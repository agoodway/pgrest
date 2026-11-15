defmodule PgRest.AuthorizationHookTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import ExUnit.CaptureLog
  import PgRest.PlugCase

  alias PgRest.Authorization.Apply
  alias PgRest.Compat.{Repo, Resources}
  alias PgRest.Error
  alias PgRest.Registry.Snapshot
  alias PgRest.SQL.Read
  alias PgRest.Test.Policies.BareQuery, as: Bare
  alias PgRest.Test.Policies.Neither
  alias PgRest.Test.SQLResources.Where, as: ScopedProject
  alias PgRest.Test.TelemetryProbe

  defmodule Policy do
    @moduledoc false
    @behaviour PgRest.Authorization
    @impl true
    def authorize(_conn, resource, op, ctx) do
      if pid = ctx[:report_to], do: send(pid, {:authorize, resource, op, ctx[:path], ctx[:root?]})
      if resource == ctx[:deny], do: {:error, :denied}, else: :ok
    end

    @impl true
    def authorize_query(_conn, resource, op, query, ctx) do
      if pid = ctx[:report_to], do: send(pid, {:hook, resource, op, ctx[:path], ctx[:root?]})
      fun = Map.get(ctx, :query, fn q, _r, _ctx -> q end)
      result = fun.(query, resource, ctx)
      opts = Map.get(ctx, :policy, fn _r, _ctx -> [aggregates: true, count: true] end)
      {:ok, result, opts.(resource, ctx)}
    end
  end

  defmodule DenyQuery do
    @moduledoc false
    @behaviour PgRest.Authorization
    @impl true
    def authorize(_c, _r, _op, _ctx), do: :ok
    @impl true
    def authorize_query(_c, _r, _op, _q, _ctx), do: {:error, :denied}
  end

  defmodule ErrorScope do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def scope(_q, _ctx), do: {:error, PgRest.Error.permission_denied(:table, "clients")}
  end

  setup do
    register(Resources.all())
    :ok
  end

  defp opts(context, auth \\ Policy) do
    [
      authorization: auth,
      aggregates: true,
      plan_enabled: true,
      tx_end: :commit_allow_override,
      context_builder: fn _c, _o -> context end
    ]
  end

  defp get(path, context, auth \\ Policy, headers \\ []),
    do: request("GET", path, nil, headers, opts(context, auth))

  defp ids(conn), do: conn |> json() |> Enum.map(& &1["id"]) |> Enum.sort()

  defp callback_trace do
    receive do
      {event, _, _, _, _} = message when event in [:authorize, :hook] ->
        [message | callback_trace()]
    after
      0 -> []
    end
  end

  defp tenant do
    %{tenant_client_id: 1}
  end

  for mode <- ~w(exact planned estimated) do
    test "pagination stays within the capped set for #{mode}" do
      ctx = %{policy: fn _, _ -> [limit: 2, aggregates: true, count: true] end}

      conn =
        get("/projects?order=id&offset=1&limit=5", ctx, Policy, [
          {"prefer", "count=" <> unquote(mode)}
        ])

      assert ids(conn) == [2]
      assert header(conn, "content-range") == "1-1/2"

      assert get("/projects?order=id&offset=3", ctx, Policy, [
               {"prefer", "count=" <> unquote(mode)}
             ]).status == 416
    end
  end

  test "capped aggregates paginate output groups" do
    ctx = %{policy: fn _, _ -> [limit: 4, aggregates: true, count: true] end}
    assert json(get("/projects?select=count()&limit=0", ctx)) == []
    assert json(get("/projects?select=count()&offset=1", ctx)) == []

    assert json(get("/projects?select=client_id,count()&order=client_id&offset=1&limit=1", ctx)) ==
             [%{"client_id" => 2, "count" => 2}]
  end

  test "ordered capped spread aggregates project remapped ordering" do
    ctx = %{policy: fn _, _ -> [limit: 2, aggregates: true, count: true] end}
    {:ok, snapshot} = PgRest.Registry.snapshot(PgRest.Registry)

    {:ok, request} =
      PgRest.Request.from_conn(
        Plug.Test.conn(
          :get,
          "/clients?select=id,projects(client_id,count())&projects.order=client_id.desc&order=id"
        ),
        %{}
      )

    context =
      Map.merge(ctx, %{
        repo: Repo,
        graph: Snapshot.graph(snapshot, "test"),
        authorization: Policy,
        aggregates: true
      })

    {:ok, plan} = PgRest.Planner.plan_read(request, Resources.Clients, context)
    [embed] = plan.embeds
    # The public planner rejects to-many spread aggregates (PGRST127); exercise the
    # compiler boundary directly, as in the independent review's probe.
    select =
      Enum.map(embed.plan.select, fn
        %{aggregate: _} = entry -> %{entry | legacy: true}
        entry -> entry
      end)

    plan = %{plan | embeds: [%{embed | spread: true, plan: %{embed.plan | select: select}}]}
    {sql, params} = Read.statement(plan, context)
    result = Repo.query!(sql, params)

    assert Jason.decode!(result.rows |> hd() |> Enum.at(2)) ==
             [
               %{"id" => 1, "client_id" => [1], "count" => [2]},
               %{"id" => 2, "client_id" => [2], "count" => [2]}
             ]
  end

  for select <- [
        "...clients(id,count())",
        "count(),clients(id)",
        "...clients(id,count())&clients.id=gt.0"
      ],
      {ordering, expected} <- [{"clients(id)", [1, 2]}, {"clients(id).desc.nullslast", [2, 1]}] do
    test "capped related ordering crosses the input boundary: #{select} #{ordering}" do
      ctx = %{policy: fn _, _ -> [limit: 4, aggregates: true, count: true] end}

      conn =
        get("/projects?select=" <> unquote(select) <> "&order=" <> unquote(ordering), ctx)

      assert conn.status == 200, conn.resp_body
      rows = json(conn)
      assert length(rows) == 2
      assert Enum.map(rows, fn row -> row["id"] || row["clients"]["id"] end) == unquote(expected)
      assert Enum.map(rows, & &1["count"]) == [2, 2]
    end
  end

  test "tenant narrowing holds at root, embed, count and aggregate" do
    auth = PgRest.Compat.TenantAuthorization
    assert ids(get("/projects?order=id", tenant(), auth)) == [1, 2]
    conn = get("/clients?select=id,projects(id)&order=id", tenant(), auth)
    assert json(conn) == [%{"id" => 1, "projects" => [%{"id" => 1}, %{"id" => 2}]}]
    conn = get("/projects", tenant(), auth, [{"prefer", "count=exact"}])
    assert header(conn, "content-range") == "0-1/2"
    assert json(get("/projects?select=count()", tenant(), auth)) == [%{"count" => 2}]
  end

  test "query narrowing constrains rows and totals even when authorize/4 grants every resource" do
    ctx = %{
      query: fn q, resource, _ctx ->
        case resource do
          Resources.Clients -> where(q, [r], r.id == 1)
          Resources.Projects -> where(q, [r], r.client_id == 1)
        end
      end
    }

    assert ids(get("/projects", ctx)) == [1, 2]

    assert json(get("/clients?select=id,projects(id)", ctx)) ==
             [%{"id" => 1, "projects" => [%{"id" => 1}, %{"id" => 2}]}]

    assert header(get("/projects", ctx, Policy, [{"prefer", "count=exact"}]), "content-range") ==
             "0-1/2"

    assert json(get("/projects?select=count()", ctx)) == [%{"count" => 2}]
  end

  test "a query column allowlist overrides a bare grant" do
    ctx = %{policy: fn r, _ -> [columns: if(r == Resources.Clients, do: ["id"], else: :all)] end}

    for path <- [
          "/clients?select=name",
          "/projects?select=id,clients(name)",
          "/projects?select=id,clients(id)&clients.order=name"
        ] do
      assert get(path, ctx).status == 401
    end
  end

  for path <- [
        "/clients?select=name",
        "/clients?select=name->>x",
        "/clients?select=name::text",
        "/clients?select=name.max()",
        "/clients?or=(name.eq.a)",
        "/clients?order=name",
        "/projects?select=id,clients(name)",
        "/projects?select=id,clients(id)&clients.name=eq.a",
        "/projects?select=id,clients(id)&clients.order=name",
        "/projects?select=id,...clients(name)"
      ] do
    test "hidden columns are denied: #{path}" do
      TelemetryProbe.attach([:pgrest, :query, :start])
      conn = get(unquote(path), tenant(), PgRest.Compat.TenantAuthorization)
      assert conn.status == 401
      assert json(conn)["code"] == "42501"
      assert json(conn)["message"] == "permission denied for table clients"
      assert TelemetryProbe.drain() == []
    end
  end

  test "star expands only allowed columns, including embeds and spreads" do
    assert json(get("/clients", tenant(), PgRest.Compat.TenantAuthorization)) == [%{"id" => 1}]
    conn = get("/projects?select=id,clients(*)", tenant(), PgRest.Compat.TenantAuthorization)
    assert Enum.all?(json(conn), &(&1["clients"] == %{"id" => 1}))
  end

  test "permissions are keyed by alias path and each callback is called once in order" do
    ctx = %{
      report_to: self(),
      query: fn q, _r, ctx ->
        if ctx.path == ["second"], do: where(q, [r], r.id == 2), else: q
      end
    }

    conn = get("/projects?select=id,first:clients(id),second:clients(id)&id=eq.1", ctx)
    assert conn.status == 200
    assert json(conn) == [%{"id" => 1, "first" => %{"id" => 1}, "second" => nil}]

    expected =
      for {r, path, root?} <- [
            {Resources.Projects, [], true},
            {Resources.Clients, ["first"], false},
            {Resources.Clients, ["second"], false}
          ],
          event <- [:authorize, :hook],
          do: {event, r, :read, path, root?}

    assert callback_trace() == expected
    assert get("/users?select=id,tasks(id)", %{report_to: self()}).status == 200

    expected =
      for {r, path, root?} <- [
            {Resources.Users, [], true},
            {Resources.UsersTasks, ["tasks", "users_tasks"], false},
            {Resources.Tasks, ["tasks"], false}
          ],
          event <- [:authorize, :hook],
          do: {event, r, :read, path, root?}

    assert callback_trace() == expected
  end

  test "a bare denial prevents the query hook" do
    conn = get("/users?select=id,tasks(id)", %{deny: Resources.Tasks, report_to: self()})
    assert conn.status == 401
    refute_received {:hook, Resources.Tasks, _, _, _}
  end

  test "query denials use the authenticated status and cannot be overridden by bare grants" do
    assert get("/clients", %{}, DenyQuery).status == 401
    assert get("/clients", %{role: :user}, DenyQuery).status == 403
  end

  test "context keys cannot switch off the mandatory query policy" do
    base = Ecto.Queryable.to_query(Resources.Clients)

    assert {:error, :denied} =
             Apply.source(
               Plug.Test.conn(:get, "/clients"),
               DenyQuery,
               Resources.Clients,
               :read,
               base,
               %{skip_bare?: true, skip_query_hook?: true}
             )
  end

  test "policy columns name physical columns even with renamed Ecto fields" do
    resource = PgRest.Test.SQLResources.Renamed
    assert Apply.check_columns(MapSet.new(["name"]), resource, ["title"]) == :ok
    assert Apply.check_columns(MapSet.new(["title"]), resource, ["title"]) == {:error, :denied}
    start_supervised!({PgRest.Registry, name: __MODULE__.Renamed, modules: [resource]})
    ctx = %{client_id: 1, policy: fn _r, _ -> [columns: ["name"]] end}

    conn =
      request(
        "GET",
        "/projects?select=name",
        nil,
        [],
        [registry: __MODULE__.Renamed] ++ opts(ctx)
      )

    assert conn.status == 200
    assert Enum.all?(json(conn), &(Map.keys(&1) == ["name"]))
  end

  test "junction aggregate and count flags cannot be bypassed through the target" do
    ctx = %{
      policy: fn r, _ ->
        [aggregates: r != Resources.UsersTasks, count: r != Resources.UsersTasks]
      end
    }

    conn = get("/users?select=id,tasks(count())", ctx)
    assert conn.status == 401
    assert json(conn)["message"] == "permission denied for table users_tasks"

    assert get("/users?select=id,tasks(id)", ctx, Policy, [{"prefer", "count=exact"}]).status ==
             401
  end

  test "related ordering by an unselected hidden column is permission denied" do
    conn =
      get(
        "/projects?select=id,clients(id)&order=clients(name)",
        tenant(),
        PgRest.Compat.TenantAuthorization
      )

    assert conn.status == 401
    assert json(conn)["code"] == "42501"
  end

  test "every junction receives narrowing and a per-parent permission limit" do
    ctx = %{
      query: fn q, r, _ ->
        if r == Resources.UsersTasks, do: where(q, [j], j.task_id in [1, 5]), else: q
      end,
      policy: fn _r, _ctx -> [limit: 1, aggregates: true, count: true] end
    }

    conn =
      get("/users?select=id,tasks(id)&tasks.order=id.desc&order=id", %{
        ctx
        | policy: fn r, _ ->
            [limit: if(r == Resources.UsersTasks, do: 1), aggregates: true, count: true]
          end
      })

    assert conn.status == 200
    rows = json(conn)
    assert length(rows) == 3
    assert Enum.map(rows, & &1["tasks"]) == [[%{"id" => 1}], [%{"id" => 5}], [%{"id" => 5}]]
    uncapped = %{ctx | policy: fn _, _ -> [aggregates: true, count: true] end}

    assert json(get("/users?select=id,tasks(id)&tasks.order=id.desc&order=id", uncapped)) ==
             [
               %{"id" => 1, "tasks" => [%{"id" => 1}]},
               %{"id" => 2, "tasks" => [%{"id" => 5}]},
               %{"id" => 3, "tasks" => [%{"id" => 5}, %{"id" => 1}]}
             ]
  end

  for suffix <- ["", "&tasks.limit=5"] do
    test "task cap is per parent #{suffix}" do
      ctx = %{
        policy: fn r, _ ->
          [limit: if(r == Resources.Tasks, do: 1), aggregates: true, count: true]
        end
      }

      conn = get("/users?select=id,tasks(id)&order=id" <> unquote(suffix), ctx)
      assert conn.status == 200
      assert Enum.map(json(conn), &length(&1["tasks"])) == [1, 1, 1]
    end
  end

  for mode <- ~w(exact planned estimated) do
    test "root cap bounds the rows and #{mode} total" do
      ctx = %{policy: fn _r, _ -> [limit: 2, aggregates: true, count: true] end}
      conn = get("/projects?limit=5", ctx, Policy, [{"prefer", "count=" <> unquote(mode)}])
      assert conn.status in [200, 206]
      assert length(json(conn)) == 2
      assert header(conn, "content-range") == "0-1/2"
    end
  end

  test "aggregates at root and lateral aggregate the capped input, including grouped rows" do
    ctx = %{
      policy: fn r, _ ->
        [limit: if(r == Resources.Projects, do: 1), aggregates: true, count: true]
      end
    }

    assert json(get("/projects?select=count()", ctx)) == [%{"count" => 1}]

    assert json(get("/projects?select=client_id,count()", ctx))
           |> Enum.map(& &1["count"])
           |> Enum.sum() == 1

    rows = json(get("/clients?select=id,projects(count())&order=id", ctx))
    assert Enum.map(rows, & &1["projects"]) == [[%{"count" => 1}], [%{"count" => 1}]]
  end

  test "capped aggregates preserve empty embeds and spread columns without alias collisions" do
    ctx = %{policy: fn _r, _ -> [limit: 1, aggregates: true, count: true] end}
    assert json(get("/clients?select=count(),projects()", ctx)) == [%{"count" => 1}]

    assert json(get("/projects?select=count(),...clients(id)", ctx)) == [
             %{"count" => 1, "id" => 1}
           ]
  end

  test "executor scrubs database constraint details for a column-only policy" do
    {:ok, snapshot} = PgRest.Registry.snapshot(PgRest.Registry)
    {:ok, req} = PgRest.Request.from_conn(Plug.Test.conn(:get, "/clients"), %{})
    base = %{repo: Repo, graph: Snapshot.graph(snapshot, "test")}
    ctx = Map.merge(base, %{authorization: Policy, policy: fn _r, _ -> [columns: ["id"]] end})
    {:ok, restricted} = PgRest.Planner.plan_read(req, Resources.Clients, ctx)
    {:ok, open} = PgRest.Planner.plan_read(req, Resources.Clients, base)

    statement =
      {"DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'failure', DETAIL = 'private row'; END $$",
       []}

    for {plan, detail} <- [{restricted, nil}, {open, "private row"}] do
      config = PgRest.Executor.config(PgRest.Plug.init(repo: Repo), plan, req.prefer)

      assert {:error, %Error{code: "23505", details: ^detail}} =
               PgRest.Executor.read(Repo, statement, nil, plan, config)
    end
  end

  test "bare query-only grants deny aggregates, counts, execute and explain" do
    assert get("/projects", %{}, Bare).status == 200

    for path <- ["/projects?select=count()", "/projects?select=count"] do
      assert get(path, %{}, Bare).status == 401
    end

    for mode <- ~w(exact planned estimated) do
      assert get("/projects", %{}, Bare, [{"prefer", "count=" <> mode}]).status == 401
    end

    assert get("/projects", %{}, Bare, [{"accept", "application/vnd.pgrst.plan"}]).status == 406
    assert get("/projects", %{}, Neither).status == 401
  end

  for method <- ~w(POST PATCH DELETE PUT) do
    test "write-query denials fail closed for #{method}, even with a bare grant" do
      TelemetryProbe.attach([:pgrest, :query, :start])

      conn =
        request(
          unquote(method),
          "/projects?id=eq.1",
          %{"id" => 1, "name" => "blocked"},
          [{"prefer", "return=representation, tx=rollback"}],
          opts(%{}, DenyQuery)
        )

      assert conn.status == 401
      assert json(conn)["code"] == "42501"
      assert TelemetryProbe.drain() == []
    end
  end

  for clause <- [:limit, :offset, :order_by, :group_by] do
    test "hook #{clause} is rejected with a configuration error naming hook and resource" do
      query =
        case unquote(clause) do
          :limit -> limit(Resources.Projects, 1)
          :offset -> offset(Resources.Projects, 1)
          :order_by -> order_by(Resources.Projects, [p], p.id)
          :group_by -> group_by(Resources.Projects, [p], p.id)
        end

      ctx = %{query: fn _q, _r, _ -> query end}

      error =
        assert_raise ArgumentError, fn ->
          Apply.source(
            Plug.Test.conn(:get, "/"),
            Policy,
            Resources.Projects,
            :read,
            Ecto.Queryable.to_query(Resources.Projects),
            ctx
          )
        end

      assert Exception.message(error) =~ inspect(Policy)
      assert Exception.message(error) =~ inspect(Resources.Projects)
    end
  end

  test "hook select and preloads are stripped, joins and distinct do not duplicate rows" do
    ctx = %{
      query: fn q, _, _ ->
        q
        |> join(:inner, [p], t in "tasks", on: t.project_id == p.id, prefix: "test")
        |> distinct(true)
        |> select([p], p.id)
        |> preload(:tasks)
      end
    }

    assert ids(get("/projects?select=id", ctx)) == [1, 2, 3, 4]
  end

  test "a replacement hook query cannot widen the base scope" do
    start_supervised!({PgRest.Registry, name: __MODULE__.Scoped, modules: [ScopedProject]})
    ctx = %{client_id: 1, query: fn _, _, _ -> Ecto.Queryable.to_query(ScopedProject) end}
    conn = request("GET", "/projects", nil, [], [registry: __MODULE__.Scoped] ++ opts(ctx))
    assert ids(conn) == [1, 2]
  end

  test "narrowing a keyless resource fails closed as permission denied" do
    ctx = %{query: fn q, _r, _ctx -> where(q, [r], not is_nil(r.a)) end}

    assert {:error, :denied} =
             Apply.source(
               Plug.Test.conn(:get, "/no_pk"),
               Policy,
               Resources.NoPk,
               :read,
               Ecto.Queryable.to_query(Resources.NoPk),
               ctx
             )

    assert get("/no_pk", ctx).status == 401
  end

  test "scope errors propagate as PgRest errors" do
    start_supervised!({PgRest.Registry, name: __MODULE__.Errors, modules: [ErrorScope]})
    conn = request("GET", "/clients", nil, [], registry: __MODULE__.Errors)
    assert conn.status == 401
    assert json(conn)["code"] == "42501"
  end

  test "a query-hook exception scrubs constraint details before a plan exists" do
    ctx = %{
      query: fn _q, _r, _ctx ->
        Repo.query!(
          "DO $$ BEGIN RAISE EXCEPTION USING ERRCODE = '23505', MESSAGE = 'policy failure', DETAIL = 'private row'; END $$"
        )
      end
    }

    conn = get("/clients", ctx)
    assert json(conn)["code"] == "23505"
    assert json(conn)["details"] == nil
  end

  test "explain receives the actual source without rerunning scope" do
    start_supervised!({PgRest.Registry, name: __MODULE__.Explain, modules: [ScopedProject]})

    ctx = %{
      client_id: 1,
      test_pid: self(),
      report_to: self(),
      query: fn q, _r, _ctx ->
        send(self(), {:source_wheres, length(q.wheres)})
        q
      end
    }

    conn =
      request(
        "GET",
        "/projects",
        nil,
        [{"accept", "application/vnd.pgrst.plan"}],
        [registry: __MODULE__.Explain] ++ opts(ctx)
      )

    assert conn.status == 200
    assert_receive {:scope_called, ScopedProject}
    refute_received {:scope_called, _}
    assert_received {:source_wheres, 1}
    assert_receive {:hook, ScopedProject, :explain, [], true}
  end

  test "authorize?: false cannot bypass the narrowing hook or hidden columns" do
    {:ok, snap} = PgRest.Registry.snapshot(PgRest.Registry)
    conn = Plug.Test.conn(:get, "/clients?select=name")
    {:ok, req} = PgRest.Request.from_conn(conn, %{})

    ctx = %{
      repo: Repo,
      graph: Snapshot.graph(snap, "test"),
      authorization: PgRest.Compat.TenantAuthorization,
      tenant_client_id: 1
    }

    assert {:error, %Error{code: "42501"}} =
             PgRest.Planner.plan_read(req, Resources.Clients, ctx, authorize?: false)

    assert {:error, %Error{code: "42501"}} =
             PgRest.Planner.plan_read(req, Resources.Clients, ctx, skip_root_rows?: true)
  end

  test "RPC stored results are narrowed and capped; :none keeps the permission cap" do
    for {name, scope} <- [{__MODULE__.Stored, :stored_rows}, {__MODULE__.Unscoped, :none}] do
      capture_log(fn ->
        start_supervised!(
          {PgRest.Registry,
           name: name,
           modules: Resources.all(),
           introspect: [repo: Repo, only: ["getallprojects"]],
           function_opts: %{{"test", "getallprojects"} => [result_scope: scope]}},
          id: name
        )
      end)

      ctx = %{
        query: fn q, r, _ ->
          if r == Resources.Projects, do: where(q, [p], p.client_id == 1), else: q
        end,
        policy: fn _r, _ -> [limit: 1, aggregates: true, count: true] end
      }

      conn =
        request(
          "GET",
          "/rpc/getallprojects?select=id&order=id.desc",
          nil,
          [],
          [registry: name] ++ opts(ctx)
        )

      assert conn.status == 200

      if scope == :stored_rows,
        do: assert(json(conn) == [%{"id" => 2}]),
        else: assert(json(conn) == [%{"id" => 5}])

      uncapped = %{ctx | policy: fn _, _ -> [aggregates: true, count: true] end}

      result =
        request(
          "GET",
          "/rpc/getallprojects?select=id&order=id.desc",
          nil,
          [],
          [registry: name] ++ opts(uncapped)
        )

      expected = if scope == :stored_rows, do: [2, 1], else: [5, 4, 3, 2, 1]
      assert json(result) == Enum.map(expected, &%{"id" => &1})
    end

    assert request(
             "GET",
             "/rpc/getallprojects",
             nil,
             [],
             [registry: __MODULE__.Stored] ++ opts(tenant(), PgRest.Compat.TenantAuthorization)
           ).status == 401
  end

  describe "unscoped RPC result grants" do
    setup do
      capture_log(fn ->
        start_supervised!(
          {PgRest.Registry,
           name: __MODULE__.ResultGrants,
           modules: Resources.all(),
           introspect: [repo: Repo, only: ["getallprojects"]],
           function_opts: %{{"test", "getallprojects"} => [result_scope: :none]}}
        )
      end)

      :ok
    end

    defp unscoped(path, ctx, auth \\ Policy, headers \\ []) do
      request(
        "GET",
        "/rpc/getallprojects" <> path,
        nil,
        headers,
        [registry: __MODULE__.ResultGrants] ++ opts(ctx, auth)
      )
    end

    test "stars keep only permitted columns" do
      conn = unscoped("?select=*&order=id", %{policy: fn _, _ -> [columns: ["id"]] end})
      assert conn.status == 200
      assert json(conn) == Enum.map(1..5, &%{"id" => &1})
    end

    test "an explicit hidden column is denied" do
      conn = unscoped("?select=name", %{policy: fn _, _ -> [columns: ["id"]] end})
      assert conn.status == 401
      assert json(conn)["code"] == "42501"
    end

    test "count requires its own grant" do
      conn =
        unscoped("?select=id", %{policy: fn _, _ -> [] end}, Policy, [{"prefer", "count=exact"}])

      assert conn.status == 401
      assert json(conn)["code"] == "42501"
    end

    test "aggregates require their own grant" do
      conn = unscoped("?select=count()", %{policy: fn _, _ -> [] end})
      assert conn.status == 401
      assert json(conn)["code"] == "42501"
    end

    test "a result query-hook denial denies execution" do
      conn = unscoped("?select=id", %{}, DenyQuery)
      assert conn.status == 401
      assert json(conn)["code"] == "42501"
    end
  end

  test "void RPC constraint details are scrubbed under a hook or RLS" do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION test.fix_wave_unique() RETURNS void LANGUAGE plpgsql AS $$
    BEGIN RAISE unique_violation USING MESSAGE = 'duplicate', DETAIL = 'private key'; END $$
    """)

    on_exit(fn -> Repo.query!("DROP FUNCTION test.fix_wave_unique()") end)

    start_supervised!(
      {PgRest.Registry,
       name: __MODULE__.Scrub,
       modules: [],
       schemas: ["test"],
       introspect: [repo: Repo, only: ["fix_wave_unique"]]}
    )

    for extra <- [
          [authorization: Policy],
          [
            rls: [
              roles: ["postgres"],
              default_role: "postgres",
              jwt: :context,
              allow_privileged_login: true
            ]
          ]
        ] do
      capture_log(fn ->
        conn =
          request("POST", "/rpc/fix_wave_unique", %{}, [], [registry: __MODULE__.Scrub] ++ extra)

        assert conn.status == 409
        assert %{"code" => "23505", "details" => nil} = json(conn)
      end)
    end
  end

  test "a volatile stored-rows RPC is narrowed and its side effects roll back" do
    start_supervised!(
      {PgRest.Registry,
       name: __MODULE__.Volatile,
       modules: Resources.all(),
       introspect: [repo: Repo, only: ["make_project"]]}
    )

    ctx = %{query: fn q, _r, _ctx -> where(q, [p], p.client_id == 1) end}
    before = Repo.query!("SELECT count(*) FROM test.projects").rows

    conn =
      request(
        "POST",
        "/rpc/make_project",
        %{"name" => "hook-rpc"},
        [{"prefer", "tx=rollback"}],
        [registry: __MODULE__.Volatile] ++ opts(ctx)
      )

    assert conn.status == 200
    assert json(conn) == nil
    assert Repo.query!("SELECT count(*) FROM test.projects").rows == before
  end

  test "function callbacks receive root path context" do
    function = %PgRest.Function{
      schema: "test",
      name: "f",
      params: [],
      returns: %PgRest.Function.Return{kind: :void, type: "void"},
      volatility: :stable
    }

    assert :ok =
             PgRest.Authorization.check(
               Policy,
               Plug.Test.conn(:get, "/rpc/f"),
               function,
               :execute,
               %{report_to: self()}
             )

    assert_received {:authorize, ^function, :execute, [], true}
  end
end
