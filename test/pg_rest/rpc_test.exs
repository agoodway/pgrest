defmodule PgRest.RPCTest do
  # Not async: starts named registries over the shared compat fixture and captures logs.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PgRest.Compat.{Functions, Repo, Resources, SupabaseRepo}
  alias PgRest.Compat.Supabase.Resources, as: SupabaseResources
  alias PgRest.Test.SQLResources.Where, as: ScopedProject
  alias PgRest.Test.TelemetryProbe

  defmodule DenyExecute do
    @moduledoc false
    @behaviour PgRest.Authorization

    @impl PgRest.Authorization
    def authorize(_conn, %PgRest.Function{}, :execute, _ctx), do: {:error, "no"}
    def authorize(_conn, _resource, _op, _ctx), do: :ok
  end

  defmodule DenyProjects do
    @moduledoc false
    @behaviour PgRest.Authorization

    @impl PgRest.Authorization
    def authorize(_conn, Resources.Projects, :read, _ctx), do: {:error, "no"}
    def authorize(_conn, _target, _op, _ctx), do: :ok
  end

  defmodule DenyClients do
    @moduledoc false
    @behaviour PgRest.Authorization

    @impl PgRest.Authorization
    def authorize(_conn, Resources.Clients, :read, _ctx), do: {:error, "no"}
    def authorize(_conn, _target, _op, _ctx), do: :ok
  end

  defmodule ClientScopedProject do
    @moduledoc false
    # `test.projects` scoped through an unprefixed `clients` subquery, which resolves through
    # the request `search_path`, like any unqualified table in Ecto's SQL.
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      field(:client_id, :integer)
    end

    @impl PgRest.Resource
    def scope(query, ctx) do
      clients = from(c in "clients", where: c.id == ^ctx.client_id, select: c.id)
      where(query, [r], r.client_id in subquery(clients))
    end
  end

  defmodule NoCallbacks do
    @moduledoc false
    # Configured as the authorization module but exports no `authorize/4` (declaring the
    # behaviour as well would only add a compile warning): every function is denied.
    def unrelated, do: :ok
  end

  @scoped_registry __MODULE__.Scoped
  @admin_registry __MODULE__.Admin
  @compat_registry __MODULE__.Compat
  @supabase_registry __MODULE__.Supabase

  setup do
    scoped_functions = ~w(scoped_projects fabricated_projects reowned_projects make_project)

    capture_log(fn ->
      start_supervised!(
        {PgRest.Registry,
         name: @scoped_registry,
         modules: [ScopedProject],
         introspect: [repo: Repo, only: scoped_functions],
         function_opts: %{{"test", "make_project"} => [result_scope: :none]}},
        id: :scoped
      )

      start_supervised!(
        {PgRest.Registry,
         name: @admin_registry,
         modules: [ScopedProject],
         introspect: [repo: Repo, only: scoped_functions],
         function_opts: %{{"test", "make_project"} => [result_scope: :none]}},
        id: :admin
      )

      start_supervised!(
        {PgRest.Registry,
         name: @compat_registry,
         modules: Resources.all(),
         introspect: [repo: Repo, only: Functions.test_functions()],
         function_opts: %{{"test", "make_project"} => [result_scope: :none]}},
        id: :compat
      )

      start_supervised!(
        {PgRest.Registry,
         name: @supabase_registry,
         modules: SupabaseResources.all(),
         schemas: ["public", "personal"],
         introspect: [repo: SupabaseRepo, except: Functions.supabase_excluded()]},
        id: :supabase
      )
    end)

    :ok
  end

  defp call(method, path, opts \\ [], body \\ nil, headers \\ []) do
    conn =
      method
      |> Plug.Test.conn(path, encode(body))
      |> then(fn conn ->
        if body,
          do: Plug.Conn.put_req_header(conn, "content-type", "application/json"),
          else: conn
      end)

    conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)

    opts =
      Keyword.merge(
        [repo: Repo, registry: @compat_registry, tx_end: :commit_allow_override],
        opts
      )

    PgRest.Plug.call(conn, PgRest.Plug.init(opts))
  end

  defp encode(nil), do: nil
  defp encode(body) when is_binary(body), do: body
  defp encode(body), do: Jason.encode!(body)

  defp json(conn), do: Jason.decode!(conn.resp_body)

  defp scoped(registry, context),
    do: [registry: registry, context_builder: fn _conn, _opts -> context end]

  defp ids(conn), do: conn |> json() |> Enum.map(& &1["id"]) |> Enum.sort()

  defp statements, do: for({_e, _m, %{sql: sql}} <- TelemetryProbe.drain(), do: sql)

  describe "result scoping (:stored_rows)" do
    test "a function returning the scoped resource returns only the in-scope rows" do
      conn = call("GET", "/rpc/scoped_projects", scoped(@scoped_registry, %{client_id: 1}))
      assert conn.status == 200
      assert ids(conn) == [1, 2]
    end

    test "fabricated rows are dropped" do
      conn = call("GET", "/rpc/fabricated_projects", scoped(@scoped_registry, %{client_id: 1}))
      assert ids(conn) == [1, 2]
    end

    test "rows whose attributes the function changed are dropped" do
      conn = call("GET", "/rpc/reowned_projects", scoped(@scoped_registry, %{client_id: 1}))
      assert conn |> json() |> Enum.map(& &1["client_id"]) |> Enum.uniq() == [1]
      assert ids(conn) == [1, 2]
    end

    test "narrow projections and filters cannot admit fabricated or altered rows" do
      for function <- ["fabricated_projects", "reowned_projects"] do
        conn =
          call(
            "GET",
            "/rpc/#{function}?select=id&id=gt.2&client_id=eq.1",
            scoped(@scoped_registry, %{client_id: 1})
          )

        assert conn.status == 200
        assert json(conn) == []
      end
    end

    test "an identity scope for this request emits no probe" do
      TelemetryProbe.attach([:pgrest, :query, :start])

      conn =
        call(
          "GET",
          "/rpc/scoped_projects",
          scoped(@admin_registry, %{client_id: 1, admin?: true})
        )

      assert ids(conn) == [1, 2, 3, 4, 5]
      refute Enum.any?(statements(), &(&1 =~ "EXISTS"))

      conn = call("GET", "/rpc/scoped_projects", scoped(@admin_registry, %{client_id: 1}))
      assert ids(conn) == [1, 2]
      assert Enum.any?(statements(), &(&1 =~ "EXISTS (SELECT 1 FROM ("))
    end

    test "result_scope: :none returns the function's row unfiltered" do
      conn =
        call(
          "POST",
          "/rpc/make_project",
          scoped(@scoped_registry, %{client_id: 1}),
          %{"name" => "new"},
          [{"prefer", "tx=rollback"}]
        )

      assert conn.status == 200
      assert %{"name" => "new", "client_id" => nil} = json(conn)
    end

    test "database error details are scrubbed when any registered resource is scoped" do
      opts = scoped(@admin_registry, %{client_id: 1, admin?: true})

      conn =
        call("POST", "/rpc/make_project", opts, %{"name" => nil}, [{"prefer", "tx=rollback"}])

      assert conn.status == 400
      assert %{"code" => "23502", "details" => nil} = json(conn)
    end
  end

  describe "search_path" do
    @cross_registry __MODULE__.CrossSchema

    # Idempotent: a crashed run leaves the decoy behind.
    defp drop_cross! do
      Repo.query!("DROP SCHEMA IF EXISTS rpc_cross CASCADE")
      Repo.query!("DROP TABLE IF EXISTS public.clients")
    end

    # A function in another schema returning `test.projects`: the scope's unprefixed `clients`
    # must still resolve in the resource's schema, never in a same-named `public` table.
    setup do
      drop_cross!()
      Repo.query!("CREATE SCHEMA rpc_cross")

      Repo.query!("""
      CREATE FUNCTION rpc_cross.cross_projects() RETURNS SETOF test.projects
        LANGUAGE sql STABLE AS $$ SELECT * FROM test.projects $$
      """)

      Repo.query!("CREATE TABLE public.clients (id integer PRIMARY KEY)")

      on_exit(&drop_cross!/0)

      capture_log(fn ->
        start_supervised!(
          {PgRest.Registry,
           name: @cross_registry,
           modules: [ClientScopedProject],
           schemas: ["rpc_cross", "test"],
           introspect: [repo: Repo, schemas: ["rpc_cross"], only: ["cross_projects"]]},
          id: :cross
        )
      end)

      :ok
    end

    test "an RPC reads its result resource's scope in the resource's schema" do
      conn = call("GET", "/rpc/cross_projects", scoped(@cross_registry, %{client_id: 1}))
      assert conn.status == 200
      assert ids(conn) == [1, 2]
    end
  end

  describe "authorization" do
    test "a denied :execute is 401 for the function, before any query" do
      TelemetryProbe.attach([:pgrest, :query, :start])
      conn = call("GET", "/rpc/add_them?a=1&b=2", authorization: DenyExecute)

      assert conn.status == 401

      assert json(conn) == %{
               "code" => "42501",
               "message" => "permission denied for function add_them",
               "details" => nil,
               "hint" => nil
             }

      assert Plug.Conn.get_resp_header(conn, "www-authenticate") == ["Bearer"]
      assert statements() == []
    end

    test ":read on the returned resource is required, whatever the result scope" do
      TelemetryProbe.attach([:pgrest, :query, :start])

      for {method, path, body} <- [
            {"GET", "/rpc/getallprojects", nil},
            {"POST", "/rpc/make_project", %{"name" => "x"}}
          ] do
        conn =
          call(method, path, [authorization: DenyProjects], body, [{"prefer", "tx=rollback"}])

        assert conn.status == 401
        assert json(conn)["message"] == "permission denied for table projects"
      end

      assert statements() == []
    end

    test ":read on every embedded resource is required" do
      TelemetryProbe.attach([:pgrest, :query, :start])
      conn = call("GET", "/rpc/getallprojects?select=id,clients(id)", authorization: DenyClients)

      assert conn.status == 401
      assert json(conn)["message"] == "permission denied for table clients"
      assert statements() == []

      assert %{status: 200} = call("GET", "/rpc/getallprojects", authorization: DenyClients)
    end

    test "a module without authorize/4 denies every function" do
      TelemetryProbe.attach([:pgrest, :query, :start])
      conn = call("GET", "/rpc/add_them?a=1&b=2", authorization: NoCallbacks)
      assert conn.status == 401
      assert json(conn)["message"] == "permission denied for function add_them"

      conn =
        call(
          "POST",
          "/rpc/get_username_and_status",
          [repo: SupabaseRepo, registry: @supabase_registry, authorization: NoCallbacks],
          %{"name_param" => "supabot"}
        )

      assert conn.status == 401
      assert json(conn)["message"] == "permission denied for function get_username_and_status"
      assert statements() == []
    end
  end

  describe "transaction setup" do
    test "a read-only call sets everything in one set_config statement" do
      TelemetryProbe.attach([:pgrest, :query, :start])
      assert %{status: 200} = call("GET", "/rpc/add_them?a=1&b=2", statement_timeout: "5s")

      sqls = statements()
      assert [setup] = Enum.filter(sqls, &String.starts_with?(&1, "SELECT set_config"))
      assert setup =~ "set_config('search_path'"
      assert setup =~ "set_config('transaction_read_only'"
      assert setup =~ "set_config('statement_timeout'"
      refute Enum.any?(sqls, &(&1 =~ "SET TRANSACTION"))

      conn = call("GET", "/rpc/callcounter", statement_timeout: "5s")
      assert conn.status == 405
      assert json(conn)["code"] == "25006"
    end

    # Both calls run on one checked-out connection, so the second would see a leaked setting.
    test "a statement timeout cancels the call and does not outlive its transaction" do
      Repo.checkout(fn ->
        conn = call("GET", "/rpc/sleep_for?s=1", statement_timeout: "100ms")
        assert conn.status == 500
        assert json(conn)["code"] == "57014"

        assert %{status: 204} = call("GET", "/rpc/sleep_for?s=0.2")
      end)
    end

    test "the setup values never reach the repo's query events or the log" do
      TelemetryProbe.attach([:pg_rest, :compat, :repo, :query])

      log =
        capture_log([level: :debug], fn ->
          assert %{status: 200} =
                   call("GET", "/rpc/add_them?a=1&b=2", statement_timeout: "4321ms")
        end)

      events = TelemetryProbe.drain()
      refute inspect(events) =~ "4321ms"
      refute inspect(events) =~ "set_config"
      refute log =~ "4321ms"
    end
  end

  describe "volatility" do
    test "GET on a volatile function that only reads succeeds" do
      assert %{status: 200} = call("GET", "/rpc/getallprojects?select=id&id=eq.1")
    end

    test "GET on a volatile function that writes is 405 and persists nothing" do
      conn = call("GET", "/rpc/setprojects?id_l=1&id_h=2&name=hacked")
      assert conn.status == 405
      assert json(conn)["code"] == "25006"
      assert %{rows: [["Windows 7"]]} = Repo.query!("SELECT name FROM test.projects WHERE id = 1")
    end

    # The sequence advances outside the transaction, so it counts executions even though the
    # POST rolls back.
    test "a POST with count=estimated executes the function once" do
      before = callcounter_value()

      conn =
        call("POST", "/rpc/callcounter?limit=1", [], nil, [
          {"prefer", "count=estimated, tx=rollback"}
        ])

      assert conn.status == 200
      assert callcounter_value() == before + 1
    end
  end

  defp callcounter_value do
    %{rows: [[value, called?]]} =
      Repo.query!("SELECT last_value, is_called FROM test.callcounter_count")

    if called?, do: value, else: value - 1
  end

  describe "arguments" do
    test "a filter-shaped value is a filter, not an argument" do
      conn = call("GET", "/rpc/sayhello?name=eq.x")
      assert conn.status == 404
      assert json(conn)["code"] == "PGRST202"
    end

    test "a JSON array body calls the function once, with its first element" do
      conn = call("POST", "/rpc/getproject", [], [%{"id" => 1}, %{"id" => 2}])
      assert conn.status == 200
      assert ids(conn) == [1]
    end

    test "a read's argument takes only the argument values, never a filter's" do
      conn = call("GET", "/rpc/getproject?id=1&id=eq.1")
      assert conn.status == 200
      assert ids(conn) == [1]
    end

    test "a JSON null argument is SQL NULL" do
      conn = call("POST", "/rpc/add_them", [], %{"a" => 1, "b" => nil})
      assert conn.status == 200
      assert conn.resp_body == "null"
    end

    test "every bind form runs against the database" do
      assert call("GET", "/rpc/add_them?a=1&b=2") |> json() == 3
      assert call("POST", "/rpc/add_them", [], %{"a" => 1, "b" => 2}) |> json() == 3
      assert call("POST", "/rpc/unnamed_json_param", [], %{"A" => 1}) |> json() == %{"A" => 1}
      assert call("GET", "/rpc/variadic_param?v=hi&v=there") |> json() == ["hi", "there"]

      supabase = [repo: SupabaseRepo, registry: @supabase_registry]
      big = "9223372036854775807"

      assert call("POST", "/rpc/echo_bigint_as_text", supabase, %{"bigint_param" => big})
             |> json() == big
    end

    test "a malformed argument value is the database's 22P02, not a raise" do
      conn = call("GET", "/rpc/add_them?a=abc&b=2")
      assert conn.status == 400
      assert json(conn)["code"] == "22P02"
    end
  end

  describe "body" do
    defp parsed(body, opts) do
      parsers =
        Plug.Parsers.init(
          parsers: [:json],
          pass: ["*/*"],
          json_decoder: Jason,
          body_reader: {PgRest.BodyReader, :read_body, []}
        )

      "POST"
      |> Plug.Test.conn("/rpc/add_them", body)
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(parsers)
      |> PgRest.Plug.call(PgRest.Plug.init([repo: Repo, registry: @compat_registry] ++ opts))
    end

    test "the cached raw body is the argument source" do
      conn = parsed(~s({"a":1,"b":2}), [])
      assert conn.status == 200
      assert conn.resp_body == "3"
    end

    test "a body above max_body_bytes is 413" do
      assert %{status: 413} = parsed(~s({"a":1,"b":2}), max_body_bytes: 5)
    end
  end
end
