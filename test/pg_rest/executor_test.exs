defmodule PgRest.ExecutorTest do
  use ExUnit.Case, async: false

  alias PgRest.Compat.{Repo, Resources}
  alias PgRest.{Error, Executor, Prefer}
  alias PgRest.Error.Translate
  alias PgRest.Test.TelemetryProbe

  setup_all do
    Repo.query!("CREATE TABLE IF NOT EXISTS public.pgrest_tx_probe (n integer)")
    :ok
  end

  setup do
    start_supervised!({PgRest.Registry, modules: Resources.all()})
    Repo.query!("TRUNCATE public.pgrest_tx_probe")
    :ok
  end

  defp probe_count,
    do: Repo.query!("SELECT count(*) FROM public.pgrest_tx_probe").rows |> hd() |> hd()

  describe "repo_opts/2" do
    test "merges log, telemetry options and the timeout" do
      assert [log: false, telemetry_options: [pgrest: true]] =
               Executor.repo_opts(nil, %{})

      opts = Executor.repo_opts("SELECT 1", %{statement_timeout: "50ms", statement_cache: false})
      assert opts[:log] == false
      assert Keyword.has_key?(opts, :telemetry_event) and opts[:telemetry_event] == nil
      assert opts[:telemetry_options] == [pgrest: true]
      assert opts[:timeout] == 1_050
      refute Keyword.has_key?(opts, :cache_statement)
    end

    test "parses Postgres interval strings" do
      assert Executor.interval_ms("50ms") == {:ok, 50}
      assert Executor.interval_ms("5s") == {:ok, 5_000}
      assert Executor.interval_ms("2min") == {:ok, 120_000}
      assert Executor.interval_ms("1h") == {:ok, 3_600_000}
      assert Executor.interval_ms("250") == {:ok, 250}
      assert Executor.interval_ms("5 parsecs") == :error
      assert Executor.interval_ms("0s") == :error
    end
  end

  describe "transaction/4" do
    test "commits and returns the result" do
      assert :done =
               Executor.transaction(Repo, %Prefer{}, fn ->
                 Repo.query!("INSERT INTO public.pgrest_tx_probe VALUES (1)")
                 :done
               end)

      assert probe_count() == 1
    end

    test "tx=rollback rolls back and still returns the computed response" do
      assert :done =
               Executor.transaction(Repo, %Prefer{tx: :rollback}, fn ->
                 Repo.query!("INSERT INTO public.pgrest_tx_probe VALUES (1)")
                 :done
               end)

      assert probe_count() == 0
    end

    test "an error result rolls back" do
      error = %Error{status: 400, code: "X", message: "m"}

      assert {:error, ^error} =
               Executor.transaction(Repo, %Prefer{}, fn ->
                 Repo.query!("INSERT INTO public.pgrest_tx_probe VALUES (1)")
                 {:error, error}
               end)

      assert probe_count() == 0
    end

    test "the one setup statement sets the search path and statement timeout" do
      TelemetryProbe.attach([:pgrest, :query, :start])
      config = %{search_path: ["test", "public"], statement_timeout: "50ms"}

      assert {~S("test", "public"), "50ms"} =
               Executor.transaction(
                 Repo,
                 %Prefer{},
                 fn ->
                   {Repo.query!("SHOW search_path").rows |> hd() |> hd(),
                    Repo.query!("SHOW statement_timeout").rows |> hd() |> hd()}
                 end,
                 config
               )

      assert [{_e, _m, %{sql: sql, params_count: 2}}] = TelemetryProbe.drain()

      assert sql ==
               "SELECT set_config('search_path', $1, true), set_config('statement_timeout', $2, true)"
    end

    test "a Prefer timezone is one more GUC in the same setup statement" do
      TelemetryProbe.attach([:pgrest, :query, :start])

      config = %{
        search_path: ["test", "public"],
        statement_timeout: "50ms",
        timezone: "Asia/Tokyo"
      }

      assert "Asia/Tokyo" =
               Executor.transaction(
                 Repo,
                 %Prefer{},
                 fn -> Repo.query!("SHOW timezone").rows |> hd() |> hd() end,
                 config
               )

      assert [{_e, _m, %{sql: sql, params_count: 3}}] = TelemetryProbe.drain()

      assert sql ==
               "SELECT set_config('search_path', $1, true), set_config('statement_timeout', $2, true), set_config('timezone', $3, true)"
    end

    test "the timeout cancels a slow statement with a translated 57014" do
      config = %{statement_timeout: "50ms"}

      # The server cancels at 50ms; the long sleep leaves no way to finish first, however
      # loaded the machine is.
      result =
        Executor.transaction(
          Repo,
          %Prefer{},
          fn ->
            case Repo.query("SELECT pg_sleep(5)", [], Executor.repo_opts(nil, config)) do
              {:ok, _} -> :finished
              {:error, exception} -> {:error, Translate.from_exception(exception, :anon)}
            end
          end,
          config
        )

      assert {:error, %Error{code: "57014", status: 500}} = result
    end

    test "the deadline covers several statements, each within the statement timeout" do
      config = %{statement_timeout: "1500ms"}

      # Six 500ms statements (3s) outlast a one-statement deadline (2.5s) but not the
      # transaction's own (4 * 1500ms + 1s); each is a third of the statement timeout, so a
      # loaded machine cannot trip it.
      result =
        Executor.transaction(
          Repo,
          %Prefer{},
          fn ->
            for _ <- 1..6 do
              Repo.query!("SELECT pg_sleep(0.5)", [], Executor.repo_opts(nil, config))
            end

            :done
          end,
          config
        )

      assert result == :done
      assert %{rows: [[1]]} = Repo.query!("SELECT 1")
    end

    test "a swallowed database error ends as a generic 500 and logs no data" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          result =
            Executor.transaction(Repo, %Prefer{}, fn ->
              Repo.query("SELECT 1/0 /* SENTINEL-9c1 */")
              :ok
            end)

          assert {:error, %Error{status: 500, code: "PGRSTX00"}} = result
        end)

      assert log =~ "PgRest: unexpected :rollback while querying"
      refute log =~ "SENTINEL-9c1"
      assert %Error{status: 500, code: "PGRSTX00"} = Translate.from_exception(:rollback, :anon)
    end

    test "settings do not leak out of the transaction" do
      Executor.transaction(Repo, %Prefer{}, fn -> :ok end, %{search_path: ["test"]})
      assert [["\"$user\", public"]] = Repo.query!("SHOW search_path").rows
    end

    test "a connection failure is a 503" do
      assert %Error{status: 503, code: "PGRST000", message: "Database connection error."} =
               Translate.from_exception(%DBConnection.ConnectionError{message: "down"}, :anon)

      assert %Error{status: 503, code: "PGRST000"} =
               Translate.from_exception(%Postgrex.Error{message: "tcp connect"}, :anon)
    end
  end
end
