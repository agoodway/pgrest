defmodule PgRest.SQL.ScopedSource do
  @moduledoc """
  Splices a resource's Ecto-scoped base query into PgRest's hand-built SQL.

  `base_query/3` computes the scoped Ecto query once per resource per request and
  enforces the predicate contract: `scope/2` may only add `where`, `join` and `distinct`.
  `compile/3` turns that query into a parenthesised subquery whose `$n` placeholders are
  shifted past the parameters the builder already holds. `effective_prefix/2` is the one
  schema rule every statement on a resource follows.

  A scope with joins or a `distinct` is spliced as a primary-key (or `unique_key`)
  semijoin, so joined rows cannot duplicate base rows and no per-parent Sort + Unique is
  planned. The semijoin reads the table in the scope's effective prefix
  (`from.prefix`, then the query prefix, then the resource schema) and selects the
  resource's default-select fields only, so columns outside the Ecto schema never appear.
  With no prefix anywhere (no `from.prefix`, query prefix or schema prefix) the table is left
  unqualified and resolves through `search_path`, exactly like Ecto's own SQL.
  `unique_key` columns must be `NOT NULL`: `IN` drops rows whose key is NULL.

  Compiled SQL text is cached in an ETS table owned by `PgRest.Cache` (created through
  `create_cache/0`). Above 5,000 shapes the cache is cleared before storing a new entry;
  concurrent callers may briefly exceed the bound. Hook shapes can vary per user.
  Without the table, queries compile uncached. Every compile emits a
  `[:pgrest, :scope_cache]` telemetry event with `cached: boolean()` metadata.
  """

  import Ecto.Query

  alias Ecto.Adapter.Queryable
  alias Ecto.Adapters.SQL
  alias PgRest.Error
  alias PgRest.SQL.{Builder, Placeholders}

  @cache_table PgRest.SQL.ScopedSource.Cache

  @doc "Name of the ETS table holding compiled scoped SQL."
  @spec cache_table() :: atom()
  def cache_table, do: @cache_table

  @doc false
  # Creates the compiled-SQL cache table, owned by the calling process. Only `PgRest.Cache`
  # calls this (from `init/1`), so it owns the table. Idempotent: an existing table is left
  # alone.
  @spec create_cache() :: :ok
  def create_cache do
    :ets.new(@cache_table, [
      :named_table,
      :set,
      :public,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  The scoped Ecto query: `scope/2` applied to the resource, then `handle_param/4` for each
  declared custom param. Raises `ArgumentError` when the result uses anything beyond
  `where`/`join`/`distinct`.
  """
  @spec base_query(module(), map(), [{String.t(), String.t()}]) ::
          Ecto.Query.t() | {:error, Error.t()}
  def base_query(resource, context, custom_params) do
    query =
      resource
      |> Ecto.Queryable.to_query()
      |> then(&resource.scope(&1, context))

    with_params(query, resource, context, custom_params)
  end

  @doc """
  Applies validated request parameters directly to an identity source, including keyless
  resources. Restricted sources are intersected with the result and require a key when
  changed; without a key the request is refused. Effective prefix changes are always rejected.
  A callback that replaces predicates or adds `or_where` cannot widen scope or policy.

  ## Differences from PostgREST

  Custom parameters are an application extension; their queries can only narrow an
  authorized source, including when no authorization hook is configured.
  Changed restricted sources need a key (42501 otherwise); identity sources do not.
  """
  @spec with_params(Ecto.Query.t() | {:error, Error.t()}, module(), map(), [
          {String.t(), String.t()}
        ]) ::
          Ecto.Query.t() | {:error, Error.t()}
  def with_params({:error, %Error{}} = error, _resource, _context, _params), do: error

  def with_params(query, resource, context, params) do
    config = resource.__pgrest_config__()

    with %Ecto.Query{} = authorized <- scope_query(query, resource),
         %Ecto.Query{} = parameterized <-
           apply_params(
             authorized,
             resource,
             context,
             params,
             config.custom_params
           ),
         %Ecto.Query{} = narrowed <- parameter_source(authorized, parameterized, resource) do
      narrowed
    else
      {:error, :denied} ->
        {:error, Error.table_denied(config, context)}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp parameter_source(authorized, parameterized, resource) do
    if identity_scope?(resource, authorized) do
      ensure_same_prefix!(authorized, parameterized, resource)
      parameterized
    else
      intersect(authorized, parameterized, resource)
    end
  end

  defp apply_params(query, resource, context, custom_params, declared) do
    custom_params
    |> Enum.filter(fn {key, _value} -> key in declared end)
    |> Enum.reduce(query, fn {key, value}, acc ->
      resource.handle_param(key, value, acc, context)
    end)
    |> scope_query(resource)
  end

  @forbidden [
    limit: nil,
    offset: nil,
    order_bys: [],
    group_bys: [],
    havings: [],
    select: nil,
    preloads: [],
    updates: [],
    combinations: [],
    lock: nil,
    with_ctes: nil,
    windows: []
  ]

  defp scope_query({:error, %Error{}} = error, _resource), do: error

  defp scope_query(query, resource),
    do:
      validate_predicate!(
        query,
        resource,
        "#{inspect(resource)}.scope/2 may only add where/join/distinct clauses"
      )

  defp validate_predicate!(%Ecto.Query{} = query, resource, message) do
    if predicate_only?(query, resource), do: query, else: raise(ArgumentError, message)
  end

  defp predicate_only?(query, resource) do
    query.from.source == Ecto.Queryable.to_query(resource).from.source and
      query.from.hints == [] and
      Enum.all?(@forbidden, fn {field, empty} -> Map.fetch!(query, field) == empty end)
  end

  @doc "Normalizes a policy query and enforces the scope predicate contract."
  @spec hook_query!(Ecto.Query.t(), module(), module()) :: Ecto.Query.t()
  def hook_query!(query, resource, auth) do
    message =
      "#{inspect(auth)}.authorize_query/5 for #{inspect(resource)} " <>
        "may only add where/join/distinct clauses; use the limit: option"

    query |> exclude(:select) |> exclude(:preload) |> validate_predicate!(resource, message)
  end

  @doc "Intersects a policy query with the base scope; neither source can widen the other."
  @spec intersect(Ecto.Query.t(), Ecto.Query.t(), module()) :: Ecto.Query.t() | {:error, :denied}
  def intersect(base, query, _resource) when base == query, do: base

  def intersect(base, query, resource) do
    ensure_same_prefix!(base, query, resource)

    case key_fields(resource.__pgrest_config__()) do
      [] -> {:error, :denied}
      fields -> intersect_source(base, query, resource, fields)
    end
  end

  defp ensure_same_prefix!(base, query, resource) do
    if effective_prefix(resource, base) != effective_prefix(resource, query) do
      raise ArgumentError,
            "authorization query for #{inspect(resource)} may not change the base scope's prefix"
    end
  end

  defp intersect_source(base, query, resource, fields) do
    cond do
      identity_scope?(resource, base) -> query
      identity_scope?(resource, query) -> base
      true -> intersect_keys(base, query, fields)
    end
  end

  defp intersect_keys(base, query, fields) do
    query = select(query, [r], map(r, ^fields))
    joined = join(base, :inner, [r], h in subquery(query), on: true)

    Enum.reduce(fields, joined, fn key, acc ->
      where(acc, [r, ..., h], field(r, ^key) == field(h, ^key))
    end)
  end

  @doc """
  Whether `source_query` is the plain `from(r in resource)`, i.e. the scope is the identity.
  """
  @spec identity_scope?(module(), Ecto.Query.t()) :: boolean()
  def identity_scope?(resource, %Ecto.Query{} = source_query) do
    strip(source_query) == strip(Ecto.Queryable.to_query(resource))
  end

  @doc """
  Compiles `source_query` to `(<sql>)`, for use as `FROM (...) AS alias`. The repo comes
  from the builder (`Builder.new(repo: repo)`). Columns are named by Ecto field name.
  """
  @spec compile(Ecto.Query.t(), module(), Builder.t()) :: {iodata(), Builder.t()}
  def compile(%Ecto.Query{}, _resource, %Builder{repo: nil}),
    do: raise(ArgumentError, "builder has no :repo; use Builder.new(repo: repo)")

  def compile(%Ecto.Query{} = query, resource, %Builder{repo: repo} = builder) do
    config = resource.__pgrest_config__()
    {sql, params} = scoped_sql(query, resource, repo)
    sql = Placeholders.renumber(sql, Builder.param_count(builder), length(params))
    {relation(sql, query, config), Builder.append_params(builder, params)}
  end

  @doc """
  A correlated `EXISTS` probe of the scoped source: `EXISTS (SELECT 1 FROM <scoped> s WHERE
  (s.<field>, ...) = (<right>, ...)<tail>)`. `fields` are the scope's column (field) names,
  `right` the matching outer expressions, `tail` text after the comparison (such as an
  optimization fence). Never `IN (subquery)`: in a conflict filter an `IN` becomes a hashed
  SubPlan over every in-scope row.
  """
  @spec exists_probe(iodata(), [String.t()], [iodata()], iodata()) :: iodata()
  def exists_probe(scoped, fields, right, tail) do
    left = Enum.map(fields, &["s.", Builder.ident(&1)])

    [
      "EXISTS (SELECT 1 FROM ",
      scoped,
      " s WHERE (",
      Enum.intersperse(left, ", "),
      ") = (",
      Enum.intersperse(right, ", "),
      ")",
      tail,
      ")"
    ]
  end

  defp semijoin?(%Ecto.Query{joins: joins, distinct: distinct}),
    do: joins != [] or distinct != nil

  defp relation(sql, query, config) do
    if semijoin?(query), do: semijoin(sql, query, config), else: plain(sql, config)
  end

  # Ecto selects the source columns; expose them under the field names when they differ.
  defp plain(sql, config) do
    if Enum.any?(config.field_columns, fn {field, source} -> field != source end) do
      ["(SELECT ", field_columns(config, "s"), " FROM (", sql, ") s)"]
    else
      ["(", sql, ")"]
    end
  end

  defp field_columns(config, prefix),
    do: projection(config, config.module.__schema__(:query_fields), prefix)

  @doc """
  `<qualifier>.<source column> AS <field name>` for each of `fields` (atoms), comma separated;
  unqualified when `qualifier` is `nil`. How a source or `RETURNING` exposes the columns
  under their Ecto field names.
  """
  @spec projection(map(), [atom()], String.t() | nil) :: iodata()
  def projection(config, fields, qualifier) do
    Enum.map_intersperse(fields, ", ", fn field ->
      source = Builder.ident(Map.fetch!(config.field_sources, field))
      [qualify(qualifier, source), " AS ", Builder.ident(Atom.to_string(field))]
    end)
  end

  defp qualify(nil, column), do: column
  defp qualify(qualifier, column), do: [qualifier, ".", column]

  @doc """
  The schema prefix the scoped source reads: the scope's `from.prefix`, then its query prefix
  (`put_query_prefix/2`), then the resource's `@schema_prefix`; `nil` when none is set. Every
  statement on the resource (reads, the write target, the semijoin, the catalog lookups and
  the request `search_path`) uses this one rule, so a scope that picks a tenant schema reads
  and writes the same table. `source_query` may be `nil` (no scope known): the resource's own
  prefix.
  """
  @spec effective_prefix(module(), Ecto.Query.t() | nil) :: String.t() | nil
  def effective_prefix(resource, nil), do: resource.__schema__(:prefix)

  def effective_prefix(resource, %Ecto.Query{} = query),
    do: query.from.prefix || query.prefix || resource.__schema__(:prefix)

  @doc """
  The schema of `effective_prefix/2`, or the resource's configured schema (`"public"`) when no
  prefix is set: the schema the catalog is read from and the `search_path` lists.
  """
  @spec effective_schema(module(), Ecto.Query.t() | nil) :: String.t()
  def effective_schema(resource, source_query),
    do: effective_prefix(resource, source_query) || resource.__pgrest_config__().schema

  @doc """
  The resource's table in its `effective_prefix/2`, quoted; unqualified when there is no
  prefix, so it resolves through `search_path` exactly like Ecto's own SQL.
  """
  @spec table(module(), Ecto.Query.t() | nil) :: iodata()
  def table(resource, source_query) do
    source = resource.__schema__(:source)

    case effective_prefix(resource, source_query) do
      nil -> Builder.ident(source)
      prefix -> Builder.qualified(prefix, source)
    end
  end

  @doc """
  The key fields (atoms) a scoped write or semijoin identifies rows by: the resource's
  `unique_key`, else its primary key. `[]` when it has neither.
  """
  @spec key_fields(map()) :: [atom()]
  def key_fields(config), do: config.unique_key || config.primary_key

  defp semijoin(sql, query, %{module: module} = config) do
    key =
      case key_fields(config) do
        [] ->
          raise ArgumentError,
                "#{inspect(module)}.scope/2 joins or uses distinct, which needs a primary key " <>
                  "or a :unique_key option on the resource"

        fields ->
          Enum.map(fields, &config.field_sources[&1])
      end

    columns = fn prefix ->
      Enum.map_intersperse(key, ", ", &[prefix, ".", Builder.ident(&1)])
    end

    table = table(module, query)

    [
      "(SELECT ",
      field_columns(config, "t"),
      " FROM ",
      table,
      " t WHERE (",
      columns.("t"),
      ") IN (SELECT ",
      columns.("s"),
      " FROM (",
      sql,
      ") s))"
    ]
  end

  # SQL text with placeholders starting at $1, plus the dumped parameter values.
  defp scoped_sql(query, resource, repo) do
    shape = strip(query)
    key = {repo, resource, :erlang.phash2(shape)}

    case lookup(key, shape) do
      {:ok, sql} ->
        {_planned, _cast, params} =
          Queryable.plan_query(:all, repo.__adapter__(), query)

        emit(resource, true)
        {sql, params}

      :miss ->
        {sql, params} = SQL.to_sql(:all, repo, query)
        sql = IO.iodata_to_binary(sql)
        store(key, shape, sql)
        emit(resource, false)
        {sql, params}
    end
  end

  defp lookup(key, shape) do
    case :ets.lookup(@cache_table, key) do
      [{^key, ^shape, sql}] -> {:ok, sql}
      _ -> :miss
    end
  rescue
    ArgumentError -> :miss
  end

  # A stored shape that differs from this one is a hash collision: keep the first entry
  # and compile this query uncached.
  defp store(key, shape, sql) do
    if :ets.info(@cache_table, :size) > 5_000, do: :ets.delete_all_objects(@cache_table)
    :ets.insert_new(@cache_table, {key, shape, sql})
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp emit(resource, cached?) do
    :telemetry.execute([:pgrest, :scope_cache], %{count: 1}, %{
      resource: resource,
      cached: cached?
    })
  end

  # The query with parameter values and source locations removed: what makes two scope
  # results the same SQL shape.
  defp strip(%{} = map) do
    map
    |> :maps.to_list()
    |> Map.new(fn
      {:params, _} -> {:params, []}
      {key, _} when key in [:file, :line] -> {key, nil}
      {key, value} -> {key, strip(value)}
    end)
  end

  defp strip(list) when is_list(list), do: Enum.map(list, &strip/1)

  defp strip(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> strip() |> List.to_tuple()

  defp strip(other), do: other
end
