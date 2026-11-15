defmodule PgRest.PlugReadTest do
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [json: 1]

  alias PgRest.Compat.{Repo, Resources}
  alias PgRest.{Executor, MediaType, Planner, Request, Responder}
  alias PgRest.SQL.Read, as: SQLRead
  alias PgRest.Test.{PlugResources, TelemetryProbe}

  defmodule Deny do
    @moduledoc false
    def authorize(_conn, resource, :read, _context) do
      if resource == PgRest.Compat.Resources.Clients, do: {:error, "no"}, else: :ok
    end
  end

  defmodule Spy do
    @moduledoc false
    def authorize(conn, _resource, :read, _context) do
      send(conn.private.spy_pid, {:params, conn.query_params})
      :ok
    end
  end

  defp call(path, opts \\ [], headers \\ [], method \\ "GET") do
    conn =
      Enum.reduce(headers, Plug.Test.conn(method, path), fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)

    PgRest.Plug.call(conn, PgRest.Plug.init([repo: Repo] ++ opts))
  end

  # Runs the read of `path` on `TrimProjects`, then responds with `corrupt.(rows)`: a body
  # whose embed shapes do not match the plan, as after a plan/SQL mismatch.
  defp respond_corrupted(path, corrupt) do
    {:ok, request} = Request.from_conn(Plug.Test.conn("GET", path), [])
    context = %{repo: Repo, graph: PgRest.Registry.graph()}
    {:ok, plan} = Planner.plan_read(request, PlugResources.TrimProjects, context)
    {:ok, result} = Executor.read(Repo, SQLRead.statement(plan, context), nil, plan)
    body = result.body |> Jason.decode!() |> corrupt.() |> Jason.encode!()

    Responder.read(
      Plug.Test.conn("GET", path),
      %{result | body: body},
      request,
      plan,
      MediaType.json()
    )
  end

  # Replaces every merged spread (`...m<n>`) with a value of the wrong shape.
  defp bad_merge(rows) do
    Enum.map(rows, fn row ->
      Map.new(row, fn
        {"..." <> _ = key, _value} -> {key, [1, 2]}
        pair -> pair
      end)
    end)
  end

  defp query_events,
    do: for({[:pgrest, :query, :stop], _m, meta} <- TelemetryProbe.drain(), do: meta)

  describe "after_load resources" do
    setup do
      start_supervised!({PgRest.Registry, modules: PlugResources.all()})
      :ok
    end

    test "root and embedded rows are string-keyed maps passed through after_load/2" do
      conn =
        call("/clients?select=id,projects(id)&order=id&projects.order=id&limit=1",
          context_builder: fn _conn, _opts -> %{tenant: "t1"} end
        )

      assert 200 = conn.status

      assert [%{"id" => 1, "loaded" => true, "tenant" => "t1", "projects" => [first | _]}] =
               json(conn)

      assert %{"id" => 1, "project_loaded" => true} = first
    end

    test "the query event carries the SQL and never parameter values" do
      TelemetryProbe.attach([:pgrest, :query, :stop])

      conn = call("/clients?name=eq.SENTINEL-1")
      assert conn.status == 200

      events = query_events()
      assert Enum.any?(events, &String.contains?(&1.sql, "pgrst_source"))
      assert Enum.all?(events, &(is_integer(&1.params_count) and is_boolean(&1.prepared)))
      refute inspect(events) =~ "SENTINEL-1"
    end
  end

  describe "after_load through spreads" do
    setup do
      start_supervised!({PgRest.Registry, modules: PlugResources.trimming()})
      :ok
    end

    test "a regular embed is trimmed" do
      conn = call("/projects?select=id,clients(id,name)&id=eq.1")
      assert [%{"clients" => client}] = json(conn)
      assert client == %{"id" => 1, "c" => true}
    end

    test "a to-one spread is trimmed and merged into the parent" do
      conn = call("/projects?select=id,...clients(name)&id=eq.1")
      assert [row] = json(conn)
      assert row == %{"id" => 1, "p" => true, "c" => true}
    end

    test "a to-one spread of a missing parent keeps null columns" do
      conn = call("/projects?select=id,...clients(name)&id=eq.5")
      assert [row] = json(conn)
      assert row == %{"id" => 5, "p" => true, "c" => nil}
    end

    test "a to-many spread is trimmed and becomes one array per column" do
      conn = call("/clients?select=id,...projects(name)&id=eq.1")
      assert [row] = json(conn)
      assert %{"id" => 1, "c" => true, "p" => ps} = row
      assert is_list(ps) and ps != [] and Enum.all?(ps, &(&1 == true))
      refute Map.has_key?(row, "name")
    end

    test "a to-many spread with no rows yields empty arrays" do
      conn = call("/clients?select=id,...projects(name)&id=eq.1&projects.id=eq.99")
      assert [row] = json(conn)
      assert row == %{"id" => 1, "c" => true, "p" => []}
    end

    test "an output key over 63 bytes is rejected, not truncated by Postgres" do
      long = String.duplicate("a", 70)

      for path <- [
            "/projects?select=id,#{long}:clients(name)&id=eq.1",
            "/projects?select=id,#{long}:name&id=eq.1"
          ] do
        conn = call(path)
        assert conn.status == 400
        assert %{"code" => "PGRST100"} = json(conn)
      end
    end

    test "a long alias cannot break the generated names: after_load still applies" do
      long = String.duplicate("a", 60)
      conn = call("/clients?select=id,#{long}:projects(id,...clients(name))&id=eq.1")
      assert [%{"id" => 1} = row] = json(conn)
      assert [first | _] = row[long]
      assert %{"p" => true, "c" => true} = first
      refute Map.has_key?(first, "name")
    end

    test "a missing embed key fails closed with a 500" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            self(),
            {:conn,
             respond_corrupted(
               "/projects?select=id,clients(id)&id=eq.1",
               &Enum.map(&1, fn row -> Map.delete(row, "clients") end)
             )}
          )
        end)

      assert_received {:conn, conn}
      assert log =~ "TrimProjects"
      assert conn.status == 500
      assert %{"code" => "PGRSTX00"} = json(conn)
      refute conn.resp_body =~ "Microsoft"
    end

    test "aliases that equal generated names are rejected, in any case" do
      for select <- [
            "id,projects(pgrst_e1:name)",
            "id,projects(id,tasks(pgrst_e3:name))",
            "id,_postgrest_t:name",
            "id,PGRST_E1:name",
            "id,projects(name->pgrst_e1)"
          ] do
        conn = call("/clients?select=#{select}&id=eq.1")
        assert conn.status == 400, select
        assert %{"code" => "PGRST100"} = json(conn)
      end
    end

    test "a to-one embed of the wrong shape fails closed" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            self(),
            {:conn,
             respond_corrupted(
               "/projects?select=id,clients(id)&id=eq.1",
               &Enum.map(&1, fn row -> Map.replace(row, "clients", 1) end)
             )}
          )
        end)

      assert_received {:conn, conn}
      assert log =~ "TrimProjects"
      assert conn.status == 500
      assert %{"code" => "PGRSTX00"} = json(conn)
    end

    test "a merged spread of the wrong shape fails closed, without an exception" do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(
            self(),
            {:conn,
             respond_corrupted("/projects?select=id,...clients(name)&id=eq.1", &bad_merge/1)}
          )
        end)

      assert_received {:conn, conn}
      assert log =~ "TrimProjects"
      assert conn.status == 500
      assert %{"code" => "PGRSTX00"} = json(conn)
    end

    test "a forged merge key is rejected at every node" do
      for path <- [
            ~s|/clients?select=id,projects(id,...tasks(id),"...projects_tasks_2":clients(name))&id=eq.1|,
            ~s|/clients?select=id,"...projects_tasks_1":projects(name),...projects(name)&id=eq.1|,
            ~s|/clients?select=id,"...x":id|
          ] do
        conn = call(path)
        assert conn.status == 400
        assert %{"code" => "PGRST100"} = json(conn)
      end
    end
  end

  describe "hooks" do
    setup do
      start_supervised!({PgRest.Registry, modules: Resources.all()})
      :ok
    end

    test "authorize/4 and the context builder see fetched query params" do
      builder = fn conn, _opts ->
        send(self(), {:builder_params, conn.query_params})
        %{}
      end

      conn =
        Plug.Test.conn("GET", "/clients?select=id&order=id")
        |> Plug.Conn.put_private(:spy_pid, self())
        |> PgRest.Plug.call(
          PgRest.Plug.init(repo: Repo, authorization: Spy, context_builder: builder)
        )

      assert conn.status == 200
      assert_received {:params, %{"select" => "id", "order" => "id"}}
      assert_received {:builder_params, %{"select" => "id", "order" => "id"}}
    end

    test "a malformed query string is still a 400, not a raise" do
      assert %{status: 400} = call("/clients?select=%E0%A4%A")
    end
  end

  describe "root alias" do
    setup do
      Repo.query!("CREATE TABLE test.pgrst_t1 (id integer PRIMARY KEY, parent_id integer)")
      Repo.query!("INSERT INTO test.pgrst_t1 VALUES (1, NULL), (2, 1), (3, 1), (4, NULL)")
      on_exit(fn -> Repo.query!("DROP TABLE IF EXISTS test.pgrst_t1") end)
      PgRest.Catalog.forget(Repo)
      start_supervised!({PgRest.Registry, modules: [PlugResources.AliasKin]})
      :ok
    end

    test "a root table named like a generated alias keeps children per parent" do
      conn = call("/pgrst_t1?select=id,kids(id)&order=id&kids.order=id")

      assert [
               %{"id" => 1, "kids" => [%{"id" => 2}, %{"id" => 3}]},
               %{"id" => 2, "kids" => []},
               %{"id" => 3, "kids" => []},
               %{"id" => 4, "kids" => []}
             ] = json(conn)
    end
  end

  describe "children-first after_load and unique embed keys" do
    setup do
      start_supervised!(
        {PgRest.Registry, modules: [PlugResources.RenameClients, PlugResources.RenameProjects]}
      )

      :ok
    end

    test "a parent that renames an embed key does not skip the child's after_load" do
      conn = call("/clients?select=id,ITEMS:projects(id,name)&id=eq.1&order=id")
      assert [row] = json(conn)
      assert [first | _] = row["items"]
      assert first["p"] == true
      refute Map.has_key?(first, "name")
      refute Map.has_key?(row, "ITEMS")
    end

    test "an embed key shared with another output is rejected" do
      for select <- [
            "id,projects(id),projects:name",
            "id,x:projects(id),x:projects(name)",
            "id,name:projects(id),name"
          ] do
        conn = call("/clients?select=#{select}")
        assert conn.status == 400, select
        assert %{"code" => "PGRST100"} = json(conn)
      end
    end
  end

  describe "63-byte table names" do
    setup do
      table = PlugResources.LongKin.table()
      assert byte_size(table) == 63
      qualified = ~s("test"."#{table}")

      Repo.query!("CREATE TABLE #{qualified} (id integer PRIMARY KEY, parent_id integer)")

      Repo.query!("INSERT INTO #{qualified} VALUES (1, NULL), (2, 1), (3, 1), (4, NULL), (5, 4)")

      on_exit(fn -> Repo.query!("DROP TABLE IF EXISTS #{qualified}") end)
      PgRest.Catalog.forget(Repo)
      start_supervised!({PgRest.Registry, modules: [PlugResources.LongKin]})
      :ok
    end

    test "children stay with their own parent" do
      table = PlugResources.LongKin.table()
      conn = call("/#{table}?select=id,kids(id)&order=id&kids.order=id")
      assert conn.status == 200

      assert [
               %{"id" => 1, "kids" => [%{"id" => 2}, %{"id" => 3}]},
               %{"id" => 2, "kids" => []},
               %{"id" => 3, "kids" => []},
               %{"id" => 4, "kids" => [%{"id" => 5}]},
               %{"id" => 5, "kids" => []}
             ] = json(conn)
    end
  end

  describe "nested merge placeholders" do
    setup do
      start_supervised!(
        {PgRest.Registry,
         modules: [
           PlugResources.NestedTasks,
           PlugResources.NestedProjects,
           PlugResources.TrimClients
         ]}
      )

      :ok
    end

    test "an empty spread runs the inner after_load first, so removed columns stay hidden" do
      conn = call("/tasks?select=id,...project(id,...client(name))&id=eq.1&project.id=eq.99")
      assert [row] = json(conn)
      # `id` is the spread project's (nil); `name` is gone, `c` comes from the inner callback.
      assert row == %{"id" => nil, "c" => nil, "saw_name" => nil}
    end
  end

  describe "a raising inner callback on an empty placeholder" do
    setup do
      start_supervised!(
        {PgRest.Registry,
         modules: [
           PlugResources.RaisingTasks,
           PlugResources.RaisingProjects,
           PlugResources.RaisingClients
         ]}
      )

      :ok
    end

    test "drops only that merged embed's columns; outer columns survive" do
      conn = call("/tasks?select=id,...project(id,...client(name))&id=eq.1&project.id=eq.99")
      assert [row] = json(conn)
      assert row == %{"id" => nil, "saw" => nil}
    end

    test "with a real row every callback runs" do
      conn = call("/tasks?select=id,...project(id,...client(name))&id=eq.1")
      assert [%{"saw" => true}] = json(conn)
    end
  end

  describe "after_load of a spread parent" do
    setup do
      start_supervised!(
        {PgRest.Registry, modules: [PlugResources.TakeProjects, PlugResources.TakeClients]}
      )

      :ok
    end

    test "sees the merged spread columns" do
      conn = call("/projects?select=id,name,...client(name)&id=eq.1")
      assert [%{"id" => 1, "c" => true} = row] = json(conn)
      assert map_size(row) == 2
    end
  end

  describe "reads" do
    setup do
      start_supervised!({PgRest.Registry, modules: Resources.all()})
      :ok
    end

    test "a read and HEAD share headers; HEAD has no body" do
      get = call("/items?select=id&order=id&limit=2", [], [{"prefer", "count=exact"}])
      head = call("/items?select=id&order=id&limit=2", [], [{"prefer", "count=exact"}], "HEAD")

      assert get.status == 206 and head.status == 206
      assert Plug.Conn.get_resp_header(get, "content-range") == ["0-1/15"]
      assert Plug.Conn.get_resp_header(head, "content-range") == ["0-1/15"]
      assert head.resp_body == ""
    end

    test "count=planned and count=estimated use the planner estimate" do
      planned = call("/items?select=id&order=id&limit=2", [], [{"prefer", "count=planned"}])
      [range] = Plug.Conn.get_resp_header(planned, "content-range")
      assert [_, total] = Regex.run(~r{^0-1/(\d+)$}, range)
      assert String.to_integer(total) >= 0
      assert Plug.Conn.get_resp_header(planned, "preference-applied") == ["count=planned"]

      estimated =
        call("/items?select=id&order=id", [max_limit: 2], [{"prefer", "count=estimated"}])

      assert estimated.status == 206
      assert [range] = Plug.Conn.get_resp_header(estimated, "content-range")
      assert [_, total] = Regex.run(~r{^0-1/(\d+)$}, range)
      assert String.to_integer(total) >= 15

      small =
        call("/items?select=id&order=id&limit=2", [max_limit: 100], [
          {"prefer", "count=estimated"}
        ])

      assert Plug.Conn.get_resp_header(small, "content-range") == ["0-1/15"]
    end

    test "the transaction setup runs first and sets the schema search path" do
      TelemetryProbe.attach([:pgrest, :query, :start])
      assert call("/clients?select=id,projects(id)&limit=1").status == 200

      assert [first | _] = for({_e, _m, %{sql: sql}} <- TelemetryProbe.drain(), do: sql)
      assert first == "SELECT set_config('search_path', $1, true)"
    end

    test "unknown tables and paths are errors" do
      assert %{status: 404} = conn = call("/nonexistent")
      assert %{"code" => "PGRST205"} = json(conn)
      assert %{status: 404} = call("/items/1")
    end

    test "an unsupported method is a 405" do
      assert %{status: 405} = conn = call("/items", [], [], "TRACE")
      assert %{"code" => "PGRST117"} = json(conn)
    end

    test "a database error is translated, never inspected" do
      conn = call("/items?id=eq.abc")
      assert conn.status == 400
      body = json(conn)

      assert %{"code" => "22P02", "message" => "invalid input syntax for type bigint: \"abc\""} =
               body

      refute conn.resp_body =~ "Postgrex"
    end
  end

  describe "allow:" do
    setup do
      start_supervised!({PgRest.Registry, modules: [PlugResources.NoRead]})
      :ok
    end

    test "a read the resource does not allow is a 42501, like a missing grant" do
      conn = call("/items")
      assert conn.status == 401
      assert %{"code" => "42501", "message" => "permission denied for table items"} = json(conn)
    end

    # As PostgREST, where the database checks privileges after the request text is parsed.
    test "malformed request text is a 400 before the missing grant" do
      assert %{status: 400, resp_body: body} = call("/items?id=eq.%zz")
      assert %{"code" => "PGRST" <> _} = Jason.decode!(body)

      assert %{status: 400} = conn = patch("/items?id=eq.1", "{")
      assert %{"code" => "PGRST102"} = json(conn)

      assert %{status: 401} = conn = patch("/items?id=eq.1", ~s({"name":"x"}))
      assert %{"code" => "42501"} = json(conn)
    end

    # Upstream parses the filter grammar before privileges are checked (verified against
    # PostgREST v14.18: a malformed filter on an unreadable table is a PGRST100).
    test "a malformed filter or order is a 400 PGRST100 before the missing grant" do
      for path <- ["/items?id=foo.1", "/items?order=id.nope", "/items?and=(id.foo.1)"] do
        assert %{status: 400} = conn = call(path)
        assert %{"code" => "PGRST100"} = json(conn)
      end

      assert %{status: 401} = conn = call("/items?id=eq.1")
      assert %{"code" => "42501"} = json(conn)
    end
  end

  defp patch(path, body) do
    "PATCH"
    |> Plug.Test.conn(path, body)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> PgRest.Plug.call(PgRest.Plug.init(repo: Repo))
  end

  describe "failures" do
    setup do
      start_supervised!({PgRest.Registry, modules: Resources.all()})
      :ok
    end

    test "a connection failure while the planner loads the catalog is a 503" do
      {conn, log} =
        ExUnit.CaptureLog.with_log(fn ->
          "GET"
          |> Plug.Test.conn("/clients")
          |> PgRest.Plug.call(PgRest.Plug.init(repo: PlugResources.DownRepo))
        end)

      assert log =~ "DBConnection.ConnectionError"
      refute log =~ "refused"

      assert conn.status == 503
      assert %{"code" => "PGRST000", "message" => "Database connection error."} = json(conn)
    end

    test "the request span covers invalid paths too" do
      TelemetryProbe.attach([:pgrest, :request, :stop])
      assert call("/items/1").status == 404
      assert [{_e, _m, %{status: 404, method: "GET", resource: "items"}}] = TelemetryProbe.drain()
    end

    test "the query stop event says what kind of failure it was" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      assert call("/items?id=eq.abc").status == 400

      assert Enum.any?(TelemetryProbe.drain(), fn {_e, _m, meta} ->
               meta.error_kind == :database
             end)
    end
  end

  describe "denials never reach the database" do
    setup do
      start_supervised!({PgRest.Registry, modules: Resources.all()})
      TelemetryProbe.attach([:pgrest, :query, :start])
      :ok
    end

    test "authorization, readable columns and count modes fail before any query" do
      assert %{status: 401} = conn = call("/clients", authorization: Deny)
      assert %{"code" => "42501", "message" => "permission denied for table clients"} = json(conn)

      assert %{status: 401} = conn = call("/accounts?select=hashed_password")
      assert %{"code" => "42501"} = json(conn)

      assert %{status: 400} =
               conn = call("/items", [count_modes: [:exact]], [{"prefer", "count=planned"}])

      assert %{"code" => "PGRST100"} = json(conn)

      assert %{status: 406} = call("/items", [], [{"accept", "text/unknowntype"}])

      assert [] = TelemetryProbe.drain()
    end

    test "positive control: an allowed request does emit query events" do
      assert %{status: 200} = call("/items?limit=1")
      assert [_ | _] = TelemetryProbe.drain()
    end
  end
end
