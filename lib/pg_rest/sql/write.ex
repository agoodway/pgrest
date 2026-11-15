defmodule PgRest.SQL.Write do
  @moduledoc """
  Compiles writes to one SQL statement, mirroring PostgREST's `mutatePlanToQuery`.

  `insert/3` binds the whole payload as **one** JSON parameter (`$1::text::json`) however
  many rows it holds, and expands it with `json_populate_recordset`:

      WITH pgrst_payload AS (SELECT $1::text::json AS j),
      pgrst_source AS (
        INSERT INTO t (<cols>) SELECT <cols> FROM json_populate_recordset(NULL::t, <array>) _
        RETURNING <every column> AS <its Ecto field name>)
      <read wrapper over pgrst_source>

  A single object is wrapped into a one element array in SQL. `RETURNING` exposes the
  columns under their Ecto field names, which is how `PgRest.SQL.Read` addresses a node.

  `json_populate_recordset` yields `NULL` for an absent key. With `missing: :default` each
  element is first merged over `jsonb_build_object(<column>, <default expression>, ...)`
  (PostgREST's `fromJsonBodyF`), so an absent key takes the column default while an explicit
  `null` stays `NULL`. The expressions come from `PgRest.Catalog.column_defaults/3`.

  `update/5` and `delete/4` compile `PATCH` and `DELETE` (see their docs): one statement, the
  payload one JSON parameter, filters compiled on the target or through a `FOR UPDATE`
  semijoin over the scoped source.

  The statement always returns `total`, `page_total`, `body`, `pgrst_keys`, `pgrst_inserted`,
  `pgrst_written`, `pgrst_matched` and the two response GUC columns (`PgRest.ResponseGucs`). `pgrst_keys` is
  the written primary keys as JSON text, `[{"<field>": value, ...}, ...]`, when the caller
  asks for them (`:keys`); `check/4` binds that text back to verify the scope.
  """

  alias PgRest.{MediaType, Plan, ResponseGucs}
  alias PgRest.SQL.{Builder, Read, ScopedSource, Where}

  @typedoc "Rows as maps keyed by source column, or the original request bytes plus their keys."
  @type input :: [map()] | {:raw, binary(), [String.t()]}

  @inserted_key "pgrst.inserted"

  # The `pgrst.inserted` setting as an integer (NULL when no statement set it).
  @inserted_setting "nullif(pg_catalog.current_setting('" <> @inserted_key <> "', true), '')::int"
  @written "(SELECT pg_catalog.count(*) FROM pgrst_source)"

  @payload_array """
  CASE WHEN json_typeof((SELECT j FROM pgrst_payload)) = 'array' \
  THEN (SELECT j FROM pgrst_payload) \
  ELSE json_build_array((SELECT j FROM pgrst_payload)) END\
  """

  @doc """
  Compiles an insert into `{sql, params}`.

  ## Options

    * `:repo` - the Ecto repo (required)
    * `:columns` - the source columns to write; default: the keys of the rows
    * `:missing` - `:default` applies column defaults for absent keys
    * `:defaults` - `%{column => default expression}` (from the catalog), used with `:missing`
    * `:on_conflict` - `nil`, or `%{target: [column], action: :merge | :ignore, guard: ...}`:
      `ON CONFLICT (<target>) DO UPDATE SET <payload columns> = EXCLUDED.<column>` or
      `DO NOTHING`. `merge` counts the inserted rows (`pgrst_inserted`); `guard` is
      `%{plan:, key: [{field, source_column}]}`, the scope probe of the existing row
    * `:returning_plan` - the read plan of the representation; `nil` returns no body
    * `:hook_limit` - caps response counts when there is no representation; written rows
      and keys used by transactional checks remain uncapped
    * `:media` - the `PgRest.MediaType` of the representation (default JSON): an object type
      unwraps a single row, `nulls=stripped` strips nulls, CSV renders text
    * `:keys` - `[field_name]`, the primary key fields to return as `pgrst_keys`
    * `:key` - `[{column, text}]`, a `PUT`'s URL key: only the payload element whose column equals
      the text (cast by Postgres to the column's type, as `json_populate_record` reads it) is
      written, and only when exactly one does; the count is returned as `pgrst_matched`. Every
      element is still decoded, so Postgres type-checks them all
    * `:source_query` - the target's scoped Ecto query (`plan.source_query`): the table is
      written in its effective schema prefix (`PgRest.SQL.ScopedSource.effective_prefix/2`);
      default: the resource's own prefix
  """
  @spec insert(module(), input(), keyword()) :: {String.t(), [term()]}
  def insert(resource, input, opts) do
    {payload, keys} = payload(input)
    columns = Keyword.get(opts, :columns) || keys
    builder = Builder.new(repo: Keyword.fetch!(opts, :repo))
    {param, builder} = Builder.param(builder, payload, "json", :text)
    {array, builder} = rows_expr(columns, opts, builder)
    target = target(resource, Keyword.get(opts, :source_query))
    on_conflict = Keyword.get(opts, :on_conflict)
    {conflict, builder} = conflict_sql(resource, on_conflict, columns, builder)
    {rows, builder} = rows_source(Keyword.get(opts, :key), columns, target, array, builder)

    ctes = ["pgrst_payload AS (SELECT ", param, " AS j), ", rows.ctes]

    source = [
      insert_sql(
        target,
        columns,
        rows.from,
        conditions(rows.where, counted(merge?(on_conflict)))
      ),
      conflict,
      returning(resource)
    ]

    extras = %{
      keys: key_columns(Keyword.get(opts, :keys)),
      inserted: if(merge?(on_conflict), do: @inserted_setting, else: "NULL"),
      matched: rows.matched
    }

    case Keyword.get(opts, :returning_plan) do
      nil -> bare(ctes, source, extras, builder, Keyword.get(opts, :hook_limit))
      plan -> represent(plan, ctes, source, extras, builder, opts)
    end
  end

  defp merge?(%{action: :merge}), do: true
  defp merge?(_on_conflict), do: false

  # --- upsert ----------------------------------------------------------------------

  # Counts a candidate row up before the insert is attempted, and back down when the
  # conflict branch turns it into an update. `set_config` returns its new value, compared
  # with a value the counter never holds at that point so the predicate is always true.
  defp bump(sign, never) do
    [
      "pg_catalog.set_config('",
      @inserted_key,
      "', (coalesce(",
      @inserted_setting,
      ", 0) ",
      sign,
      " 1)::text, true) <> '",
      never,
      "'"
    ]
  end

  defp do_nothing(target), do: [conflict_target(target), "DO NOTHING"]

  # `resource` is only needed by the guard of a real update.
  defp conflict_sql(_resource, nil, _columns, builder), do: {[], builder}
  defp conflict_sql(_resource, %{target: []}, _columns, builder), do: {[], builder}

  defp conflict_sql(_resource, %{action: :ignore, target: t}, _columns, builder),
    do: {do_nothing(t), builder}

  defp conflict_sql(_resource, %{action: :merge, target: t}, [], builder),
    do: {do_nothing(t), builder}

  defp conflict_sql(resource, %{action: :merge, target: target} = on_conflict, columns, builder) do
    sets =
      Enum.map_intersperse(columns, ", ", &[Builder.ident(&1), " = EXCLUDED.", Builder.ident(&1)])

    {guard, builder} = guard(resource, Map.get(on_conflict, :guard), builder)

    {[conflict_target(target), "DO UPDATE SET ", sets, " WHERE ", guard, bump("-", "-1")],
     builder}
  end

  defp conflict_target(target) do
    [" ON CONFLICT (", Builder.ident_list(target), ") "]
  end

  # The existing row must be visible through the scope: a correlated EXISTS probe (never
  # `IN (subquery)`), the row-level security `USING` check of the conflicting row.
  defp guard(_resource, nil, builder), do: {[], builder}

  defp guard(resource, %{plan: plan, key: key}, builder) do
    {scoped, builder} = ScopedSource.compile(plan.source_query, resource, builder)
    table = Builder.ident(resource.__schema__(:source))

    # `OFFSET 0` keeps the planner from turning the EXISTS into a hashed ANY SubPlan over
    # every in-scope row: it stays a per-row index probe.
    probe =
      ScopedSource.exists_probe(
        scoped,
        Enum.map(key, &elem(&1, 0)),
        Enum.map(key, fn {_field, source} -> [table, ".", Builder.ident(source)] end),
        " OFFSET 0"
      )

    {[probe, " AND "], builder}
  end

  defp payload({:raw, binary, keys}), do: {binary, keys}

  defp payload(rows) do
    keys = rows |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()
    {Jason.encode!(rows), keys}
  end

  defp represent(plan, ctes, source, extras, builder, opts) do
    plan = Plan.Read.put_media(plan, Keyword.get(opts, :media, MediaType.json()))

    Read.statement(plan, %{repo: builder.repo},
      source: {source, builder},
      ctes: ctes,
      extra: extras.keys,
      inserted: extras.inserted,
      written: @written,
      matched: extras.matched
    )
  end

  # No body: the page total and the keys only.
  defp bare(ctes, source, extras, builder, cap) do
    {count, builder} = response_count(cap, builder)

    Builder.to_sql(builder, [
      "WITH ",
      ctes,
      "pgrst_source AS (",
      source,
      ") SELECT NULL::bigint AS total, ",
      count,
      " AS page_total, ",
      "NULL::text AS body, ",
      extras.keys,
      " AS pgrst_keys, ",
      extras.inserted,
      " AS pgrst_inserted, ",
      @written,
      " AS pgrst_written, ",
      extras.matched,
      " AS pgrst_matched, ",
      ResponseGucs.columns(),
      " FROM pgrst_source"
    ])
  end

  defp response_count(nil, builder), do: {"pg_catalog.count(*)", builder}

  defp response_count(cap, builder) do
    {value, builder} = Builder.bigint(builder, cap)
    {["LEAST(pg_catalog.count(*), ", value, ")"], builder}
  end

  defp insert_sql(target, [], from, where),
    do: ["INSERT INTO ", target, " SELECT FROM ", from, where(where)]

  defp insert_sql(target, columns, from, where) do
    names = Builder.ident_list(columns)

    ["INSERT INTO ", target, " (", names, ") SELECT ", names, " FROM ", from, where(where)]
  end

  defp where([]), do: []
  defp where(terms), do: [" WHERE " | Enum.intersperse(terms, " AND ")]

  # `CASE` evaluates in order: the insert counter only sees the row that is written.
  defp conditions(terms, []), do: terms
  defp conditions([], counter), do: counter

  defp conditions(terms, [counter]),
    do: [["CASE WHEN ", Enum.intersperse(terms, " AND "), " THEN ", counter, " ELSE false END"]]

  defp counted(true), do: [bump("+", "0")]
  defp counted(false), do: []

  # What the insert reads. A `PUT` decodes every element once (`pgrst_rows`, so Postgres reads
  # and type-checks them all) and flags those whose key column equals the URL's value, cast
  # by `json_populate_record` like any payload value. It writes only when exactly one does.
  defp rows_source(nil, columns, target, array, builder),
    do: {%{ctes: [], from: from(columns, target, array), where: [], matched: "NULL"}, builder}

  defp rows_source(key, _columns, target, array, builder) do
    {predicates, builder} =
      Enum.map_reduce(key, builder, fn {column, text}, b ->
        {name, b} = Builder.param(b, column, nil, :text)
        {value, b} = Builder.param(b, text, nil, :text)
        {key_predicate(column, target, name, value), b}
      end)

    ctes = [
      "pgrst_rows AS MATERIALIZED (SELECT _.*, ",
      Enum.intersperse(predicates, " AND "),
      " AS pgrst_match FROM json_populate_recordset(NULL::",
      target,
      ", ",
      array,
      ") _), pgrst_matches AS (SELECT count(*) FILTER (WHERE pgrst_match) AS n FROM pgrst_rows), "
    ]

    {%{
       ctes: ctes,
       from: "pgrst_rows _",
       where: ["pgrst_match", "(SELECT n FROM pgrst_matches) = 1"],
       matched: "(SELECT n FROM pgrst_matches)"
     }, builder}
  end

  defp key_predicate(column, target, name, value) do
    ident = Builder.ident(column)

    [
      "_.",
      ident,
      " = (SELECT k.",
      ident,
      " FROM json_populate_record(NULL::",
      target,
      ", json_build_object(",
      name,
      ", ",
      value,
      ")) k)"
    ]
  end

  defp from([], _target, array), do: ["json_array_elements(", array, ") _"]

  defp from(_columns, target, array),
    do: ["json_populate_recordset(NULL::", target, ", ", array, ") _"]

  # --- rows ----------------------------------------------------------------------

  defp rows_expr(columns, opts, builder) do
    defaults = defaults(columns, opts)

    if defaults == [],
      do: {@payload_array, builder},
      else: with_defaults(defaults, builder)
  end

  defp defaults(columns, opts) do
    case Keyword.get(opts, :missing) do
      :default ->
        all = Keyword.get(opts, :defaults, %{})
        for column <- columns, expression = Map.get(all, column), do: {column, expression}

      _other ->
        []
    end
  end

  # Every element becomes `jsonb_build_object(<defaults>) || element`, in payload order.
  defp with_defaults(defaults, builder) do
    {pairs, builder} =
      Enum.map_reduce(defaults, builder, fn {column, expression}, b ->
        {key, b} = Builder.param(b, column, nil, :text)
        {[key, ", ", expression], b}
      end)

    sql = [
      "(SELECT coalesce(json_agg(jsonb_build_object(",
      Enum.intersperse(pairs, ", "),
      ") || d.e ORDER BY d.ord), '[]'::json) FROM jsonb_array_elements((",
      @payload_array,
      ")::jsonb) WITH ORDINALITY AS d(e, ord))"
    ]

    {sql, builder}
  end

  # --- target, returning, keys ---------------------------------------------------

  # The table in the scope's effective schema prefix (`ScopedSource.table/2`), so a write
  # reaches the table its reads and its write check see.
  defp target(resource, source_query), do: ScopedSource.table(resource, source_query)

  defp returning(resource, qualifier \\ nil),
    do: [" RETURNING ", returning_columns(resource, qualifier)]

  defp returning_columns(resource, qualifier) do
    config = resource.__pgrest_config__()
    ScopedSource.projection(config, config.fields, qualifier)
  end

  defp key_columns(nil), do: "NULL"
  defp key_columns([]), do: "NULL"

  defp key_columns(fields) do
    names = Builder.ident_list(fields)
    ["(SELECT json_agg(k.*)::text FROM (SELECT ", names, " FROM pgrst_source) k)"]
  end

  # --- update and delete ---------------------------------------------------------

  @mutation_alias "pgrst_m"

  @doc """
  Compiles a `PATCH` into `{sql, params}`. `input` is `{:raw, json, keys}` (one object, or an
  array of one) and `opts` as for `insert/3` (`:repo`, `:columns`, `:missing`, `:defaults`,
  `:media`, `:keys`).

  The columns `SET` are `opts[:columns]` (default: the keys), taken from the payload by
  `json_populate_recordset`, so every value arrives in its column's catalog type. With none
  the statement selects no row (`WHERE false`), as PostgREST does.

  `plan` is the target plan whose `where` selects the rows; `returning_plan` (the plan
  without `where`) shapes the representation, `nil` for none. Two shapes, by the scope:

    * **Identity scope**, PostgREST's own: the filters are compiled on the target,
      `UPDATE t AS pgrst_m SET ... WHERE <filters>`. Tables without a primary key work.
    * **Any other scope**: the rows are chosen through the scope and locked,
      `WHERE (<key>) IN (SELECT <key> FROM (<scoped source>) s WHERE <filters> FOR UPDATE)`,
      so a concurrent change of ownership is waited for and re-checked (S-L1).
  """
  @spec update(module(), input(), Plan.Read.t(), Plan.Read.t() | nil, keyword()) ::
          {String.t(), [term()]}
  def update(resource, input, %Plan.Read{} = plan, returning_plan, opts) do
    {payload, keys} = payload(input)
    columns = Keyword.get(opts, :columns) || keys
    builder = Builder.new(repo: Keyword.fetch!(opts, :repo))
    {ctes, source, builder} = update_source(resource, columns, payload, plan, opts, builder)

    mutation(returning_plan, ctes, source, builder, opts)
  end

  @doc """
  Compiles a `DELETE` into `{sql, params}`, the same two shapes as `update/5`:
  `DELETE FROM t AS pgrst_m WHERE ... RETURNING ...`.
  """
  @spec delete(module(), Plan.Read.t(), Plan.Read.t() | nil, keyword()) ::
          {String.t(), [term()]}
  def delete(resource, %Plan.Read{} = plan, returning_plan, opts) do
    builder = Builder.new(repo: Keyword.fetch!(opts, :repo))
    {where, builder} = mutation_where(resource, plan, builder)

    source = [
      "DELETE FROM ",
      target(resource, plan.source_query),
      " AS ",
      @mutation_alias,
      where,
      returning(resource, @mutation_alias)
    ]

    mutation(returning_plan, [], source, builder, opts)
  end

  defp update_source(resource, [], _payload, plan, _opts, builder) do
    source = [
      "SELECT ",
      returning_columns(resource, @mutation_alias),
      " FROM ",
      target(resource, plan.source_query),
      " AS ",
      @mutation_alias,
      " WHERE false"
    ]

    {[], source, builder}
  end

  defp update_source(resource, columns, payload, plan, opts, builder) do
    {param, builder} = Builder.param(builder, payload, "json", :text)
    {array, builder} = rows_expr(columns, opts, builder)
    {where, builder} = mutation_where(resource, plan, builder)
    target = target(resource, plan.source_query)
    names = Builder.ident_list(columns)

    sets =
      Enum.map_intersperse(
        columns,
        ", ",
        &[Builder.ident(&1), " = pgrst_body.", Builder.ident(&1)]
      )

    source = [
      "UPDATE ",
      target,
      " AS ",
      @mutation_alias,
      " SET ",
      sets,
      " FROM (SELECT ",
      names,
      " FROM json_populate_recordset(NULL::",
      target,
      ", ",
      array,
      ") _) pgrst_body",
      where,
      returning(resource, @mutation_alias)
    ]

    {["pgrst_payload AS (SELECT ", param, " AS j), "], source, builder}
  end

  defp mutation(returning_plan, ctes, source, builder, opts) do
    extras = %{keys: key_columns(Keyword.get(opts, :keys)), inserted: "NULL", matched: "NULL"}

    case returning_plan do
      nil -> bare(ctes, source, extras, builder, nil)
      plan -> represent(plan, ctes, source, extras, builder, opts)
    end
  end

  defp mutation_where(resource, plan, builder) do
    config = resource.__pgrest_config__()

    if ScopedSource.identity_scope?(resource, plan.source_query) and plan.hook_limit == nil,
      do: identity_where(config, plan, builder),
      else: semijoin_where(resource, config, plan, builder)
  end

  defp identity_where(_config, %Plan.Read{where: nil}, builder), do: {[], builder}

  defp identity_where(config, plan, builder) do
    {sql, builder} =
      Where.compile(plan.where, @mutation_alias, plan.column_types, builder,
        categories: plan.categories,
        columns: config.field_columns
      )

    {[" WHERE ", sql], builder}
  end

  # The scoped source exposes field names; the target is addressed by source column.
  defp semijoin_where(resource, config, plan, builder) do
    {scoped, builder} = ScopedSource.compile(plan.source_query, resource, builder)
    {filters, builder} = scoped_filters(plan, builder)
    {limit, builder} = Builder.limit(builder, plan.hook_limit)
    fields = ScopedSource.key_fields(config)

    left =
      Enum.map(
        fields,
        &[@mutation_alias, ".", Builder.ident(Map.fetch!(config.field_sources, &1))]
      )

    right = Enum.map(fields, &["s.", Builder.ident(Atom.to_string(&1))])

    sql = [
      " WHERE (",
      Enum.intersperse(left, ", "),
      ") IN (SELECT ",
      Enum.intersperse(right, ", "),
      " FROM ",
      scoped,
      " s",
      filters,
      limit,
      " FOR UPDATE)"
    ]

    {sql, builder}
  end

  defp scoped_filters(%Plan.Read{where: nil}, builder), do: {[], builder}

  defp scoped_filters(plan, builder) do
    {sql, builder} =
      Where.compile(plan.where, "s", plan.column_types, builder, categories: plan.categories)

    {[" WHERE ", sql], builder}
  end

  # --- write check ---------------------------------------------------------------

  @doc """
  The write check, a statement in the same transaction as the write: how many of the
  written `keys` (the text of `pgrst_keys`) the resource's scope does **not** see. `0` passes.

  The keys are one JSON parameter; each is probed with a correlated `EXISTS`, never
  `IN (subquery)`. `key_fields` are the primary key (or `unique_key`) fields in order and
  `plan.column_types` supplies their catalog types.
  """
  @spec check(module(), Plan.Read.t(), String.t(), [String.t()], module()) ::
          {String.t(), [term()]}
  def check(resource, %Plan.Read{} = plan, keys_json, key_fields, repo) do
    builder = Builder.new(repo: repo)
    {keys, builder} = Builder.param(builder, keys_json, "json", :text)
    {scoped, builder} = ScopedSource.compile(plan.source_query, resource, builder)

    definitions =
      Enum.map_intersperse(key_fields, ", ", fn field ->
        [Builder.ident(field), " ", Map.get(plan.column_types, field, "text")]
      end)

    right = Enum.map(key_fields, &["k.", Builder.ident(&1)])
    probe = ScopedSource.exists_probe(scoped, key_fields, right, "")

    Builder.to_sql(builder, [
      "SELECT pg_catalog.json_array_length(",
      keys,
      ") - pg_catalog.count(*) FROM json_to_recordset(",
      keys,
      ") AS k(",
      definitions,
      ") WHERE ",
      probe
    ])
  end
end
