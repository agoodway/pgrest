defmodule PgRest.Compat.Fixture do
  @moduledoc """
  Rebuilds the `pgrest_compat` and `pgrest_supabase` databases and waits for PostgREST
  to see them, and `pgrest_safeupdate` when its server is up.

  Test harness only. `load!/0` drops and recreates the databases every run.
  """

  alias PgRest.Compat.{AuthenticatorRepo, Repo, SafeupdateRepo, SupabaseRepo}

  # PostgREST backs off its DB reconnect up to 32s after the database is dropped,
  # so the wait must outlast one full backoff step.
  @reload_timeout 60_000
  @poll_interval 200
  @servers %{
    default: {"PGREST_POSTGREST_URL", "http://localhost:54321"},
    limits: {"PGREST_POSTGREST_LIMITS_URL", "http://localhost:54329"},
    supabase: {"PGREST_POSTGREST_SUPABASE_URL", "http://localhost:54323"}
  }

  # One entry per fixture database. `schema` and `grant` describe the reload-marker view:
  # it lives in the PostgREST instance's default schema and, when `grant` is set, is
  # readable by that anonymous role. `servers` are the PostgREST instances serving it.
  @fixtures %{
    test: %{
      database: "pgrest_compat",
      sql: [Path.expand("fixture.sql", __DIR__)],
      repo: Repo,
      schemas: ["test"],
      schema: "test",
      grant: nil,
      servers: [:default, :limits]
    },
    supabase: %{
      database: "pgrest_supabase",
      sql: [
        Path.expand("supabase/roles.sql", __DIR__),
        Path.expand("supabase/fixture.sql", __DIR__)
      ],
      repo: SupabaseRepo,
      schemas: ["public", "personal"],
      schema: "public",
      grant: "anon",
      servers: [:supabase]
    }
  }

  # The pg-safeupdate database lives on its own Postgres (compose profile `safeupdate`) and
  # has no PostgREST, marker view or sequence baseline.
  @safeupdate %{
    database: "pgrest_safeupdate",
    sql: [Path.expand("safeupdate.sql", __DIR__)],
    repo: SafeupdateRepo
  }

  # Every repo whose pool must be stopped before a database is dropped.
  @repos [Repo, SupabaseRepo, AuthenticatorRepo, SafeupdateRepo]

  @type fixture :: :test | :supabase
  @type baseline :: %{
          repo: module(),
          sequences: %{String.t() => {integer(), boolean()}}
        }

  @doc "Returns `PGREST_JS_PORT`, defaulting to the JS harness port 54328."
  @spec js_port() :: integer()
  def js_port, do: System.get_env("PGREST_JS_PORT", "54328") |> String.to_integer()

  @doc "Returns the base URL of a PostgREST server."
  @spec postgrest_url(:default | :limits | :supabase) :: String.t()
  def postgrest_url(server \\ :default) do
    {env, default} = Map.fetch!(@servers, server)
    System.get_env(env, default)
  end

  @doc """
  Drops and recreates every fixture database, runs its SQL, captures its sequence
  baseline, then waits until each PostgREST instance serves a freshly created marker
  view.

  Stops every repo first if running, and starts all four again (`Repo`, `SupabaseRepo`,
  `AuthenticatorRepo`, and `SafeupdateRepo` when its server is up) linked to the caller, so callers start none themselves. When the
  `db_safeupdate` server is reachable it also recreates `pgrest_safeupdate` and starts
  `SafeupdateRepo` (see `safeupdate_loaded?/0`).
  """
  @spec load!() :: :ok
  def load! do
    Enum.each(@repos, &stop_repo/1)
    ensure_postgres_reachable!()

    fixtures =
      for {name, fixture} <- @fixtures do
        recreate_database!(fixture)
        run_fixture!(fixture)
        :persistent_term.put({__MODULE__, :baseline, name}, capture_baseline(fixture))
        marker = create_marker_view!(fixture)
        :persistent_term.put({__MODULE__, :marker, name}, marker)
        {fixture, marker}
      end

    Enum.each(fixtures, fn {fixture, marker} -> wait_for_postgrest!(fixture, marker) end)
    {:ok, _} = Repo.start_link()
    {:ok, _} = SupabaseRepo.start_link()
    {:ok, _} = AuthenticatorRepo.start_link()
    load_safeupdate!()
  end

  @doc "Whether `load!/0` found the pg-safeupdate server and loaded `pgrest_safeupdate`."
  @spec safeupdate_loaded?() :: boolean()
  def safeupdate_loaded?, do: :persistent_term.get({__MODULE__, :safeupdate}, false)

  defp load_safeupdate! do
    loaded? = repo_reachable?(SafeupdateRepo)

    if loaded? do
      recreate_database!(@safeupdate)
      run_fixture!(@safeupdate)
      {:ok, _} = SafeupdateRepo.start_link()
    end

    :persistent_term.put({__MODULE__, :safeupdate}, loaded?)
    :ok
  end

  @doc """
  The sequence baseline `load!/0` captured for a fixture database: `{last_value,
  is_called}` for every sequence in its exposed schemas, plus the repo that resets them.

  The brief types the values as `integer()`; `is_called` is needed to restore a
  never-used sequence exactly, so the value is a tuple.
  """
  @spec sequence_baseline(fixture()) :: baseline()
  def sequence_baseline(fixture \\ :test) do
    :persistent_term.get({__MODULE__, :baseline, fixture})
  end

  @doc "The reload-marker view `load!/0` created last in a fixture (test support only)."
  @spec last_reload_marker(fixture()) :: String.t()
  def last_reload_marker(fixture), do: :persistent_term.get({__MODULE__, :marker, fixture})

  @doc """
  Runs `sql` (one `RETURNING id` row) through `repo` and rolls it back, returning the
  generated id: two calls tell whether a sequence was reset in between.
  """
  @spec rolled_back_insert!(module(), String.t()) :: term()
  def rolled_back_insert!(repo, sql) do
    {:error, id} =
      repo.transaction(fn ->
        %{rows: [[id]]} = repo.query!(sql)
        repo.rollback(id)
      end)

    id
  end

  @doc "The schemas a fixture database exposes."
  @spec schemas(fixture()) :: [String.t()]
  def schemas(fixture), do: Map.fetch!(@fixtures, fixture).schemas

  @doc "Resets every sequence in `baseline` with `setval`, through the baseline's repo."
  @spec reset_sequences!(baseline()) :: :ok
  def reset_sequences!(%{repo: repo, sequences: sequences}) do
    Enum.each(sequences, fn {name, {last, called?}} ->
      repo.query!("SELECT setval($1::text::regclass, $2, $3)", [name, last, called?])
    end)
  end

  defp stop_repo(repo) do
    case Process.whereis(repo) do
      nil -> :ok
      pid -> Supervisor.stop(pid)
    end
  end

  defp capture_baseline(%{database: database, repo: repo, schemas: schemas}) do
    %{rows: rows} =
      with_conn(repo, database, fn conn ->
        Postgrex.query!(
          conn,
          """
          SELECT format('%I.%I', schemaname, sequencename),
                 coalesce(last_value, start_value),
                 last_value IS NOT NULL
            FROM pg_sequences
           WHERE schemaname = ANY($1)
          """,
          [schemas]
        )
      end)

    sequences = Map.new(rows, fn [name, last, called?] -> {name, {last, called?}} end)
    %{repo: repo, sequences: sequences}
  end

  defp ensure_postgres_reachable! do
    unless repo_reachable?(Repo) do
      %{hostname: host, port: port} = Map.new(Repo.config())

      raise "Postgres is not reachable at #{host}:#{port} (PGREST_DB_PORT). " <>
              "Run `docker compose up -d db` first."
    end
  end

  defp repo_reachable?(repo) do
    %{hostname: host, port: port} = Map.new(repo.config())
    tcp_open?(host, port)
  end

  # An admin connection to `database` on the server `repo` is configured for.
  defp admin_opts(repo, database) do
    repo.config()
    |> Keyword.take([:hostname, :port, :username, :password])
    |> Keyword.put(:database, database)
  end

  defp with_conn(repo, database, fun) do
    {:ok, conn} = Postgrex.start_link(admin_opts(repo, database))

    try do
      fun.(conn)
    after
      GenServer.stop(conn)
    end
  end

  defp recreate_database!(%{database: database, repo: repo}) do
    with_conn(repo, "postgres", fn conn ->
      Postgrex.query!(conn, "DROP DATABASE IF EXISTS #{database} WITH (FORCE)", [])
      Postgrex.query!(conn, "CREATE DATABASE #{database}", [])
    end)
  end

  # Postgrex types `query_type: :text` out of its option list, though it is supported.
  @dialyzer {:nowarn_function, run_fixture!: 1}
  defp run_fixture!(%{database: database, repo: repo, sql: paths}) do
    with_conn(repo, database, fn conn ->
      Enum.each(paths, &Postgrex.query!(conn, File.read!(&1), [], query_type: :text))
    end)
  end

  defp create_marker_view!(%{database: database, repo: repo, schema: schema, grant: grant}) do
    marker = "pgrst_reload_#{System.os_time(:millisecond)}"

    with_conn(repo, database, fn conn ->
      Postgrex.query!(conn, "CREATE VIEW #{schema}.#{marker} AS SELECT 1 AS one", [])

      if grant, do: Postgrex.query!(conn, "GRANT SELECT ON #{schema}.#{marker} TO #{grant}", [])

      notify_reload!(conn)
    end)

    marker
  end

  # `reload config` re-reads the API roles' ALTER ROLE settings (roles.sql).
  defp notify_reload!(conn) do
    Postgrex.query!(conn, "NOTIFY pgrst, 'reload schema'", [])
    Postgrex.query!(conn, "NOTIFY pgrst, 'reload config'", [])
  end

  defp wait_for_postgrest!(%{database: database, repo: repo, servers: servers}, marker) do
    deadline = System.monotonic_time(:millisecond) + @reload_timeout

    # One connection serves every NOTIFY of the poll loop.
    with_conn(repo, database, fn conn ->
      servers
      |> Enum.filter(&poll?/1)
      |> Enum.each(&poll!(postgrest_url(&1) <> "/" <> marker, deadline, conn))
    end)
  end

  # Skip a server unless it is reachable or its URL env var was set explicitly.
  defp poll?(server) do
    {env, _default} = Map.fetch!(@servers, server)
    %URI{host: host, port: port} = server |> postgrest_url() |> URI.parse()

    System.get_env(env) != nil or tcp_open?(host, port)
  end

  defp tcp_open?(host, port) do
    case :gen_tcp.connect(to_charlist(host), port, [], 500) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      {:error, _} ->
        false
    end
  end

  defp poll!(url, deadline, conn) do
    case Req.get(url, retry: false, receive_timeout: 2_000) do
      {:ok, %{status: 200}} ->
        :ok

      other ->
        if System.monotonic_time(:millisecond) >= deadline do
          raise "PostgREST did not serve #{url} within #{@reload_timeout}ms: #{inspect(other)}"
        end

        Process.sleep(@poll_interval)
        notify_reload!(conn)
        poll!(url, deadline, conn)
    end
  end
end
