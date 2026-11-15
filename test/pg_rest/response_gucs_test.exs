defmodule PgRest.ResponseGucsTest do
  # Not async: starts a named registry over the shared compat fixture.
  use ExUnit.Case, async: false

  alias PgRest.Compat.{Functions, Repo, Resources}
  alias PgRest.{Error, ResponseGucs}

  @registry PgRest.ResponseGucsTest.Registry

  describe "decode/2" do
    test "nil, nil is no override" do
      assert ResponseGucs.decode(nil, nil) == {:ok, %{headers: [], status: nil}}
    end

    test "headers decode in order" do
      raw = ~s|[{"X-Test":"a"},{"X-Test-2":"b"}]|

      assert ResponseGucs.decode(raw, nil) ==
               {:ok, %{headers: [{"X-Test", "a"}, {"X-Test-2", "b"}], status: nil}}
    end

    test "an empty array adds no header" do
      assert ResponseGucs.decode("[]", nil) == {:ok, %{headers: [], status: nil}}
    end

    for {name, raw} <- [
          object: ~s|{"X-Test":"x"}|,
          strings: ~s|["a","b"]|,
          two_keys: ~s|[{"a":"1","b":"2"}]|,
          empty_object: ~s|[{}]|,
          non_string_value: ~s|[{"a":1}]|,
          not_json: "nope"
        ] do
      test "#{name} is PGRST111" do
        assert {:error, %Error{code: "PGRST111", status: 500} = error} =
                 ResponseGucs.decode(unquote(raw), nil)

        assert error.message ==
                 "response.headers guc must be a JSON array composed of objects with a single key and a string value"

        assert error.details == nil and error.hint == nil
      end
    end

    for {name, raw} <- [
          empty_name: ~s|[{"":"x"}]|,
          crlf_value: ~s|[{"X-A":"a\\r\\nSet-Cookie: x=1"}]|,
          lf_value: ~s|[{"X-A":"a\\nb"}]|,
          cr_value: ~s|[{"X-A":"a\\rb"}]|,
          nul_value: ~s|[{"X-A":"a\\u0000b"}]|,
          control_value: ~s|[{"X-A":"a\\u001fb"}]|,
          del_value: ~s|[{"X-A":"a\\u007fb"}]|,
          crlf_name: ~s|[{"X-A\\r\\nSet-Cookie":"x"}]|,
          space_name: ~s|[{"X A":"x"}]|,
          colon_name: ~s|[{"X:A":"x"}]|,
          nul_name: ~s|[{"X\\u0000A":"x"}]|,
          non_ascii_name: ~s|[{"X-\\u00e9":"x"}]|,
          injected_second_header: ~s|[{"X-Ok":"1"},{"X-A":"a\\r\\nb"}]|
        ] do
      test "a header with #{name} is PGRST111, never reaches the response" do
        assert {:error, %Error{code: "PGRST111", status: 500}} =
                 ResponseGucs.decode(unquote(raw), nil)
      end
    end

    test "tab and obs-text in a value, and token characters in a name, are accepted" do
      raw = ~s/[{"X-Weird_Name.1!#$%&'*+^`|~":"a\\tb \\u00e9"}]/

      assert {:ok, %{headers: [{"X-Weird_Name.1!#$%&'*+^`|~", "a\tb \u00e9"}]}} =
               ResponseGucs.decode(raw, nil)
    end

    test "a status decodes to an integer" do
      assert ResponseGucs.decode(nil, "403") == {:ok, %{headers: [], status: 403}}
    end

    test "the leading digits are the status, as PostgREST reads it" do
      for raw <- ["403abc", "403 ", "0403", "403 abc"] do
        assert ResponseGucs.decode(nil, raw) == {:ok, %{headers: [], status: 403}}
      end

      assert ResponseGucs.decode(nil, "999") == {:ok, %{headers: [], status: 999}}
      assert ResponseGucs.decode(nil, "200") == {:ok, %{headers: [], status: 200}}
    end

    test "a sign, a leading space, an empty value or a status outside 200..999 is PGRST112" do
      for raw <- [" 403", "+403", "-403", "", "0", "99", "100", "199", "1000", "abc"] do
        assert {:error, %Error{code: "PGRST112"}} = ResponseGucs.decode(nil, raw)
      end
    end

    test "a bad status is PGRST112" do
      assert {:error, %Error{code: "PGRST112", status: 500, message: message}} =
               ResponseGucs.decode(nil, "bad")

      assert message == "response.status guc must be a valid status code"
    end

    test "the status is decoded before the headers, as PostgREST does" do
      assert {:error, %Error{code: "PGRST112"}} = ResponseGucs.decode("{}", "bad")
      assert {:error, %Error{code: "PGRST111"}} = ResponseGucs.decode("{}", "403")
    end
  end

  describe "apply/2" do
    defp base do
      "GET"
      |> Plug.Test.conn("/")
      |> Plug.Conn.put_resp_header("location", "/generated")
      |> Plug.Conn.put_resp_header("content-type", "application/json")
    end

    test "a GUC location replaces the generated one, whatever the case" do
      conn = ResponseGucs.apply(base(), %{headers: [{"Location", "/guc"}], status: nil})

      assert Plug.Conn.get_resp_header(conn, "location") == ["/guc"]
      assert Plug.Conn.get_resp_header(conn, "content-type") == ["application/json"]
    end

    test "a GUC content-type replaces the generated one" do
      conn = ResponseGucs.apply(base(), %{headers: [{"Content-Type", "text/csv"}], status: nil})

      assert Plug.Conn.get_resp_header(conn, "content-type") == ["text/csv"]
    end

    test "repeated names are all kept, in order" do
      headers = [{"Set-Cookie", "a=1"}, {"Set-Cookie", "b=2"}]
      conn = ResponseGucs.apply(base(), %{headers: headers, status: nil})

      assert Plug.Conn.get_resp_header(conn, "set-cookie") == ["a=1", "b=2"]
    end

    test "apply/2 leaves the status to the caller" do
      assert ResponseGucs.apply(base(), %{headers: [], status: 205}).status == nil
    end

    test "status/2 is the GUC status, else the default" do
      assert ResponseGucs.status(%{headers: [], status: 205}, 200) == 205
      assert ResponseGucs.status(ResponseGucs.none(), 200) == 200
    end

    test "none/0 is what decode/2 gives for nil, nil" do
      assert ResponseGucs.decode(nil, nil) == {:ok, ResponseGucs.none()}
    end
  end

  describe "through the plug" do
    setup do
      start_supervised!(
        {PgRest.Registry,
         name: @registry,
         modules: Resources.all(),
         introspect: [repo: Repo, only: Functions.test_functions()]}
      )

      :ok
    end

    defp call(method, path, headers \\ []) do
      conn =
        Enum.reduce(headers, Plug.Test.conn(method, path), fn {k, v}, c ->
          Plug.Conn.put_req_header(c, k, v)
        end)

      PgRest.Plug.call(
        conn,
        PgRest.Plug.init(repo: Repo, registry: @registry, tx_end: :commit_allow_override)
      )
    end

    defp call_json(method, path, body, headers \\ []) do
      conn =
        method
        |> Plug.Test.conn(path, body)
        |> Plug.Conn.put_req_header("content-type", "application/json")

      conn = Enum.reduce(headers, conn, fn {k, v}, c -> Plug.Conn.put_req_header(c, k, v) end)

      PgRest.Plug.call(
        conn,
        PgRest.Plug.init(repo: Repo, registry: @registry, tx_end: :commit_allow_override)
      )
    end

    test "an RPC that sets response.status and then raises returns the raise's error" do
      conn = call("POST", "/rpc/status_then_raise")

      assert conn.status == 400
      assert Jason.decode!(conn.resp_body)["message"] == "boom"
    end

    test "GUC headers and status reach the response" do
      conn = call("GET", "/rpc/get_int_and_guc_headers?num=1")

      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "x-test-2") == ["key1=val1"]
    end

    test "the GUCs are applied under tx=rollback" do
      conn = call("POST", "/rpc/send_body_status_403", [{"prefer", "tx=rollback"}])

      assert conn.status == 403
      assert Jason.decode!(conn.resp_body) == %{"message" => "invalid user or password"}
    end

    test "a GUC header value with CR/LF is a PGRST111 500, no header is injected" do
      body = Jason.encode!(%{"raw" => ~s|[{"X-A":"a\\r\\nSet-Cookie: x=1"}]|})
      conn = call_json("POST", "/rpc/guc_headers_raw", body)

      assert conn.status == 500
      assert Jason.decode!(conn.resp_body)["code"] == "PGRST111"
      assert Plug.Conn.get_resp_header(conn, "set-cookie") == []
      assert Plug.Conn.get_resp_header(conn, "x-a") == []
    end

    test "a GUC header with an empty name is a PGRST111 500" do
      body = Jason.encode!(%{"raw" => ~s|[{"":"x"}]|})
      conn = call_json("POST", "/rpc/guc_headers_raw", body)

      assert conn.status == 500
      assert Jason.decode!(conn.resp_body)["code"] == "PGRST111"
      assert Enum.all?(conn.resp_headers, fn {name, _value} -> name != "" end)
    end

    test "a repeated GUC header stays repeated through the plug" do
      conn = call("GET", "/rpc/set_cookie_twice")

      assert conn.status == 204
      assert [_first, _second] = Plug.Conn.get_resp_header(conn, "set-cookie")
    end

    test "no response header has an empty name or value" do
      for {method, path, body} <- [
            {"POST", "/loc_test", ~s|{"id": 1, "c": "c1"}|},
            {"PATCH", "/loc_test?id=eq.1", ~s|{"c": "c2"}|},
            {"GET", "/loc_test", ""},
            {"DELETE", "/loc_test?id=eq.1", ""},
            {"GET", "/rpc/set_cookie_twice", ""},
            {"GET", "/rpc/get_projects_and_guc_headers", ""}
          ] do
        conn = call_json(method, path, body, [{"prefer", "tx=rollback"}])

        assert Enum.all?(conn.resp_headers, fn {name, value} -> name != "" and value != "" end),
               "#{method} #{path}: #{inspect(conn.resp_headers)}"
      end
    end

    test "bad headers are a PGRST111 500 and roll back" do
      conn = call("GET", "/rpc/bad_guc_headers_1")

      assert conn.status == 500
      assert Jason.decode!(conn.resp_body)["code"] == "PGRST111"
    end
  end
end
