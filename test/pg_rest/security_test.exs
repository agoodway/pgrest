defmodule PgRest.SecurityTest do
  # Security regressions across the read and write pipelines: `allow:` on every resource a
  # request touches, `readable:` on `Location`, and the scope's schema prefix on writes.
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [json: 1, register: 1, request: 5]

  alias PgRest.Test.SecurityResources

  @plug_opts [tx_end: :commit_allow_override, require_filters_for_mutations: false]

  defp send_req(method, path, body \\ nil, prefer \\ "tx=rollback"),
    do: request(method, path, body, [{"prefer", prefer}], @plug_opts)

  defp assert_denied(conn, table) do
    assert conn.status == 401

    assert %{"code" => "42501", "message" => "permission denied for table " <> ^table} =
             json(conn)
  end

  describe "allow: without :read" do
    setup do
      register(SecurityResources.allow())
      :ok
    end

    test "an embed of the resource is denied" do
      assert_denied(send_req("GET", "/clients?select=id,projects(id,name)"), "projects")
    end

    test "a spread of the resource is denied" do
      assert_denied(send_req("GET", "/tasks?select=id,...projects(name)"), "projects")
    end

    test "a many-to-many embed through a junction the resource cannot read is denied" do
      assert_denied(send_req("GET", "/tasks?select=id,users(id)"), "users_tasks")
    end

    test "the embed is denied in a write's representation too" do
      conn =
        send_req(
          "POST",
          "/clients?select=id,projects(id)",
          %{"id" => 9901, "name" => "c"},
          "return=representation, tx=rollback"
        )

      assert_denied(conn, "projects")
    end

    test "POST with return=representation is denied" do
      body = %{"id" => 9901, "name" => "p", "client_id" => 1}
      conn = send_req("POST", "/projects", body, "return=representation, tx=rollback")
      assert_denied(conn, "projects")
    end

    test "POST with return=headers-only (a Location) is denied" do
      body = %{"id" => 9901, "name" => "p", "client_id" => 1}
      conn = send_req("POST", "/projects", body, "return=headers-only, tx=rollback")
      assert_denied(conn, "projects")
    end

    test "POST with a count is denied" do
      body = %{"id" => 9901, "name" => "p", "client_id" => 1}
      assert_denied(send_req("POST", "/projects", body, "count=exact, tx=rollback"), "projects")
    end

    test "PATCH and DELETE with a filter are denied" do
      assert_denied(send_req("PATCH", "/projects?id=eq.1", %{"name" => "z"}), "projects")
      assert_denied(send_req("DELETE", "/projects?id=eq.1"), "projects")
    end

    test "the allowed operations still work when they read nothing" do
      body = %{"id" => 9901, "name" => "p", "client_id" => 1}
      assert send_req("POST", "/projects", body).status == 201
      assert send_req("PATCH", "/projects", %{"name" => "z"}).status == 204
      assert send_req("GET", "/clients?select=id&id=eq.1").status == 200
      assert [%{"id" => 1}] = json(send_req("GET", "/tasks?select=id&id=eq.1"))
    end
  end

  describe "readable: and Location" do
    setup do
      register([SecurityResources.PkHidden])
      :ok
    end

    test "headers-only is denied when the primary key is not readable" do
      conn =
        send_req(
          "POST",
          "/clients",
          %{"id" => 9902, "name" => "x"},
          "return=headers-only, tx=rollback"
        )

      assert_denied(conn, "clients")
      assert Plug.Conn.get_resp_header(conn, "location") == []
    end

    test "a write without a Location still works" do
      assert send_req("POST", "/clients", %{"id" => 9902, "name" => "x"}).status == 201
    end
  end

  describe "a scope that sets the schema prefix" do
    setup do
      register([SecurityResources.TenantTasks])
      :ok
    end

    test "reads and writes all reach the scope's schema" do
      assert [%{"id" => 1}] = json(send_req("GET", "/tasks?select=id&id=eq.1"))

      rep = "return=representation, tx=rollback"

      post = send_req("POST", "/tasks?select=id,name", %{"id" => 9903, "name" => "t"}, rep)
      assert {post.status, json(post)} == {201, [%{"id" => 9903, "name" => "t"}]}

      patch = send_req("PATCH", "/tasks?id=eq.1&select=id,name", %{"name" => "z"}, rep)
      assert {patch.status, json(patch)} == {200, [%{"id" => 1, "name" => "z"}]}

      delete = send_req("DELETE", "/tasks?id=eq.8&select=id", nil, rep)
      assert {delete.status, json(delete)} == {200, [%{"id" => 8}]}

      upsert =
        send_req(
          "POST",
          "/tasks?select=id,name",
          %{"id" => 1, "name" => "u"},
          "resolution=merge-duplicates, return=representation, tx=rollback"
        )

      assert {upsert.status, json(upsert)} == {200, [%{"id" => 1, "name" => "u"}]}
    end

    test "the catalog and the search_path use the scope's schema" do
      {:ok, request} = PgRest.Request.from_conn(Plug.Test.conn("GET", "/tasks"), [])

      {:ok, plan} =
        PgRest.Planner.plan_read(request, SecurityResources.TenantTasks, %{
          repo: PgRest.Compat.Repo,
          graph: PgRest.Registry.graph()
        })

      # `integer` is the catalog type of test.tasks.id; without the catalog it would be the
      # Ecto fallback `bigint`.
      assert plan.column_types["id"] == "integer"

      assert PgRest.Executor.config(
               PgRest.Plug.init(repo: PgRest.Compat.Repo),
               plan,
               %PgRest.Prefer{}
             ).search_path ==
               ["test", "public"]
    end
  end

  describe "custom params on PATCH and DELETE" do
    defmodule DenyRead do
      @moduledoc false
      def authorize(_conn, _resource, :read, _context), do: {:error, "no"}
      def authorize(_conn, _resource, _operation, _context), do: :ok
    end

    setup do
      register([PgRest.Test.ReadResources.Searchable])
      :ok
    end

    test "a custom param is a filter: it needs :read" do
      conn =
        request("PATCH", "/projects?q=Win", %{"name" => "z"}, [{"prefer", "tx=rollback"}],
          tx_end: :commit_allow_override,
          authorization: DenyRead
        )

      assert_denied(conn, "projects")
    end

    test "a custom param alone does not satisfy require_filters_for_mutations" do
      register_search()
      opts = [tx_end: :commit_allow_override]
      headers = [{"prefer", "tx=rollback"}]

      for {method, body} <- [{"PATCH", %{"name" => "z"}}, {"DELETE", nil}] do
        conn = request(method, "/clients?search=", body, headers, opts)
        assert {conn.status, json(conn)["code"]} == {400, "21000"}, method
      end

      assert request("PATCH", "/clients?search=&id=eq.1", %{"name" => "z"}, headers, opts).status ==
               204
    end

    test "the write check uses the scope only, not a custom param" do
      register_search()

      conn =
        request(
          "PATCH",
          "/clients?search=soft&id=eq.1&select=id,name",
          %{"name" => "zz"},
          [{"prefer", "return=representation, tx=rollback"}],
          tx_end: :commit_allow_override
        )

      assert {conn.status, json(conn)} == {200, [%{"id" => 1, "name" => "zz"}]}
    end
  end

  describe "the request context cannot switch authorization off" do
    setup do
      register(SecurityResources.allow())
      :ok
    end

    test "a context_builder map with authorize?: false still has embeds authorized" do
      conn =
        request("GET", "/clients?select=id,projects(id)", nil, [],
          context_builder: fn _conn, _opts -> %{authorize?: false} end
        )

      assert_denied(conn, "projects")
    end
  end

  # Replaces the registry of the describe's setup with one holding SearchClients.
  defp register_search do
    stop_supervised!(PgRest.Registry)
    register([SecurityResources.SearchClients])
  end
end
