defmodule DemoWeb.PageControllerTest do
  use DemoWeb.ConnCase

  test "GET / renders the PgRest demo home", %{conn: conn} do
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)
    assert body =~ "PgRest Demo"
    assert body =~ "Example Queries"
  end
end
