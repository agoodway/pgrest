defmodule PgRest.Catalog do
  @moduledoc """
  Reads metadata about registered tables from the PostgreSQL catalogs.

  Only tables registered as resources are ever loaded, so the cache key space is
  bounded. Results are cached lazily in `:persistent_term` under
  `{PgRest.Catalog, repo, kind, {schema, table}}`; the server facts (`facts/1`) under
  `{PgRest.Catalog, repo, :facts, :server}`. `PgRest.Planner.Columns` memoizes its
  per-resource info under the same `{PgRest.Catalog, repo, :info, _}` namespace, so
  `forget/1` clears both without the catalog depending on the planner.

  Every load runs in its own short transaction that first sets a local empty
  `search_path`, so names of non-`pg_catalog` objects come back schema-qualified
  (`test.status_enum`). Because that setting is transaction-local, a load refuses to run
  inside an open transaction: it would leak into the caller's request. Resolve catalog
  data before opening the request transaction.

  The catalog never leaves PgRest: type text is emitted into SQL only through
  `PgRest.SQL.Builder.param/4`.
  """

  alias PgRest.{Executor, Options}

  require Logger

  @type table_key :: {String.t(), String.t()}

  @columns_sql """
  SELECT a.attname::text, pg_catalog.format_type(a.atttypid, a.atttypmod), t.typcategory::text
  FROM pg_catalog.pg_attribute a
  JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
  JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
  JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped
  """

  # PostgREST's column default (SchemaCache.hs): identity BY DEFAULT is `nextval(<seq>)`, a
  # domain default applies when the column has none, generated columns have none.
  @defaults_sql """
  SELECT name, expression FROM (
    SELECT a.attname::text AS name,
      CASE
        WHEN t.typbasetype != 0 AND ad.adbin IS NULL THEN pg_catalog.pg_get_expr(t.typdefaultbin, 0)
        WHEN a.attidentity = 'd' THEN pg_catalog.format('nextval(%L)', seq.objid::pg_catalog.regclass)
        WHEN a.attgenerated = 's' THEN NULL
        ELSE pg_catalog.pg_get_expr(ad.adbin, ad.adrelid)
      END AS expression
    FROM pg_catalog.pg_attribute a
    JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
    JOIN pg_catalog.pg_type t ON t.oid = a.atttypid
    LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
    LEFT JOIN pg_catalog.pg_depend seq ON seq.refobjid = a.attrelid
      AND seq.refobjsubid = a.attnum AND seq.deptype = 'i'
      AND seq.classid = 'pg_catalog.pg_class'::pg_catalog.regclass
    WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped
  ) defaults
  WHERE expression IS NOT NULL
  """

  # One statement, no transaction: the role is the login role (`session_user`), never a role
  # a request set with `set_config('role', ...)`.
  @facts_sql """
  SELECT
    (SELECT coalesce(pg_catalog.array_agg(name::text), '{}') FROM pg_catalog.pg_timezone_names),
    pg_catalog.current_setting('server_version_num')::int,
    coalesce((SELECT rolsuper OR rolbypassrls FROM pg_catalog.pg_roles
      WHERE rolname = session_user), false)
  """

  # PostgREST's `queryRoleSettings`: the `ALTER ROLE ... SET` settings (database-wide, as
  # `rolconfig`) of every role the login role is a member of, limited to the settings that role
  # may set (`user` context, or on 15+ a `SET` privilege), without
  # `default_transaction_isolation`. In `rolconfig` order.
  @role_settings_sql """
  SELECT r.rolname::text, kv.key, kv.value
  FROM pg_catalog.pg_auth_members m
  JOIN pg_catalog.pg_roles r ON r.oid = m.roleid
  CROSS JOIN LATERAL pg_catalog.unnest(r.rolconfig) WITH ORDINALITY AS s(setting, n)
  CROSS JOIN LATERAL (SELECT
      pg_catalog.substr(s.setting, 1, pg_catalog.strpos(s.setting, '=') - 1) AS key,
      pg_catalog.substr(s.setting, pg_catalog.strpos(s.setting, '=') + 1) AS value) kv
  JOIN pg_catalog.pg_settings ps ON ps.name = kv.key
  WHERE m.member = (SELECT oid FROM pg_catalog.pg_roles WHERE rolname = session_user)
    AND kv.key <> 'default_transaction_isolation'
    AND (ps.context = 'user'__PARAMETER_PRIVILEGE__)
  ORDER BY r.rolname, s.n
  """
  @parameter_privilege " OR pg_catalog.has_parameter_privilege(session_user, ps.name, 'SET')"
  @role_settings_pre15 String.replace(@role_settings_sql, "__PARAMETER_PRIVILEGE__", "")
  @role_settings_15 String.replace(
                      @role_settings_sql,
                      "__PARAMETER_PRIVILEGE__",
                      @parameter_privilege
                    )

  defmodule Facts do
    @moduledoc """
    Server-wide facts `PgRest.Catalog.facts/1` reads once per repo: the timezone names
    `Prefer: timezone` accepts, the server version, whether the login role bypasses RLS, and
    the `ALTER ROLE ... SET` settings of the roles it may switch to (`%{role => [{name, value}]}`).
    """

    @enforce_keys [:timezones, :server_version_num, :bypasses_rls?]
    defstruct [:timezones, :server_version_num, :bypasses_rls?, role_settings: %{}]

    @type t :: %__MODULE__{
            timezones: MapSet.t(String.t()),
            server_version_num: pos_integer(),
            bypasses_rls?: boolean(),
            role_settings: %{String.t() => [{String.t(), String.t()}]}
          }
  end

  @no_columns %{types: %{}, categories: %{}}
  @permanent_codes [:insufficient_privilege, :undefined_table, :invalid_schema_name]

  @doc """
  Maps each column of `schema.table` to its `format_type(atttypid, atttypmod)` text.

  Returns `%{}` when the catalog is permanently unreadable (no privilege on `pg_attribute`,
  missing object; cached, with a warning once per repo) and the caller falls back to the
  Ecto type mapping. Transient failures (timeouts, failover) are re-raised and never
  cached. Raises `ArgumentError` inside an open transaction.
  """
  @spec column_types(module(), String.t(), String.t()) :: %{String.t() => String.t()}
  def column_types(repo, schema, table) when is_binary(schema) and is_binary(table) do
    columns(repo, schema, table).types
  end

  @doc """
  Maps each column of `schema.table` to its `pg_type.typcategory` letter (`"S"` string,
  `"E"` enum, `"N"` numeric, ...). A domain carries its base type's category. Loaded together
  with `column_types/3`; `%{}` when the catalog is unreadable.
  """
  @spec column_categories(module(), String.t(), String.t()) :: %{String.t() => String.t()}
  def column_categories(repo, schema, table) when is_binary(schema) and is_binary(table) do
    columns(repo, schema, table).categories
  end

  @doc """
  Maps each column of `schema.table` that has a default expression to that expression's
  text (`pg_get_expr`). An identity `BY DEFAULT` column maps to `nextval(<sequence>)`, a domain default applies
  when the column has none, and generated columns have no default (PostgREST's
  `SchemaCache`).

  Loaded with an empty `search_path`, so a default such as `test.next_code()` is schema
  qualified and stays correct when spliced into a statement that runs under another
  `search_path`. `%{}` when the catalog is unreadable. Raises `ArgumentError` inside an
  open transaction.
  """
  @spec column_defaults(module(), String.t(), String.t()) :: %{String.t() => String.t()}
  def column_defaults(repo, schema, table) when is_binary(schema) and is_binary(table) do
    cached(repo, :defaults, {schema, table}, %{}, fn ->
      load(repo, fn -> fetch_defaults(repo, schema, table) end)
    end)
  end

  @doc """
  The server facts of `repo` (`PgRest.Catalog.Facts`): the `pg_timezone_names`, the
  `server_version_num` and whether the login role (`session_user`, never `current_user`) is a
  superuser or `BYPASSRLS`, and the role settings RLS mode applies (PostgREST's
  `queryRoleSettings`). Two queries, cached under `{PgRest.Catalog, repo, :facts, :server}`
  until `forget/1`.

  `PgRest.Plug` warms it before opening the request transaction, so the query never runs after
  a request switched roles. A failure raises and is not cached.
  """
  @spec facts(module()) :: Facts.t()
  def facts(repo) do
    key = {__MODULE__, repo, :facts, :server}

    case :persistent_term.get(key, :miss) do
      :miss -> tap(fetch_facts(repo), &:persistent_term.put(key, &1))
      %Facts{} = facts -> facts
    end
  end

  defp fetch_facts(repo) do
    %{rows: [[zones, version, bypasses?]]} = repo.query!(@facts_sql, [], repo_opts())

    %Facts{
      timezones: MapSet.new(zones),
      server_version_num: version,
      bypasses_rls?: bypasses?,
      role_settings: fetch_role_settings(repo, version)
    }
  end

  # `has_parameter_privilege/3` exists from Postgres 15.
  defp fetch_role_settings(repo, version) do
    sql = if version >= 150_000, do: @role_settings_15, else: @role_settings_pre15
    %{rows: rows} = repo.query!(sql, [], repo_opts())

    Enum.group_by(rows, fn [role, _, _] -> role end, fn [_, name, value] -> {name, value} end)
  end

  defp repo_opts, do: Executor.repo_opts(nil, %{})

  defp columns(repo, schema, table) do
    cached(repo, :columns, {schema, table}, @no_columns, fn ->
      load(repo, fn -> fetch_columns(repo, schema, table) end)
    end)
  end

  @doc "Clears every cached catalog entry for `repo`, and the info memoized from it (for tests)."
  @spec forget(module()) :: :ok
  def forget(repo) do
    for {{__MODULE__, ^repo, _kind, _table} = key, _value} <- :persistent_term.get() do
      :persistent_term.erase(key)
    end

    :persistent_term.erase({__MODULE__, repo, :warned})
    :ok
  end

  # --- shared plumbing (column_defaults/3 reuses these) ---------------------------

  defp cached(repo, kind, table, empty, loader) do
    key = {__MODULE__, repo, kind, table}

    case :persistent_term.get(key, :miss) do
      :miss -> store(key, empty, loader.())
      value -> value
    end
  end

  # A permanently failed load is cached as `empty` so an unreadable catalog is not queried
  # per request.
  defp store(key, _empty, {:ok, value}) do
    :persistent_term.put(key, value)
    value
  end

  defp store(key, empty, :error) do
    :persistent_term.put(key, empty)
    empty
  end

  defp load(repo, fun) do
    with_empty_search_path(repo, __MODULE__, fun)
  rescue
    error in Postgrex.Error ->
      if permanent?(error) do
        warn_once(repo, error)
        :error
      else
        reraise error, __STACKTRACE__
      end
  end

  @doc false
  # Runs `fun` in its own transaction with an empty local `search_path`, so `format_type` and
  # `pg_get_expr` qualify every non-`pg_catalog` name. `PgRest.Function.Introspect` shares it.
  # Raises `ArgumentError`, naming `caller`, inside an open transaction, where the setting
  # would leak.
  @spec with_empty_search_path(module(), module(), (-> result)) ::
          {:ok, result} | {:error, term()}
        when result: term()
  def with_empty_search_path(repo, caller, fun) do
    if repo.in_transaction?() do
      raise ArgumentError,
            "#{inspect(caller)} cannot load inside a transaction (its local search_path would " <>
              "leak into the request); resolve catalog data before opening one"
    end

    repo.transaction(
      fn ->
        repo.query!("SELECT set_config('search_path', '', true)", [], repo_opts())
        fun.()
      end,
      repo_opts()
    )
  end

  # Privilege and missing-object failures will not fix themselves; anything else (timeouts,
  # failover, serialization, lock waits) is transient and must not poison the cache.
  defp permanent?(%Postgrex.Error{postgres: %{code: code}}),
    do: code in @permanent_codes

  defp permanent?(_error), do: false

  defp warn_once(repo, error) do
    key = {__MODULE__, repo, :warned}

    Options.log_once(key, fn ->
      Logger.warning(
        "PgRest.Catalog could not read the catalog for #{inspect(repo)}; filter casts fall " <>
          "back to the Ecto type mapping (#{Exception.message(error)})"
      )
    end)
  end

  defp fetch_columns(repo, schema, table) do
    %{rows: rows} = repo.query!(@columns_sql, [schema, table], repo_opts())

    {types, categories} = typed_rows(rows)
    %{types: Map.new(types), categories: categories}
  end

  @doc false
  # `[name, type, typcategory]` catalog rows as `{[{name, type}], %{name => typcategory}}`, in
  # row order. `PgRest.Function.Introspect` reads its result columns the same way.
  @spec typed_rows([[String.t()]]) :: {[{String.t(), String.t()}], %{String.t() => String.t()}}
  def typed_rows(rows) do
    {Enum.map(rows, fn [name, type, _category] -> {name, type} end),
     Map.new(rows, fn [name, _type, category] -> {name, category} end)}
  end

  defp fetch_defaults(repo, schema, table) do
    %{rows: rows} = repo.query!(@defaults_sql, [schema, table], repo_opts())
    Map.new(rows, fn [name, expression] -> {name, expression} end)
  end
end
