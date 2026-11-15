defmodule PgRest.ResponderTest do
  use ExUnit.Case, async: true

  alias PgRest.{Error, Responder}
  alias PgRest.Error.Translate

  test "custom RAISE headers override generated error headers case-insensitively" do
    error = %Error{
      status: 401,
      code: "123",
      message: "ABC",
      headers: [{"Content-Type", "application/problem+json"}, {"WWW-Authenticate", "Custom"}]
    }

    conn = Responder.error(Plug.Test.conn("GET", "/"), error)
    assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/problem+json"]
    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == ["Custom"]
    assert Jason.decode!(conn.resp_body)["code"] == "123"
  end

  test "a parsed PGRST 401 with an empty header map has no Bearer challenge" do
    error =
      Translate.from_exception(
        %Postgrex.Error{
          postgres: %{
            pg_code: "PGRST",
            message: ~s|{"code":"123","message":"ABC"}|,
            detail: ~s|{"status":401,"headers":{}}|
          }
        },
        :anon
      )

    conn = Responder.error(Plug.Test.conn("GET", "/"), error)
    assert conn.status == 401
    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == []
  end

  test "a custom 401 carrying unrelated headers has no Bearer challenge" do
    error = %Error{status: 401, code: "custom", message: "ABC", headers: [{"X-Custom", "value"}]}
    conn = Responder.error(Plug.Test.conn("GET", "/"), error)
    assert Plug.Conn.get_resp_header(conn, "x-custom") == ["value"]
    assert Plug.Conn.get_resp_header(conn, "www-authenticate") == []
  end

  test "PgRest permission and authentication 401s retain their challenges" do
    for error <- [
          Error.permission_denied(:table, "items", :anon),
          %Error{status: 401, code: "PGRST301", message: "invalid token"}
        ] do
      conn = Responder.error(Plug.Test.conn("GET", "/"), error)
      assert Plug.Conn.get_resp_header(conn, "www-authenticate") == ["Bearer"]
    end
  end
end
