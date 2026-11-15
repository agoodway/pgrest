defmodule PgRest.Integration.E2ETest do
  use PgRest.Integration.Case, async: false

  alias Supabase.PostgREST

  defp select(client, table, columns \\ "*") do
    client |> PostgREST.from(table) |> PostgREST.select(columns, returning: true)
  end

  describe "reads" do
    test "list all rows", %{client: client} do
      {:ok, resp} = client |> select("clients") |> PostgREST.execute()

      assert resp.status in [200, 206]
      assert resp.body |> Enum.map(& &1["name"]) |> Enum.sort() == ["Apple", "Microsoft"]
    end

    test "filter eq", %{client: client} do
      {:ok, resp} =
        client |> select("projects") |> PostgREST.eq("client_id", 1) |> PostgREST.execute()

      assert Enum.sort(Enum.map(resp.body, & &1["name"])) == ["Windows 10", "Windows 7"]
    end

    test "filter range with gt and lt", %{client: client} do
      {:ok, resp} =
        client
        |> select("items")
        |> PostgREST.all_of([{:gt, "id", 3}, {:lt, "id", 6}])
        |> PostgREST.order("id", asc: true)
        |> PostgREST.execute()

      assert Enum.map(resp.body, & &1["id"]) == [4, 5]
    end

    test "filter ilike", %{client: client} do
      {:ok, resp} =
        client
        |> select("projects")
        |> PostgREST.ilike("name", "%WINDOWS%")
        |> PostgREST.execute()

      assert length(resp.body) == 2
    end

    test "order descending", %{client: client} do
      {:ok, resp} =
        client
        |> select("items", ["id"])
        |> PostgREST.order("id")
        |> PostgREST.limit(3)
        |> PostgREST.execute()

      assert Enum.map(resp.body, & &1["id"]) == [15, 14, 13]
    end

    test "range pages the rows", %{client: client} do
      {:ok, resp} =
        client
        |> select("items", ["id"])
        |> PostgREST.order("id", asc: true)
        |> PostgREST.range(1, 2)
        |> PostgREST.execute()

      assert resp.status == 206
      assert Enum.map(resp.body, & &1["id"]) == [2, 3]
    end

    test "select specific columns", %{client: client} do
      {:ok, resp} = client |> select("projects", ["id", "name"]) |> PostgREST.execute()

      first = hd(resp.body)
      assert Map.keys(first) |> Enum.sort() == ["id", "name"]
    end
  end

  describe "embeds" do
    test "one-to-many", %{client: client} do
      {:ok, resp} =
        client
        |> select("clients", ["id", "projects(id)"])
        |> PostgREST.eq("id", 1)
        |> PostgREST.execute()

      assert [%{"projects" => projects}] = resp.body
      assert length(projects) == 2
    end

    test "many-to-one", %{client: client} do
      {:ok, resp} =
        client
        |> select("projects", ["id", "clients(name)"])
        |> PostgREST.eq("id", 3)
        |> PostgREST.execute()

      assert [%{"clients" => %{"name" => "Apple"}}] = resp.body
    end
  end

  describe "writes (rolled back)" do
    test "insert returns the representation", %{client: client} do
      {:ok, resp} =
        client
        |> PostgREST.from("clients")
        |> PostgREST.insert(%{"id" => 100, "name" => "New Client"})
        |> PostgREST.rollback()
        |> PostgREST.execute()

      assert resp.status == 201
      assert [%{"id" => 100, "name" => "New Client"}] = resp.body
    end

    test "update by filter", %{client: client} do
      {:ok, resp} =
        client
        |> PostgREST.from("clients")
        |> PostgREST.update(%{"name" => "Renamed"})
        |> PostgREST.eq("id", 1)
        |> PostgREST.rollback()
        |> PostgREST.execute()

      assert resp.status == 200
      assert [%{"id" => 1, "name" => "Renamed"}] = resp.body
    end

    test "delete by filter", %{client: client} do
      {:ok, resp} =
        client
        |> PostgREST.from("projects")
        |> PostgREST.delete()
        |> PostgREST.eq("id", 5)
        |> PostgREST.rollback()
        |> PostgREST.execute()

      assert resp.status == 200
      assert [%{"id" => 5, "name" => "Orphan"}] = resp.body
    end

    test "the rollback left the fixture untouched", %{client: client} do
      {:ok, resp} =
        client |> select("projects", ["id"]) |> PostgREST.eq("id", 5) |> PostgREST.execute()

      assert [%{"id" => 5}] = resp.body
    end
  end

  describe "errors" do
    test "a unique violation is a PostgREST 409", %{client: client, base_url: base_url} do
      {:error, error} =
        client
        |> PostgREST.from("clients")
        |> PostgREST.insert(%{"id" => 1, "name" => "dup"})
        |> PostgREST.rollback()
        |> PostgREST.execute()

      assert error.metadata.resp_status == 409

      # The client reads the body with atom keys and so drops the code; read it raw.
      resp =
        Req.post!("#{base_url}/rest/v1/clients",
          json: %{"id" => 1, "name" => "dup"},
          headers: [{"prefer", "tx=rollback"}]
        )

      assert resp.status == 409
      assert resp.body["code"] == "23505"
    end
  end
end
