defmodule PgRest.StatementCacheTest do
  use ExUnit.Case, async: false

  alias PgRest.Compat.{Repo, Resources, SupabaseRepo}
  alias PgRest.{Executor, Prefer, StatementCache}
  alias PgRest.Test.TelemetryProbe

  # Every test starts from empty tables: restarting their owner recreates them.
  setup do
    restart_cache!()
    start_supervised!({PgRest.Registry, modules: Resources.all()})
    :ok
  end

  defp restart_cache! do
    :ok = Supervisor.terminate_child(PgRest.Supervisor, PgRest.Cache)
    {:ok, _pid} = Supervisor.restart_child(PgRest.Supervisor, PgRest.Cache)
  end

  defp named?(opts), do: Keyword.has_key?(opts, :cache_statement)

  describe "query_opts/2" do
    test "promotes a text after promote_after sightings" do
      config = [promote_after: 3, max: 10]
      sql = "SELECT 1 /* promote */"

      assert [[], [], []] == for(_ <- 1..3, do: StatementCache.query_opts(sql, config))
      assert [cache_statement: "pgrest_" <> hex] = StatementCache.query_opts(sql, config)
      assert byte_size(hex) == 32
      assert hex =~ ~r/^[0-9a-f]{32}$/
      assert [cache_statement: "pgrest_" <> ^hex] = StatementCache.query_opts(sql, config)
    end

    test "promotes at most max texts and never evicts" do
      config = [promote_after: 0, max: 2]

      assert named?(StatementCache.query_opts("SELECT 1 /* a */", config))
      assert named?(StatementCache.query_opts("SELECT 1 /* b */", config))
      refute named?(StatementCache.query_opts("SELECT 1 /* c */", config))
      refute named?(StatementCache.query_opts("SELECT 1 /* c */", config))
      assert named?(StatementCache.query_opts("SELECT 1 /* a */", config))
    end

    test "concurrent first sightings of one text take one slot" do
      config = [promote_after: 0, max: 2]

      1..100
      |> Task.async_stream(fn _ -> StatementCache.query_opts("SELECT 1 /* race */", config) end)
      |> Stream.run()

      assert named?(StatementCache.query_opts("SELECT 1 /* other */", config))
      refute named?(StatementCache.query_opts("SELECT 1 /* third */", config))
    end

    test "a rejected claim leaves the counter and the cap usable" do
      config = [promote_after: 0, max: 1]

      assert named?(StatementCache.query_opts("SELECT 1 /* a */", config))
      for _ <- 1..5, do: refute(named?(StatementCache.query_opts("SELECT 1 /* b */", config)))

      assert [{:promoted, 1}] = :ets.lookup(StatementCache, :promoted)
      assert [_one] = named_entries()
    end

    test "interleaved claims over the cap roll back deterministically" do
      config = [promote_after: 0, max: 1]
      hash_a = :crypto.hash(:sha256, "interleave a")
      hash_b = :crypto.hash(:sha256, "interleave b")

      # Both callers reserve before either counts: the room for one is claimed twice.
      assert {:ok, name_a} = StatementCache.reserve(hash_a)
      assert {:ok, _name_b} = StatementCache.reserve(hash_b)
      assert {:taken, ^name_a} = StatementCache.reserve(hash_a)
      assert length(named_entries()) == 2

      assert [cache_statement: ^name_a] = StatementCache.confirm(hash_a, name_a, config)
      assert [] == StatementCache.confirm(hash_b, "unused", config)

      assert [{:promoted, 1}] = :ets.lookup(StatementCache, :promoted)
      assert [{{:named, ^hash_a}, ^name_a}] = named_entries()
    end

    test "concurrent promotion fills the cap exactly and never shuts it off early" do
      config = [promote_after: 0, max: 40]
      texts = for n <- 1..200, do: "SELECT #{n} /* wave */"

      # Racing waves may reject claims transiently; a later sighting retries them.
      for _ <- 1..3 do
        texts
        |> Task.async_stream(&StatementCache.query_opts(&1, config), max_concurrency: 50)
        |> Stream.run()
      end

      for text <- texts, do: StatementCache.query_opts(text, config)

      assert [{:promoted, 40}] = :ets.lookup(StatementCache, :promoted)
      assert length(named_entries()) == 40
    end

    test "false never names" do
      for _ <- 1..10, do: assert([] == StatementCache.query_opts("SELECT 1", false))
    end

    test "bounds the sightings table" do
      config = [promote_after: 1_000_000, max: 2]
      for n <- 1..100, do: StatementCache.query_opts("SELECT #{n}", config)
      assert :ets.info(StatementCache, :size) <= 10 * 2 + 3
    end

    test "is inert without the table, and warns once" do
      :ok = Supervisor.terminate_child(PgRest.Supervisor, PgRest.Cache)
      on_exit(fn -> Supervisor.restart_child(PgRest.Supervisor, PgRest.Cache) end)
      :persistent_term.erase({StatementCache, :warned_missing_table})

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          for _ <- 1..3,
              do: assert([] == StatementCache.query_opts("SELECT 1", promote_after: 0, max: 1))
        end)

      assert [_once] = Regex.scan(~r/no table \(is the :pgrest application started\?\)/, log)
    end
  end

  defp named_entries, do: :ets.match_object(StatementCache, {{:named, :_}, :_})

  test "promoted executor statements cannot carry results between database roles" do
    SupabaseRepo.checkout(fn ->
      SupabaseRepo.query!(
        "CREATE FUNCTION public.pgrest_role_cache_probe() RETURNS text LANGUAGE sql IMMUTABLE AS $$ SELECT 'secret'::text $$"
      )

      SupabaseRepo.query!(
        "REVOKE EXECUTE ON FUNCTION public.pgrest_role_cache_probe() FROM PUBLIC, anon"
      )

      SupabaseRepo.query!(
        "GRANT EXECUTE ON FUNCTION public.pgrest_role_cache_probe() TO authenticated"
      )

      backend = SupabaseRepo.query!("SELECT pg_backend_pid()").rows

      run = fn sql, role ->
        config = %{
          statement_cache: [promote_after: 2, max: 50],
          gucs: [{"role", role}],
          role_settings: [{"plan_cache_mode", "auto"}],
          authenticated?: role != "anon"
        }

        Executor.transaction(
          SupabaseRepo,
          %Prefer{},
          fn ->
            assert SupabaseRepo.query!("SELECT pg_backend_pid()").rows == backend
            Executor.count(SupabaseRepo, {sql, []}, config)
          end,
          config
        )
      end

      try do
        for {sql, length} <- [
              {"SELECT length(public.privileged_hello('x')) /* upstream role isolation */", 21},
              {"SELECT length(public.pgrest_role_cache_probe()) /* role isolation */", 6}
            ] do
          for _ <- 1..8, do: assert(run.(sql, "authenticated") == {:ok, length})

          assert [[name, generic_plans]] =
                   SupabaseRepo.query!(
                     "SELECT name, generic_plans FROM pg_prepared_statements WHERE statement=$1",
                     [sql]
                   ).rows

          assert name =~ "pgrest_"
          assert generic_plans > 0

          for _ <- 1..4 do
            assert {:error, %{code: "42501", status: 401}} = run.(sql, "anon")
            assert run.(sql, "authenticated") == {:ok, length}
          end
        end
      after
        SupabaseRepo.query!("DROP FUNCTION public.pgrest_role_cache_probe()")
      end
    end)
  end

  describe "through the plug" do
    defp request(path, opts) do
      conn = Plug.Test.conn("GET", path)
      PgRest.Plug.call(conn, PgRest.Plug.init([repo: Repo] ++ opts))
    end

    defp prepared_flags do
      for {_event, _measurements, %{sql: sql, prepared: prepared}} <- TelemetryProbe.drain(),
          do: {String.starts_with?(sql, "WITH pgrst_source"), prepared}
    end

    test "the fourth execution of a read runs prepared" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      cache = [promote_after: 3, max: 50]

      for _ <- 1..5,
          do: assert(%{status: 200} = request("/items?select=id&limit=1", statement_cache: cache))

      assert [false, false, false, true, true] ==
               for({true, prepared} <- prepared_flags(), do: prepared)
    end

    test "statement_cache: false never prepares" do
      TelemetryProbe.attach([:pgrest, :query, :stop])

      for _ <- 1..6, do: request("/items?select=id&limit=1", statement_cache: false)

      assert Enum.all?(prepared_flags(), fn {_read?, prepared} -> prepared == false end)
    end

    test "alias-minted texts leave at most max named statements on the connection" do
      max = 5

      # Pooled connections keep statements named by earlier tests, so count what is added.
      added =
        Repo.checkout(fn ->
          before = named_statements()

          for n <- 1..1_000 do
            assert %{status: 200} =
                     request("/items?select=a#{n}:id&limit=1",
                       statement_cache: [promote_after: 0, max: max]
                     )
          end

          MapSet.difference(named_statements(), before)
        end)

      assert MapSet.size(added) in 1..max//1
    end

    defp named_statements do
      "SELECT name FROM pg_prepared_statements WHERE name LIKE 'pgrest_%'"
      |> Repo.query!([])
      |> Map.fetch!(:rows)
      |> MapSet.new(fn [name] -> name end)
    end
  end
end
