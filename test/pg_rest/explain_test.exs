defmodule PgRest.ExplainTest do
  # Not async: registries over the shared compat fixture, committed sequences and telemetry.
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [header: 2, json: 1, register: 1, request: 5]

  alias PgRest.{Authorization, Error, Executor}
  alias PgRest.Compat.{Fixture, Functions, Repo, Resources, Scenario}
  alias PgRest.SQL.Explain
  alias PgRest.Test.{PlugResources, TelemetryProbe}
  alias PgRest.Test.Policies.{AllowAll, Neither}

  @opts [tx_end: :commit_allow_override, plan_enabled: true]
  @json ~s(application/vnd.pgrst.plan+json; for="application/json")

  defp call(method, path, headers, body \\ nil, opts \\ []),
    do: request(method, path, body, headers, Keyword.merge(@opts, opts))

  defp accept(type), do: [{"accept", type}]
  defp rollback(accept), do: [{"accept", accept}, {"prefer", "tx=rollback"}]

  defp count(table), do: Repo.query!("SELECT count(*) FROM test.#{table}").rows |> hd() |> hd()

  defp callcounter_value do
    %{rows: [[value, called?]]} =
      Repo.query!("SELECT last_value, is_called FROM test.callcounter_count")

    if called?, do: value, else: value - 1
  end

  # An authorization module that exports `authorize/4` only.
  defmodule DenyProjectsExplain do
    @moduledoc false
    def authorize(_conn, PgRest.Compat.Resources.Projects, :explain, _context), do: {:error, "no"}
    def authorize(_conn, _resource, _operation, _context), do: :ok
  end

  defmodule DenyFunctionExplain do
    @moduledoc false
    def authorize(_conn, %PgRest.Function{}, :explain, _context), do: {:error, "no"}
    def authorize(_conn, _resource, _operation, _context), do: :ok
  end

  # Exports `authorize_query/5` only, as a deny-by-default policy library does.
  defmodule QueryOnly do
    @moduledoc false
    def authorize_query(_conn, _resource, :explain, _query, _context), do: {:error, :unsupported}
    def authorize_query(_conn, _resource, _operation, query, _context), do: {:ok, query}
  end

  defmodule QueryOnlyAllows do
    @moduledoc false
    def authorize_query(_conn, _resource, :explain, query, _context),
      do: {:ok, query, columns: :all}

    def authorize_query(_conn, _resource, :read, query, _context),
      do: {:ok, query, columns: :all}

    def authorize_query(_conn, _resource, _operation, _query, _context), do: {:error, :no}
  end

  describe "SQL.Explain.wrap/2" do
    test "names the format, then the options in the order given, uppercase" do
      assert Explain.wrap({"SELECT 1", []}, %{format: :json, options: [:analyze, :verbose]}) ==
               {"EXPLAIN (FORMAT JSON, ANALYZE, VERBOSE) SELECT 1", []}
    end

    test "text without options, and every option" do
      assert Explain.wrap({"SELECT $1", ["x"]}, %{format: :text, options: []}) ==
               {"EXPLAIN (FORMAT TEXT) SELECT $1", ["x"]}

      assert {sql, []} =
               Explain.wrap({"SELECT 1", []}, %{
                 format: :text,
                 options: [:analyze, :verbose, :settings, :buffers, :wal]
               })

      assert sql == "EXPLAIN (FORMAT TEXT, ANALYZE, VERBOSE, SETTINGS, BUFFERS, WAL) SELECT 1"
    end
  end

  describe "Executor.explain/3" do
    test "JSON: the plan value, re-encoded" do
      assert {:ok, body} = Executor.explain(Repo, {"EXPLAIN (FORMAT JSON) SELECT 1", []})

      assert [%{"Plan" => %{"Node Type" => "Result"}}] = Jason.decode!(body)
      refute body =~ "\n"
    end

    test "TEXT: the rows joined by a newline" do
      assert {:ok, body} = Executor.explain(Repo, {"EXPLAIN (FORMAT TEXT) SELECT 1", []})

      assert body =~ ~r/\AResult  \(cost=.*\)\z/
    end

    test "a database error is a PostgREST error" do
      assert {:error, %Error{code: "42P01"}} =
               Executor.explain(Repo, {"EXPLAIN SELECT * FROM test.nope", []})
    end
  end

  describe "reads" do
    setup do
      register(Resources.all())
      :ok
    end

    test "a JSON plan: Content-Type echoes the media type, no Content-Range" do
      conn = call("GET", "/projects?id=in.(1,2,3)", accept("application/vnd.pgrst.plan+json"))

      assert conn.status == 200
      assert header(conn, "content-type") == @json <> "; charset=utf-8"
      assert header(conn, "content-range") == nil
      assert [%{"Plan" => %{"Node Type" => "Aggregate"}}] = json(conn)
    end

    test "text is the default format" do
      for type <- ["application/vnd.pgrst.plan", "application/vnd.pgrst.plan+text"] do
        conn = call("GET", "/projects?id=in.(1,2,3)", accept(type))

        assert conn.status == 200

        assert header(conn, "content-type") ==
                 ~s(application/vnd.pgrst.plan+text; for="application/json"; charset=utf-8)

        assert String.starts_with?(conn.resp_body, "Aggregate")
      end
    end

    test "options are echoed in canonical order and reach EXPLAIN" do
      conn =
        call("GET", "/projects", accept(@json <> "; options=wal|buffers|analyze|bogus"))

      assert header(conn, "content-type") ==
               @json <> "; options=analyze|buffers|wal; charset=utf-8"

      assert [%{"Plan" => %{"WAL Records" => 0, "Shared Hit Blocks" => _}}] = json(conn)
    end

    test "verbose lists the columns and settings the search path" do
      conn = call("GET", "/projects", accept(@json <> "; options=verbose|settings"))

      assert [%{"Plan" => plan, "Settings" => %{"search_path" => path}}] = json(conn)
      assert path =~ "test"
      assert %{"Output" => [_ | _]} = plan
    end

    test "for= object explains the object statement and echoes its canonical name" do
      conn =
        call(
          "GET",
          "/projects?id=eq.1",
          accept(
            ~s(application/vnd.pgrst.plan+json; for="application/vnd.pgrst.object"; options=verbose)
          )
        )

      assert header(conn, "content-type") ==
               ~s(application/vnd.pgrst.plan+json; for="application/vnd.pgrst.object+json"; ) <>
                 "options=verbose; charset=utf-8"

      assert [%{"Plan" => %{"Output" => outputs}}] = json(conn)
      assert Enum.any?(outputs, &(&1 =~ "-> 0"))
    end

    test "a one-row object plan does not need one row" do
      conn =
        call(
          "GET",
          "/projects",
          accept(~s(application/vnd.pgrst.plan; for="application/vnd.pgrst.object"))
        )

      assert conn.status == 200
    end

    test "for= a type nothing serves is PGRST107 with the plan type listed" do
      conn = call("GET", "/projects", accept(~s(application/vnd.pgrst.plan+json; for="text/xml")))

      assert conn.status == 406
      assert json(conn)["code"] == "PGRST107"

      assert json(conn)["message"] ==
               ~s(None of these media types are available: application/vnd.pgrst.plan+json; for="text/xml")
    end

    test "an embed, a count and a window are part of the plan" do
      conn =
        call(
          "GET",
          "/clients?select=*,projects(*)&limit=1",
          [{"accept", "application/vnd.pgrst.plan"}, {"prefer", "count=exact"}]
        )

      assert conn.status == 200
      assert conn.resp_body =~ "Limit"
    end

    test "a bad request is its own error, not a plan" do
      assert call("GET", "/nope", accept("application/vnd.pgrst.plan")).status == 404

      conn = call("GET", "/projects?select=nope", accept("application/vnd.pgrst.plan"))
      assert conn.status == 400
      assert json(conn)["code"] == "42703"
    end
  end

  # A plan returns no rows, so `after_load/2` has nothing to redact: the plan is offered.
  describe "an after_load/2 resource" do
    setup do
      register([PlugResources.TrimProjects, PlugResources.TrimClients, PlugResources.TrimTasks])
      :ok
    end

    test "is explained" do
      conn = call("GET", "/projects?select=id", accept("application/vnd.pgrst.plan"))

      assert conn.status == 200
      assert String.starts_with?(conn.resp_body, "Aggregate")
    end
  end

  describe "the explained statement is the one that would run" do
    setup do
      start_supervised!(
        {PgRest.Registry,
         modules: Resources.all(), introspect: [repo: Repo, only: Functions.test_functions()]}
      )

      TelemetryProbe.attach([:pgrest, :query, :start])
      :ok
    end

    defp statements do
      for {_event, _measurements, %{sql: sql, params_count: n}} <- TelemetryProbe.drain(),
          not String.starts_with?(sql, "SELECT set_config"),
          do: {sql, n}
    end

    test "for= text/csv explains the CSV body, header parameter included" do
      path = "/rpc/getallprojects?select=name&limit=1"

      assert call("GET", path, accept("text/csv")).status == 200
      assert [{csv_sql, csv_params}] = statements()
      assert csv_params > 0

      conn = call("GET", path, accept(~s(application/vnd.pgrst.plan+json; for="text/csv")))

      assert conn.status == 200

      assert header(conn, "content-type") ==
               ~s(application/vnd.pgrst.plan+json; for="text/csv"; charset=utf-8)

      assert [{sql, params}] = statements()
      assert sql == "EXPLAIN (FORMAT JSON) " <> csv_sql
      assert params == csv_params
    end

    test "a table read explains the same text a plain read runs" do
      path = "/clients?select=id&order=id&limit=2"

      assert call("GET", path, []).status == 200
      assert [{read_sql, read_params}] = statements()

      assert call("GET", path, accept("application/vnd.pgrst.plan")).status == 200
      assert [{sql, params}] = statements()
      assert sql == "EXPLAIN (FORMAT TEXT) " <> read_sql
      assert params == read_params
    end

    test "EXPLAIN statements are never logged: log: false and no repo query event" do
      conn = call("GET", "/clients?select=id", accept("application/vnd.pgrst.plan"))
      assert conn.status == 200
      assert [{"EXPLAIN" <> _, _}] = statements()
    end
  end

  # `analyze` runs a write, and a sequence advances even when its transaction rolls back: put
  # the fixture's sequences back, as the stateful scenarios do.
  defp reset_sequences_on_exit do
    baseline = Scenario.baseline_for(%{fixture: :test})
    on_exit(fn -> Fixture.reset_sequences!(baseline) end)
  end

  describe "writes" do
    setup do
      register(Resources.all())
      reset_sequences_on_exit()
      :ok
    end

    test "a plan of an insert does not insert" do
      before = count("items")
      conn = call("POST", "/items", accept("application/vnd.pgrst.plan"), %{})

      assert conn.status == 200
      assert conn.resp_body =~ "Insert on items"
      assert header(conn, "content-range") == nil
      assert count("items") == before
    end

    test "update and delete plans change nothing" do
      before = Repo.query!("SELECT name FROM test.projects ORDER BY id").rows

      patch =
        call("PATCH", "/projects?id=eq.1", accept("application/vnd.pgrst.plan"), %{"name" => "x"})

      delete = call("DELETE", "/projects?id=eq.1", accept("application/vnd.pgrst.plan"))

      assert patch.status == 200
      assert patch.resp_body =~ "Update on projects"
      assert delete.status == 200
      assert delete.resp_body =~ "Delete on projects"
      assert Repo.query!("SELECT name FROM test.projects ORDER BY id").rows == before
    end

    test "an upsert plan names its conflict resolution" do
      conn =
        call(
          "POST",
          "/clients",
          [{"accept", "application/vnd.pgrst.plan"}, {"prefer", "resolution=merge-duplicates"}],
          %{"id" => 1, "name" => "x"}
        )

      assert conn.status == 200
      assert conn.resp_body =~ "Conflict Resolution: UPDATE"
    end

    test "analyze with tx=rollback executes the insert and rolls it back" do
      before = count("items")
      conn = call("POST", "/items", rollback(@json <> "; options=analyze"), %{})

      assert conn.status == 200
      assert [%{"Execution Time" => _, "Plan" => %{"Actual Rows" => 1}}] = json(conn)
      assert count("items") == before
    end

    test "analyze without tx=rollback is PGRST107 and inserts nothing" do
      before = count("items")
      conn = call("POST", "/items", accept(@json <> "; options=analyze"), %{})

      assert conn.status == 406
      assert json(conn)["code"] == "PGRST107"
      assert count("items") == before
    end

    test "analyze with tx=rollback under tx_end: :commit is PGRST107 too" do
      before = count("items")

      conn =
        call("POST", "/items", rollback(@json <> "; options=analyze"), %{}, tx_end: :commit)

      assert conn.status == 406
      assert json(conn)["code"] == "PGRST107"
      assert count("items") == before
    end

    test "update and delete need the rollback for analyze as well" do
      for {method, body} <- [{"PATCH", %{"name" => "x"}}, {"DELETE", nil}] do
        conn = call(method, "/projects?id=eq.1", accept(@json <> "; options=analyze"), body)
        assert conn.status == 406, method
      end
    end

    test "a write with a plan Accept and no analyze needs no rollback" do
      conn = call("POST", "/items", accept(@json), %{}, tx_end: :commit)

      assert conn.status == 200
    end

    test "a bad payload is its own error" do
      conn = call("POST", "/clients", accept("application/vnd.pgrst.plan"), %{"nope" => 1})

      assert conn.status == 400
      assert json(conn)["code"] == "PGRST204"
    end
  end

  describe "an RPC" do
    setup do
      start_supervised!(
        {PgRest.Registry,
         modules: Resources.all(), introspect: [repo: Repo, only: Functions.test_functions()]}
      )

      reset_sequences_on_exit()
      :ok
    end

    test "is explained, not executed" do
      before = callcounter_value()

      conn =
        call("POST", "/rpc/callcounter", accept("application/vnd.pgrst.plan+json"))

      assert conn.status == 200
      assert [%{"Plan" => _}] = json(conn)
      assert callcounter_value() == before
    end

    test "analyze executes a volatile function once, and only with tx=rollback" do
      before = callcounter_value()

      denied = call("POST", "/rpc/callcounter", accept(@json <> "; options=analyze"))
      assert denied.status == 406
      assert callcounter_value() == before

      allowed = call("POST", "/rpc/callcounter", rollback(@json <> "; options=analyze"))
      assert allowed.status == 200
      assert callcounter_value() == before + 1
    end

    test "analyze of a volatile function that writes a row: 406 without tx=rollback, 200 and no row with it" do
      body = %{"name" => "analyzed"}
      analyze = @json <> "; options=analyze"

      rows = fn ->
        Repo.query!("SELECT count(*) FROM test.projects WHERE name = 'analyzed'").rows
      end

      refused = call("POST", "/rpc/make_project", accept(analyze), body)
      assert refused.status == 406
      assert json(refused)["code"] == "PGRST107"
      assert rows.() == [[0]]

      allowed = call("POST", "/rpc/make_project", rollback(analyze), body)
      assert allowed.status == 200
      assert [%{"Plan" => _}] = json(allowed)
      assert rows.() == [[0]]
    end

    test "analyze of a stable function needs no rollback (its transaction is read-only)" do
      conn = call("GET", "/rpc/getallprojects", accept(@json <> "; options=analyze"))

      assert conn.status == 200
    end

    test "a set of rows and a scalar" do
      for path <- ["/rpc/getallprojects?id=in.(1,2,3)", "/rpc/add_them?a=3&b=4"] do
        conn = call("GET", path, accept("application/vnd.pgrst.plan"))
        assert conn.status == 200, path
        assert String.starts_with?(conn.resp_body, "Aggregate"), path
      end
    end

    test "a function whose plan is denied by the hook is PGRST107" do
      conn =
        call("GET", "/rpc/getallprojects", accept("application/vnd.pgrst.plan"), nil,
          authorization: DenyFunctionExplain
        )

      assert conn.status == 406
      assert json(conn)["code"] == "PGRST107"
    end
  end

  describe "gating" do
    setup do
      register(Resources.all())
      :ok
    end

    test "plan_enabled: false (the default) offers no plan type" do
      for opts <- [[plan_enabled: false], []] do
        conn =
          request("GET", "/projects", nil, accept("application/vnd.pgrst.plan"), opts)

        assert conn.status == 406
        assert json(conn)["code"] == "PGRST107"

        assert json(conn)["message"] ==
                 ~s(None of these media types are available: application/vnd.pgrst.plan+text; for="application/json")
      end
    end

    test "a client that also accepts JSON gets JSON when the plan is not offered" do
      conn =
        request(
          "GET",
          "/projects?limit=1",
          nil,
          accept("application/vnd.pgrst.plan, application/json"),
          []
        )

      assert conn.status == 200
      assert header(conn, "content-type") == "application/json; charset=utf-8"
    end

    test "plan_enabled as a function decides per request" do
      enabled = fn conn, _context -> Plug.Conn.get_req_header(conn, "x-admin") == ["1"] end
      type = accept("application/vnd.pgrst.plan")

      assert call("GET", "/projects", [{"x-admin", "1"} | type], nil, plan_enabled: enabled).status ==
               200

      denied = call("GET", "/projects", type, nil, plan_enabled: enabled)
      assert denied.status == 406
      assert json(denied)["code"] == "PGRST107"
    end

    test "plan_enabled must be false, true or a 2-arity function" do
      for bad <- [nil, :yes, fn _conn -> true end] do
        assert_raise ArgumentError, ~r/plan_enabled/, fn ->
          PgRest.Plug.init(repo: Repo, plan_enabled: bad)
        end
      end
    end

    test "the hook's :explain denial on the root is PGRST107; allowed it is a 200" do
      type = accept("application/vnd.pgrst.plan")

      denied = call("GET", "/projects", type, nil, authorization: DenyProjectsExplain)
      assert denied.status == 406
      assert json(denied)["code"] == "PGRST107"

      assert call("GET", "/clients", type, nil, authorization: DenyProjectsExplain).status == 200
      assert call("GET", "/projects", type, nil, authorization: AllowAll).status == 200
    end

    test "an embed the hook denies :explain on denies the plan" do
      conn =
        call("GET", "/clients?select=id,projects(id)", accept("application/vnd.pgrst.plan"), nil,
          authorization: DenyProjectsExplain
        )

      assert conn.status == 406
      assert json(conn)["code"] == "PGRST107"
    end

    test "a write whose :explain is denied is PGRST107 and writes nothing" do
      before = count("projects")

      conn =
        call(
          "POST",
          "/projects",
          accept("application/vnd.pgrst.plan"),
          %{"id" => 901, "name" => "no", "client_id" => 1},
          authorization: DenyProjectsExplain
        )

      assert conn.status == 406
      assert count("projects") == before
    end

    test "the plan gate does not leak a denial as 401" do
      conn =
        call("GET", "/projects", accept("application/vnd.pgrst.plan, application/json"), nil,
          authorization: DenyProjectsExplain
        )

      assert conn.status == 200
      assert header(conn, "content-type") == "application/json; charset=utf-8"
    end
  end

  defmodule DenyExplain do
    @moduledoc false
    def authorize(_conn, _resource, :explain, _context), do: {:error, "no"}
    def authorize(_conn, _resource, _operation, _context), do: :ok
  end

  # The gate decides the final media type, whatever the Accept list offers around the plan
  # type: a resource with after_load/2 drops CSV, which used to re-choose past the gate.
  describe "gating with several Accept types (after_load/2 resources)" do
    @plan_csv "text/csv, application/vnd.pgrst.plan+json"
    @analyze_csv "text/csv, application/vnd.pgrst.plan+json; options=analyze"
    @disabled_message "None of these media types are available: " <>
                        "text/csv, application/vnd.pgrst.plan+json; for=\"application/json\""

    setup do
      register([PlugResources.TrimProjects, PlugResources.TrimClients, PlugResources.TrimTasks])
      :ok
    end

    defp refused?(conn) do
      assert conn.status == 406
      assert json(conn)["code"] == "PGRST107"
      conn.resp_body
    end

    test "a denied plan is the same 406 as a disabled one, never a plan" do
      accept = accept(@plan_csv)

      denied = call("GET", "/projects?select=id", accept, nil, authorization: DenyExplain)
      disabled = call("GET", "/projects?select=id", accept, nil, plan_enabled: false)

      assert refused?(denied) == refused?(disabled)
      assert json(denied)["message"] == @disabled_message
    end

    test "an allowed plan is chosen over the dropped CSV" do
      conn = call("GET", "/projects?select=id", accept(@plan_csv), nil, authorization: AllowAll)

      assert conn.status == 200
      assert header(conn, "content-type") =~ "application/vnd.pgrst.plan+json"
    end

    test "an analyze insert without an honoured tx=rollback is refused and writes no row" do
      body = %{"id" => 900, "name" => "never", "client_id" => 1}
      accept = {"accept", @analyze_csv}

      for {opts, headers} <- [
            {[], [accept, {"prefer", "return=representation"}]},
            {[tx_end: :commit], [accept, {"prefer", "return=representation, tx=rollback"}]}
          ] do
        conn = call("POST", "/projects", headers, body, opts)

        refused?(conn)
        assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM test.projects WHERE id = 900")
      end
    end

    test "update and delete analyze are refused the same way and change nothing" do
      before = Repo.query!("SELECT name FROM test.projects ORDER BY id").rows
      headers = [{"accept", @analyze_csv}, {"prefer", "return=representation"}]

      refused?(call("PATCH", "/projects?id=eq.1", headers, %{"name" => "x"}))
      refused?(call("DELETE", "/projects?id=eq.5", headers))
      assert Repo.query!("SELECT name FROM test.projects ORDER BY id").rows == before
    end

    test "a denied write plan is the same 406 as a disabled one" do
      headers = [{"accept", @plan_csv}, {"prefer", "return=representation, tx=rollback"}]
      body = %{"id" => 900, "name" => "never", "client_id" => 1}

      denied = call("POST", "/projects", headers, body, authorization: DenyExplain)
      disabled = call("POST", "/projects", headers, body, plan_enabled: false)

      assert refused?(denied) == refused?(disabled)
      assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM test.projects WHERE id = 900")
    end

    test "a denied PATCH or DELETE plan is the same 406 as a disabled one" do
      headers = [{"accept", @plan_csv}, {"prefer", "return=representation, tx=rollback"}]
      before = Repo.query!("SELECT name FROM test.projects ORDER BY id").rows

      for {method, path, body} <- [
            {"PATCH", "/projects?id=eq.1", %{"name" => "x"}},
            {"DELETE", "/projects?id=eq.5", nil}
          ] do
        denied = call(method, path, headers, body, authorization: DenyExplain)
        disabled = call(method, path, headers, body, plan_enabled: false)

        assert refused?(denied) == refused?(disabled), method
      end

      assert Repo.query!("SELECT name FROM test.projects ORDER BY id").rows == before
    end

    test "the plan_enabled function is not called when no plan type is asked for" do
      test = self()
      enabled = fn _conn, _context -> send(test, :called) && true end

      call("GET", "/projects?select=id", accept("application/json"), nil, plan_enabled: enabled)
      refute_received :called

      call("GET", "/projects?select=id", accept("application/vnd.pgrst.plan"), nil,
        plan_enabled: enabled
      )

      assert_received :called
    end

    test "the error order does not tell a denial from a disabled plan" do
      accept = accept("application/vnd.pgrst.plan")

      for opts <- [[plan_enabled: false], [authorization: DenyExplain]] do
        conn = call("GET", "/nope", accept, nil, opts)
        assert conn.status == 404
      end
    end
  end

  describe "gating with several Accept types (tables and RPC)" do
    setup do
      start_supervised!(
        {PgRest.Registry,
         modules: Resources.all(), introspect: [repo: Repo, only: Functions.test_functions()]}
      )

      reset_sequences_on_exit()
      :ok
    end

    test "a denied plan falls through to the next type, byte-identical to a disabled one" do
      accept = accept("application/vnd.pgrst.plan+json, text/csv")

      for path <- ["/projects?select=id&limit=1", "/rpc/getallprojects?select=id&limit=1"] do
        denied = call("GET", path, accept, nil, authorization: DenyExplain)
        disabled = call("GET", path, accept, nil, plan_enabled: false)

        assert header(denied, "content-type") == "text/csv; charset=utf-8"
        assert denied.resp_body == disabled.resp_body
      end
    end

    test "a denied plan is the same 406 as a disabled one when it is all an RPC request accepts" do
      accept = accept("application/vnd.pgrst.plan+json")

      for {method, path, body} <- [
            {"GET", "/rpc/getallprojects?select=id", nil},
            {"POST", "/rpc/make_project", %{"name" => "never"}}
          ] do
        denied = call(method, path, accept, body, authorization: DenyExplain)
        disabled = call(method, path, accept, body, plan_enabled: false)

        assert denied.status == 406, path
        assert json(denied)["code"] == "PGRST107", path
        assert denied.resp_body == disabled.resp_body, path
      end
    end

    test "an analyze call that cannot roll back falls through to JSON and runs exactly once" do
      before = callcounter_value()
      accept = accept(@json <> "; options=analyze, application/json")

      conn =
        call("POST", "/rpc/callcounter", [{"prefer", "tx=rollback"} | accept], nil,
          tx_end: :commit
        )

      assert header(conn, "content-type") == "application/json; charset=utf-8"
      assert callcounter_value() == before + 1
    end

    test "a denied analyze insert is a 406 and writes no row" do
      before = count("items")
      headers = [{"prefer", "tx=rollback"} | accept(@json <> "; options=analyze")]

      denied = call("POST", "/items", headers, %{}, authorization: DenyExplain)
      disabled = call("POST", "/items", headers, %{}, plan_enabled: false)
      allowed = call("POST", "/items", headers, %{}, authorization: AllowAll)

      assert refused?(denied) == refused?(disabled)
      assert allowed.status == 200
      assert count("items") == before
    end
  end

  describe "Authorization.check/5 for :explain" do
    defp check(auth, resource \\ Resources.Projects),
      do: Authorization.check(auth, Plug.Test.conn(:get, "/"), resource, :explain, %{})

    test "authorize/4 decides when exported" do
      assert :ok = check(AllowAll)
      assert {:error, %Error{}} = check(DenyProjectsExplain)
    end

    test "authorize_query/5 needs an explicit three-tuple explain grant" do
      assert :ok = check(QueryOnlyAllows)
      assert {:error, %Error{}} = check(QueryOnly)
    end

    test "a module exporting neither denies" do
      assert {:error, %Error{}} = check(Neither)
    end

    test "no hook at all allows, and so does a resource whose allow: list names no :explain" do
      assert :ok = check(nil)
      assert :ok = check(nil, PlugResources.NoRead)
      assert :ok = check(AllowAll, PlugResources.NoRead)
      assert {:error, %Error{}} = check(DenyExplain, PlugResources.NoRead)
    end

    test "a function needs authorize/4, an authorize_query/5-only module is denied" do
      function = %PgRest.Function{
        schema: "test",
        name: "f",
        params: [],
        returns: %PgRest.Function.Return{kind: :void, type: "void"},
        volatility: :stable
      }

      assert :ok = check(AllowAll, function)
      assert {:error, %Error{}} = check(QueryOnlyAllows, function)
    end
  end
end
