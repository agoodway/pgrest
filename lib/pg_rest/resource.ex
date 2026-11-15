defmodule PgRest.Resource do
  @moduledoc """
  Behavior for defining PgRest API resources from Ecto schemas.

  ## Usage

      defmodule MyApp.Orders do
        use Ecto.Schema
        use PgRest.Resource

        schema "orders" do
          field :reference, :string
          field :status, :string
          timestamps()
        end

        import Ecto.Query

        @impl PgRest.Resource
        def scope(query, %{tenant_id: tid}) do
          where(query, [r], r.tenant_id == ^tid)
        end
      end

  ## Unsupported table names

  A table whose name starts with `pgrst_` (`pgrst_source`, `pgrst_source_count`, ...)
  collides with the CTE and alias names PgRest generates. Do not register one.
  """

  @typedoc "A map of contextual information (repo, user, tenant, etc.) passed to callbacks."
  @type context :: map()

  @doc """
  Applies scoping to the base query (e.g. tenant isolation).

  The scope is a predicate: it may add `where`, `join` and `distinct` only (anything else
  raises `ArgumentError` naming the resource). Named bindings are fine: `from(q, as: :t)`,
  `join(..., as: :j)` and `where([t: t, j: j], ...)` are compiled by Ecto itself and
  spliced as-is, so the names are kept. A scope may return `{:error, %PgRest.Error{}}`
  to reject the request.
  """
  @callback scope(Ecto.Query.t(), context()) :: Ecto.Query.t() | {:error, PgRest.Error.t()}

  @doc "Handles a custom query parameter not recognized by the standard parser."
  @callback handle_param(String.t(), String.t(), Ecto.Query.t(), context()) :: Ecto.Query.t()

  @doc """
  Builds the changeset of one written row (once per row; keep it pure). Its final changes
  express write intent: only keys in `changeset.changes` are written. Cast with
  `force_changes: true` to write (and validate) a value equal to the struct default.
  """
  @callback changeset(Ecto.Schema.t(), map(), context()) :: Ecto.Changeset.t()

  @doc """
  Post-processes a row after loading from the database (needs `after_load: true`).

  The body is decoded with plain `Jason`, so numbers arrive as integers (exact) or floats: a
  non-integer number is re-encoded as a float (`1.50` becomes `1.5`, digits past double
  precision are rounded). Select exact decimals as text (`amount::text`) on such resources.

  Rows are string-keyed maps, also for embedded resources and for spread (`...rel(...)`)
  targets: a spread's rows go through this callback before their columns merge into the
  parent row. When an embed has no row (a null to-one, an empty to-many), the callback runs
  once on a placeholder row whose planned columns are all `nil`, only to decide which
  columns to emit: the ones it keeps appear as `nil` (to-one) or `[]` (to-many), including
  keys it adds, and columns it removes stay hidden. If it raises on the placeholder, no
  columns are emitted for that spread.

  The keys are the response's output keys: a request alias (`select=secret_alias:secret`)
  renames a column before this callback sees it. Do not use key-based redaction here as a
  security control; hide columns with `readable:` / `writable:` instead.

  This is a transformation hook, not a confidentiality control. It runs after the query
  projected its columns, so filters, order, counts and `!inner` can still reveal values of
  fields it removes, and it does not run on the implicit junction rows of many-to-many
  embeds. Use `readable:` / `writable:` for columns and `scope/2` for rows.

  Rows are processed children first, exactly once each: embedded rows (by the planned
  output key) and merged spreads go through their callbacks before the row's own callback
  runs, so a parent callback may rename or drop embed keys.
  """
  @callback after_load(map(), context()) :: map()

  @valid_operations [:read, :create, :update, :delete]

  @doc """
  Injects PgRest resource behaviour, configuration, and default callback implementations.

  ## Options

    * `:allow` - `:all` (default) or a list of `:read | :create | :update | :delete`. An
      excluded operation is a `42501` on every resource a request touches (see
      `PgRest.Authorization.check/5`): without `:read` the resource cannot be embedded,
      spread or used as a junction, and its writes cannot read rows back
    * `:custom_params` - query parameter names routed to `handle_param/4` (default `[]`)
    * `:after_load` - `true` when `after_load/2` is overridden (default `false`)
    * `:unique_key` - fields forming a unique key for scoped mutations on tables
      without a primary key (default `nil`). It must be truly unique and its
      columns `NOT NULL`: the write check and the scope semijoin trust it (a NULL key is
      dropped by `IN`, a duplicate key matches more than one row)
    * `:relationships` - overrides and explicit relationship declarations, see
      `PgRest.SchemaGraph`
    * `:readable` / `:writable` - `:all` (default) or a list of field names exposed
      for reading / writing. Redact fields are hidden unless listed explicitly. The
      default `changeset/3` casts the effective writable set with `force_changes: true`.

  ## Writes through a custom `changeset/3`

  A resource that defines `changeset/3` is written row by row (`operation: :create` is in
  the context; `:upsert` for a `Prefer: resolution=` request; `:update` for `PATCH`, where
  `:required` errors for fields the payload does not supply are dropped). The changeset runs
  **once per row** (keep it pure) and **its final changes express write intent**: the
  columns written are the keys of `changeset.changes` (persisted, and in `columns=` when
  given), with their changeset values, including any change the callback adds
  (`put_change/3`). `writable:` (and `redact: true`) gate only keys the client supplies (`42501`),
  so a generated change is written even for a non-writable or redacted field. The changeset
  receives `struct(resource)`, also for `PATCH`, not the stored row, so a `put_change`
  derived from struct fields uses their defaults. Edges:

    * a supplied key the changeset does not put in its changes is not written: an insert
      gets the database default and an update leaves the column unchanged (cast every key
      you accept);
    * `cast/4` drops a value equal to the struct default (`nil`, `0`, `false`, `""` through
      `empty_values`, `[]`, ...), so it is not written either. To write it, cast with
      `force_changes: true` before your validations (they then see it too); the default
      `changeset/3` does;
    * Ecto does not force embeds: a `cast_embed/3` clearing an embed to a struct default
      that is the same (`nil` for `embeds_one`, `[]` for `embeds_many`) is omitted;
    * a change that only some rows get (a callback that adds a column conditionally, or a
      default-equal value dropped without `force_changes`) makes the rows non-uniform; the
      column is written `NULL` (or its default with `missing=default`) for the other rows. An
      upsert (`operation: :upsert`) refuses that with a 400 `PGRST102` ("All object keys must
      match"), so a merge never overwrites stored data with `NULL`.

  Validation errors are a 400 `23514` whose `details` is `field: message; ...`.

  ## Scoped writes

  `PATCH` and `DELETE` over a scope select their rows through a `FOR UPDATE` semijoin, so
  a concurrent change of ownership is waited for and re-checked. When the scope joins or
  uses `distinct`, the lock is taken on the table rows but the scope predicate (inside the
  semijoin) is not re-evaluated after the wait: a `DELETE` has the weaker guarantee. A
  `PATCH` is covered by the write check, which fails a row that left the scope with a
  42501.

  ## Differences from PostgREST

  Virtual fields explicitly listed in `writable:` are changeset-only inputs and are never
  written to SQL. Unlisted virtual fields are unknown payload keys (PGRST204).
  PostgREST accepts database columns only; this supports virtual password inputs whose
  changeset generates a persisted hash.

  `scope/2` and `changeset/3` have no definitions until the module is compiled: a
  `@before_compile` hook injects the identity scope and the default changeset only
  when the module does not define its own, and records that in the config as
  `custom_scope?` / `custom_changeset?`.
  """
  defmacro __using__(opts) do
    opts = Macro.expand_literals(opts, __CALLER__)
    allow = validate_allow!(opts)
    custom_params = validate_custom_params!(opts)
    after_load = validate_boolean!(opts, :after_load)
    unique_key = validate_unique_key!(opts)
    relationships = validate_relationships!(opts)
    readable = validate_columns!(opts, :readable)
    writable = validate_columns!(opts, :writable)

    quote do
      @behaviour PgRest.Resource
      @pgrest_resource true
      @pgrest_allow unquote(allow)
      @pgrest_custom_params unquote(custom_params)
      @pgrest_after_load unquote(after_load)
      @pgrest_unique_key unquote(unique_key)
      @pgrest_relationships unquote(Macro.escape(relationships))
      @pgrest_readable unquote(readable)
      @pgrest_writable unquote(writable)
      @before_compile PgRest.Resource
      @after_compile PgRest.Resource

      @doc "Returns `true` to indicate this module is a PgRest resource."
      @spec __pgrest_resource__() :: true
      def __pgrest_resource__, do: true

      @doc "Handles custom query parameters. Override to support non-standard filters."
      @impl PgRest.Resource
      def handle_param(_key, _value, query, _context), do: query

      @doc "Post-processes a loaded record. Override to transform data after retrieval."
      @impl PgRest.Resource
      def after_load(record, _context), do: record

      defoverridable handle_param: 4, after_load: 2
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    custom_scope? = Module.defines?(env.module, {:scope, 2})
    custom_changeset? = Module.defines?(env.module, {:changeset, 3})

    scope_default =
      if custom_scope? do
        nil
      else
        quote do
          @doc "Applies scoping to the query. Override to add tenant isolation or other filters."
          @impl PgRest.Resource
          def scope(query, _context), do: query
        end
      end

    changeset_default =
      if custom_changeset? do
        nil
      else
        quote do
          @doc """
          Casts the effective writable set with `force_changes: true`, so a supplied value
          equal to the struct default is still a change. Override to add validations.
          """
          @impl PgRest.Resource
          def changeset(struct, attrs, _context) do
            Ecto.Changeset.cast(struct, attrs, __pgrest_effective__().writable_fields,
              force_changes: true
            )
          end
        end
      end

    quote do
      unquote(scope_default)
      unquote(changeset_default)

      @doc false
      @spec __pgrest_effective__() :: map()
      def __pgrest_effective__ do
        PgRest.Resource.effective_columns(
          __MODULE__,
          @pgrest_readable,
          @pgrest_writable
        )
      end

      @doc "Returns the PgRest configuration map derived from the Ecto schema."
      @spec __pgrest_config__() :: map()
      def __pgrest_config__ do
        effective = __pgrest_effective__()

        %{
          module: __MODULE__,
          table: __MODULE__.__schema__(:source),
          schema: effective.schema,
          fields: __MODULE__.__schema__(:fields),
          associations: __MODULE__.__schema__(:associations),
          primary_key: __MODULE__.__schema__(:primary_key),
          allow: @pgrest_allow,
          custom_params: @pgrest_custom_params,
          after_load: @pgrest_after_load,
          unique_key: @pgrest_unique_key,
          relationships: @pgrest_relationships,
          field_sources: effective.field_sources,
          field_columns: effective.field_columns,
          source_fields: effective.source_fields,
          input_fields: effective.input_fields,
          readable_sources: effective.readable_sources,
          types: effective.types,
          custom_scope?: unquote(custom_scope?),
          custom_changeset?: unquote(custom_changeset?),
          readable: effective.readable,
          writable: effective.writable,
          virtual_sources: effective.virtual_sources,
          restricted_columns?: effective.restricted_columns?
        }
      end
    end
  end

  @doc false
  def __after_compile__(env, _bytecode) do
    module = env.module
    fields = module.__schema__(:fields)

    for {key, names} <- [
          readable: Module.get_attribute(module, :pgrest_readable),
          writable: Module.get_attribute(module, :pgrest_writable),
          unique_key: Module.get_attribute(module, :pgrest_unique_key)
        ],
        is_list(names),
        unknown =
          names -- known_fields(key, fields, module),
        unknown != [] do
      raise ArgumentError,
            "#{inspect(module)} lists unknown fields in :#{key} option: " <>
              "#{inspect(unknown)}. Schema fields are: #{inspect(fields)}"
    end

    associations = module.__schema__(:associations)

    for {name, opts} <- Module.get_attribute(module, :pgrest_relationships) do
      check_relationship!(module, associations, name, opts)
    end

    :ok
  end

  @relationship_kinds [:m2o, :o2m, :o2o, :m2m]
  @override_keys [:constraint, :cardinality]
  @junction_keys [:table, :schema, :source_columns, :target_columns, :constraints]

  defp check_relationship!(module, associations, name, opts) do
    case Keyword.fetch(opts, :kind) do
      :error ->
        check_override!(module, associations, name, opts)

      {:ok, :m2m} ->
        check_m2m!(module, name, opts)

      {:ok, kind} when kind in @relationship_kinds ->
        check_keys!(module, name, opts, [:target, :columns, :constraint], [:kind])

      {:ok, kind} ->
        raise ArgumentError,
              "#{inspect(module)} relationship #{inspect(name)} has unknown kind " <>
                "#{inspect(kind)}. Valid kinds are: #{inspect(@relationship_kinds)}"
    end
  end

  defp check_override!(module, associations, name, opts) do
    if name not in associations do
      raise ArgumentError,
            "#{inspect(module)} :relationships has #{inspect(name)}, which is neither an association nor " <>
              "an explicit declaration (missing :kind). Associations: #{inspect(associations)}"
    end

    check_keys!(module, name, opts, [], @override_keys)
  end

  defp check_m2m!(module, name, opts) do
    check_keys!(module, name, opts, [:target, :junction], [:kind])
    check_junction!(module, name, Keyword.fetch!(opts, :junction))
  end

  defp check_junction!(module, name, junction) when is_list(junction) do
    if Keyword.keyword?(junction),
      do: check_keys!(module, name, junction, @junction_keys, []),
      else: raise_junction!(module, name)
  end

  defp check_junction!(module, name, _other), do: raise_junction!(module, name)

  defp raise_junction!(module, name) do
    raise ArgumentError,
          "#{inspect(module)} relationship #{inspect(name)}: :junction must be a keyword list " <>
            "with keys #{inspect(@junction_keys)}"
  end

  # `required` keys must be present; only `required ++ extra` keys are allowed.
  defp check_keys!(module, name, opts, required, extra) do
    keys = Keyword.keys(opts)

    case {required -- keys, keys -- (required ++ extra)} do
      {[], []} ->
        :ok

      {[], unknown} ->
        raise ArgumentError,
              "#{inspect(module)} relationship #{inspect(name)} has unknown keys #{inspect(unknown)}"

      {missing, _unknown} ->
        raise ArgumentError,
              "#{inspect(module)} relationship #{inspect(name)} is missing required keys #{inspect(missing)}"
    end
  end

  @doc false
  @spec effective_columns(module(), :all | [atom()], :all | [atom()]) :: map()
  def effective_columns(module, readable, writable) do
    key = {__MODULE__, module, module.__info__(:md5)}

    case :persistent_term.get(key, nil) do
      nil ->
        effective = compute_columns(module, readable, writable)
        :persistent_term.put(key, effective)
        effective

      effective ->
        effective
    end
  end

  defp known_fields(:writable, fields, module), do: fields ++ module.__schema__(:virtual_fields)
  defp known_fields(_key, fields, _module), do: fields

  defp compute_columns(module, readable, writable) do
    fields = module.__schema__(:fields)
    redact = module.__schema__(:redact_fields)

    readable_fields = if readable == :all, do: fields -- redact, else: readable
    writable_fields = if writable == :all, do: fields -- redact, else: writable

    readable_set = MapSet.new(readable_fields, &Atom.to_string/1)
    writable_set = MapSet.new(writable_fields, &Atom.to_string/1)
    all_set = MapSet.new(fields, &Atom.to_string/1)
    field_sources = Map.new(fields, &{&1, Atom.to_string(module.__schema__(:field_source, &1))})

    field_columns =
      Map.new(field_sources, fn {field, source} -> {Atom.to_string(field), source} end)

    source_fields = Map.new(field_columns, fn {field, source} -> {source, field} end)

    virtual_sources =
      writable_fields
      |> Enum.filter(&(&1 in module.__schema__(:virtual_fields)))
      |> Map.new(&{Atom.to_string(&1), Atom.to_string(&1)})

    %{
      schema: module.__schema__(:prefix) || "public",
      field_sources: field_sources,
      field_columns: field_columns,
      source_fields: source_fields,
      input_fields: Map.merge(source_fields, virtual_sources),
      readable_sources: MapSet.new(readable_fields, &Map.fetch!(field_sources, &1)),
      types: Map.new(fields, &{&1, module.__schema__(:type, &1)}),
      readable: readable_set,
      writable: writable_set,
      virtual_sources: virtual_sources,
      writable_fields: writable_fields,
      restricted_columns?: readable_set != all_set or writable_set != all_set
    }
  end

  defp validate_custom_params!(opts) do
    case Keyword.get(opts, :custom_params, []) do
      params when is_list(params) ->
        if Enum.all?(params, &is_binary/1) do
          params
        else
          raise ArgumentError, "invalid :custom_params option: expected a list of strings"
        end

      other ->
        raise ArgumentError,
              "invalid :custom_params option: #{inspect(other)}. Expected a list of strings"
    end
  end

  defp validate_boolean!(opts, key) do
    case Keyword.get(opts, key, false) do
      value when is_boolean(value) ->
        value

      other ->
        raise ArgumentError, "invalid :#{key} option: #{inspect(other)}. Expected a boolean"
    end
  end

  defp validate_unique_key!(opts) do
    case Keyword.get(opts, :unique_key) do
      nil ->
        nil

      [_ | _] = key ->
        if Enum.all?(key, &is_atom/1) do
          key
        else
          raise ArgumentError, "invalid :unique_key option: expected a list of field names"
        end

      other ->
        raise ArgumentError,
              "invalid :unique_key option: #{inspect(other)}. Expected nil or a non-empty list of field names"
    end
  end

  defp validate_relationships!(opts) do
    case Keyword.get(opts, :relationships, []) do
      rels when is_list(rels) ->
        if Keyword.keyword?(rels) and Enum.all?(rels, &keyword_entry?/1) do
          rels
        else
          raise ArgumentError,
                "invalid :relationships option: expected a keyword list of keyword lists"
        end

      other ->
        raise ArgumentError,
              "invalid :relationships option: #{inspect(other)}. Expected a keyword list"
    end
  end

  defp keyword_entry?({_name, options}), do: Keyword.keyword?(options)

  defp validate_columns!(opts, key) do
    case Keyword.get(opts, key, :all) do
      :all ->
        :all

      names when is_list(names) ->
        if Enum.all?(names, &is_atom/1) do
          names
        else
          raise ArgumentError, "invalid :#{key} option: expected :all or a list of field names"
        end

      other ->
        raise ArgumentError,
              "invalid :#{key} option: #{inspect(other)}. Expected :all or a list of field names"
    end
  end

  defp validate_allow!(opts) do
    case Keyword.get(opts, :allow, :all) do
      :all ->
        :all

      ops when is_list(ops) ->
        invalid = ops -- @valid_operations

        if invalid != [] do
          raise ArgumentError,
                "invalid operations in :allow option: #{inspect(invalid)}. " <>
                  "Valid operations are: #{inspect(@valid_operations)}"
        end

        if ops == [] do
          raise ArgumentError,
                ":allow option cannot be an empty list. " <>
                  "Valid operations are: #{inspect(@valid_operations)}"
        end

        ops

      other ->
        raise ArgumentError,
              "invalid :allow option: #{inspect(other)}. " <>
                "Expected :all or a list of operations from: #{inspect(@valid_operations)}"
    end
  end
end
