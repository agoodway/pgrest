defmodule PgRest.PlannerTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias PgRest.Compat.Repo
  alias PgRest.Compat.Resources, as: R
  alias PgRest.{Error, Plan, Planner, Request, SchemaGraph}
  alias PgRest.Test.ReadResources

  defmodule Deny do
    @moduledoc false
    # Implements only `authorize/4`; denies the modules in `context.denied`.
    def authorize(_conn, resource, :read, %{denied: denied}) do
      if resource in denied, do: {:error, "no"}, else: :ok
    end
  end

  @graph SchemaGraph.build(R.all())

  defp request(path, headers \\ []) do
    conn =
      Enum.reduce(headers, conn("GET", path), fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)

    {:ok, request} = Request.from_conn(conn, [])
    request
  end

  defp plan(path, resource, context \\ %{}, headers \\ []) do
    Planner.plan_read(
      request(path, headers),
      resource,
      Map.merge(%{repo: Repo, graph: @graph}, context)
    )
  end

  defp plan!(path, resource, context \\ %{}) do
    assert {:ok, plan} = plan(path, resource, context)
    plan
  end

  defp error(path, resource, context \\ %{}) do
    assert {:error, %Error{} = error} = plan(path, resource, context)
    error
  end

  describe "structure" do
    test "splits select, filters, order and window" do
      plan =
        plan!("/projects?select=id,name&id=gt.1&order=name.desc&limit=2&offset=1", R.Projects)

      assert %Plan.Read{alias: "pgrst_t0", limit: 2, offset: 1} = plan
      assert Enum.map(plan.select, & &1.key) == ["id", "name"]
      assert [%{dir: :desc}] = plan.order
      assert %{children: [%{field: %{name: "id"}}]} = plan.where
    end

    test "embeds, embedded filters and order land on the embed" do
      plan =
        plan!(
          "/clients?select=id,projects(id,tasks(id))&projects.name=like.W*&projects.order=id.desc&projects.tasks.limit=1",
          R.Clients
        )

      assert [%Plan.Embed{output_name: "projects", agg_alias: "pgrst_e1"} = projects] =
               plan.embeds

      assert projects.plan.alias == "pgrst_t1"
      assert [%{dir: :desc}] = projects.plan.order
      assert [%Plan.Embed{plan: %{limit: 1, alias: "pgrst_t2"}}] = projects.plan.embeds
    end

    test "every node carries its own source query and catalog types" do
      plan = plan!("/clients?select=id,projects(id)", R.Clients)
      assert %Ecto.Query{} = plan.source_query
      assert plan.column_types["id"] == "integer"
      [%{plan: child}] = plan.embeds
      assert %Ecto.Query{} = child.source_query
    end

    test "m2m embeds carry the junction's source query" do
      plan = plan!("/users?select=id,tasks(id)", R.Users)
      assert [%Plan.Embed{junction_source_query: %Ecto.Query{}}] = plan.embeds
    end

    test "embed null filters become leaves of the where tree" do
      plan = plan!("/projects?select=name,clients()&clients=not.is.null", R.Projects)
      assert %{children: [{:null_embed, "clients", false}]} = plan.where
    end

    test "empty select returns the root's columns, `x()` embeds none" do
      assert Enum.map(plan!("/projects?select=", R.Projects).select, & &1.key) ==
               ["id", "name", "client_id"]

      assert plan!("/projects?select=clients()", R.Projects).select == []
    end

    test "key names follow PostgREST naming" do
      plan =
        plan!(
          "/complex_items?select=a:id,settings->foo->>bar,arr_data->0,id::text",
          R.ComplexItems
        )

      assert Enum.map(plan.select, & &1.key) == ["a", "bar", "arr_data", "id"]
    end

    test "count preference is kept on the root" do
      assert plan!("/items", R.Items).count == nil
      {:ok, plan} = plan("/items", R.Items, %{}, [{"prefer", "count=exact"}])
      assert plan.count == :exact
    end
  end

  describe "validation" do
    test "unknown column anywhere is the recorded 42703" do
      for path <- [
            "/items?select=nope",
            "/items?nope=eq.1",
            "/items?order=nope",
            "/clients?select=id,projects(nope)",
            "/clients?select=id,projects(id)&projects.nope=eq.1",
            "/clients?select=id,projects(id)&projects.order=nope",
            "/items?or=(nope.eq.1,id.eq.2)"
          ] do
        assert %Error{status: 400, code: "42703", message: message} =
                 error(path, R.Items |> table(path))

        assert message =~ ~r/^column \w+\.nope does not exist$/
      end
    end

    defp table(_default, "/clients" <> _), do: R.Clients
    defp table(default, _path), do: default

    test "unknown column message names the embed alias and hints" do
      assert %Error{message: "column projects_1.nope does not exist", hint: _} =
               error("/clients?select=id,projects(nope)", R.Clients)

      assert %Error{hint: ~s(Perhaps you meant to reference the column "projects.name".)} =
               error("/projects?nam=eq.1", R.Projects)
    end

    test "a URL-sized unknown column name is answered quickly and unhinted" do
      long = String.duplicate("n", 8_000)

      {micros, result} = :timer.tc(fn -> error("/projects?#{long}=eq.1", R.Projects) end)

      assert %Error{code: "42703", hint: nil} = result
      assert micros < 200_000
    end

    test "an unknown key that is not a custom param is a 400, a declared one is not" do
      assert %Error{status: 400, code: "42703"} = error("/items?bogus=eq.1", R.Items)

      assert %Error{status: 400, code: "PGRST100"} = error("/items?bogus=1", R.Items)
    end

    test "a key without = is ignored, ?id= is a filter" do
      assert {:ok, %Plan.Read{where: nil}} = plan("/items?id", R.Items)
      assert %Error{code: "PGRST100"} = error("/items?id=", R.Items)
    end

    test "a filter or order on an embed missing from the select is PGRST108" do
      assert %Error{status: 400, code: "PGRST108", message: message} =
               error("/clients?select=id&nope.id=eq.1", R.Clients)

      assert message == "'nope' is not an embedded resource in this request"

      assert %Error{code: "PGRST108"} =
               error("/projects?select=id,clients(id)&order=x(id)", R.Projects)
    end

    test "ordering by a to-many embed is PGRST118" do
      assert %Error{
               status: 400,
               code: "PGRST118",
               message: "A related order on 'projects' is not possible"
             } =
               error("/clients?select=id,projects(id)&order=projects(id)", R.Clients)
    end

    test "ordering by an embed column that is not selected is 42703" do
      assert %Error{code: "42703", message: "column projects_clients_1.name does not exist"} =
               error("/projects?select=id,clients(id)&order=clients(name)", R.Projects)
    end

    test "aggregates are PGRST123" do
      assert %Error{status: 400, code: "PGRST123"} = error("/items?select=count()", R.Items)
      assert %Error{code: "PGRST123"} = error("/clients?select=projects(id.sum())", R.Clients)
    end

    test "relationship errors come from the graph" do
      assert %Error{code: "PGRST200"} = error("/clients?select=nope(id)", R.Clients)

      assert %Error{status: 300, code: "PGRST201"} =
               error("/orders?select=addresses(*)", R.Orders)
    end

    test "a count mode outside count_modes is a 400" do
      assert {:error, %Error{status: 400, message: "count=exact is not allowed"}} =
               plan("/items", R.Items, %{count_modes: [:planned]}, [{"prefer", "count=exact"}])

      assert {:ok, _} =
               plan("/items", R.Items, %{count_modes: [:planned]}, [{"prefer", "count=planned"}])
    end
  end

  describe "embedding depth" do
    # clients -> projects -> clients -> ...
    defp alternating(depth, level \\ 1)
    defp alternating(0, _level), do: "id"

    defp alternating(depth, level) do
      name = if rem(level, 2) == 1, do: "projects", else: "client"
      "id,#{name}(#{alternating(depth - 1, level + 1)})"
    end

    test "nesting past max_embed_depth is a 400 before anything else" do
      path = "/clients?select=" <> alternating(9)

      assert %Error{status: 400, code: "PGRST100", message: "embedding depth exceeds 8"} =
               error(path, R.Clients)
    end

    test "the configured depth is used and exactly that deep is planned" do
      assert %Error{message: "embedding depth exceeds 2"} =
               error("/clients?select=id,projects(id,tasks(id,users(id)))", R.Clients, %{
                 max_embed_depth: 2
               })

      assert {:ok, _} =
               plan("/clients?select=id,projects(id,tasks(id))", R.Clients, %{max_embed_depth: 2})
    end

    test "a thousand levels are rejected without resolving anything" do
      select = String.duplicate("projects(", 1000) <> "id" <> String.duplicate(")", 1000)

      assert %Error{message: "embedding depth exceeds 8"} =
               error("/clients?select=" <> select, R.Clients)
    end

    test "eight levels plan" do
      assert {:ok, _} = plan("/clients?select=" <> alternating(8), R.Clients)
    end
  end

  describe "readable columns" do
    test "a non-readable column is a 401 42501 in select, filter, logic, order and embeds" do
      for path <- [
            "/accounts?select=hashed_password",
            "/accounts?hashed_password=eq.x",
            "/accounts?or=(hashed_password.eq.x,id.eq.1)",
            "/accounts?order=hashed_password"
          ] do
        assert %Error{status: 401, code: "42501", message: "permission denied for table accounts"} =
                 error(path, R.Accounts)
      end
    end

    test "* expands to the readable columns only" do
      keys = fn plan -> Enum.map(plan.select, & &1.key) end
      refute "hashed_password" in keys.(plan!("/accounts", R.Accounts))
      refute "hashed_password" in keys.(plan!("/accounts?select=*", R.Accounts))
      assert "email" in keys.(plan!("/accounts", R.Accounts))
    end
  end

  describe "authorization" do
    test "is asked about the root, each embed and the m2m junction, failing closed" do
      assert %Error{status: 401, code: "42501", message: "permission denied for table clients"} =
               error("/clients", R.Clients, %{authorization: Deny, denied: [R.Clients]})

      assert %Error{message: "permission denied for table clients"} =
               error("/projects?select=*,clients(*)", R.Projects, %{
                 authorization: Deny,
                 denied: [R.Clients]
               })

      assert %Error{message: "permission denied for table users_tasks"} =
               error("/users?select=tasks(*)", R.Users, %{
                 authorization: Deny,
                 denied: [R.UsersTasks]
               })

      assert %Error{message: "permission denied for table tasks"} =
               error("/clients?select=projects(tasks(id))", R.Clients, %{
                 authorization: Deny,
                 denied: [R.Tasks]
               })

      assert {:ok, _} =
               plan("/clients?select=projects(id)", R.Clients, %{authorization: Deny, denied: []})
    end
  end

  describe "reserved keys" do
    test "columns and on_conflict are ignored on reads" do
      assert {:ok, %Plan.Read{where: nil}} = plan("/items?columns=id&on_conflict=id", R.Items)
    end
  end

  describe "effective source" do
    test "scope/2 runs once per resource per request" do
      {:ok, _} =
        Planner.plan_read(
          request("/clients?select=*,projects(*)"),
          ReadResources.Clients,
          %{
            repo: Repo,
            graph: SchemaGraph.build([ReadResources.Clients, ReadResources.Projects]),
            test_pid: self()
          }
        )

      assert_received {:scope_called, ReadResources.Projects}
      refute_received {:scope_called, _}
    end

    test "a repeated embed of the same resource shares one scope call" do
      {:ok, _} =
        Planner.plan_read(
          request("/clients?select=a:projects(id),b:projects(id)"),
          ReadResources.Clients,
          %{
            repo: Repo,
            graph: SchemaGraph.build([ReadResources.Clients, ReadResources.Projects]),
            test_pid: self()
          }
        )

      assert_received {:scope_called, ReadResources.Projects}
      refute_received {:scope_called, _}
    end
  end

  describe "limits" do
    test "max_limit is carried by every node" do
      plan =
        plan!("/clients?select=id,projects(id,tasks(id)),users:projects(id)", R.Clients, %{
          max_limit: 2
        })

      assert plan.max_limit == 2
      assert Enum.all?(plan.embeds, &(&1.plan.max_limit == 2))
      assert Enum.all?(hd(plan.embeds).plan.embeds, &(&1.plan.max_limit == 2))
    end
  end
end
