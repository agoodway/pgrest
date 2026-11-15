defmodule PgRest.PlugTest do
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [json: 1, register: 1, request: 3]

  alias PgRest.Compat.Resources

  # HTTP surface of the plug over the compat fixture. Per-feature behaviour lives in the
  # plug_read, insert, update_delete and upsert tests and in the compat scenarios.

  setup do
    register(Resources.all())
    :ok
  end

  describe "routing" do
    test "GET /<table> is served" do
      conn = request("GET", "/clients?select=id&order=id", nil)

      assert conn.status == 200
      assert json(conn) == [%{"id" => 1}, %{"id" => 2}]
      assert {"content-type", "application/json; charset=utf-8"} in conn.resp_headers
    end

    test "an unknown table is a PGRST205 404" do
      conn = request("GET", "/nonexistent", nil)

      assert conn.status == 404
      assert %{"code" => "PGRST205"} = json(conn)
    end

    test "the 0.1 /<table>/<id> routes are gone for every method" do
      for method <- ["GET", "PATCH", "DELETE"] do
        conn = request(method, "/items/1", nil)
        assert conn.status == 404
        assert %{"code" => "PGRST125"} = json(conn)
      end
    end

    test "an unsupported method is a 405 error body" do
      conn = request("TRACE", "/items", nil)

      assert conn.status == 405
      assert %{"code" => "PGRST117"} = json(conn)
    end
  end

  describe "error bodies" do
    test "carry exactly the four PostgREST keys and never the 0.1 error key" do
      body = "GET" |> request("/nonexistent", nil) |> json()

      assert body |> Map.keys() |> Enum.sort() == ["code", "details", "hint", "message"]
    end
  end

  describe "context" do
    test "the default context comes from conn.assigns" do
      builder = fn conn, _opts ->
        send(self(), {:assigns, conn.assigns})
        %{}
      end

      "GET"
      |> Plug.Test.conn("/clients")
      |> Plug.Conn.assign(:user_id, 42)
      |> PgRest.Plug.call(PgRest.Plug.init(repo: PgRest.Compat.Repo, context_builder: builder))

      assert_received {:assigns, %{user_id: 42}}
    end
  end
end
