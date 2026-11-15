defmodule PgRest.RequestTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PgRest.{Prefer, Request}

  @parser_opts [parsers: [:json], pass: ["*/*"], json_decoder: Jason]

  defp json_conn(method, path, body) do
    method |> conn(path, body) |> put_req_header("content-type", "application/json")
  end

  describe "from_conn/2 basics" do
    test "extracts method, path, ordered params, accept, prefer and range" do
      conn =
        :get
        |> conn("/items?id=gt.1&id=lt.5&limit=2&offset=1")
        |> put_req_header("accept", "application/json")
        |> put_req_header("prefer", "count=exact")

      assert {:ok, %Request{} = request} = Request.from_conn(conn, [])
      assert request.method == "GET"
      assert request.path == ["items"]
      assert request.params == [{"id", "gt.1"}, {"id", "lt.5"}, {"limit", "2"}, {"offset", "1"}]
      assert [%{kind: :json}] = request.accepts
      assert %Prefer{count: :exact} = request.prefer
      assert request.range == %{offset: 1, limit: 2}
      assert request.body == nil
      assert request.raw_body == nil
      assert request.conn == conn
    end

    test "an absent Accept is any type" do
      assert {:ok, %Request{accepts: [%{kind: :any}]}} =
               Request.from_conn(conn(:get, "/items"), [])
    end

    test "Range header applies to GET only" do
      get = put_req_header(conn(:get, "/items"), "range", "0-4")
      assert {:ok, %Request{range: %{offset: 0, limit: 5}}} = Request.from_conn(get, [])
      head = put_req_header(conn(:head, "/items"), "range", "0-4")
      assert {:ok, %Request{range: %{offset: 0, limit: nil}}} = Request.from_conn(head, [])
    end

    test "range and query string errors surface" do
      assert {:error, %PgRest.Error{status: 416}} =
               Request.from_conn(conn(:get, "/items?limit=-1"), [])

      assert {:error, %PgRest.Error{status: 400, code: "PGRST100"}} =
               Request.from_conn(conn(:get, "/items?id=eq.%zz"), [])
    end
  end

  describe "tx_end" do
    setup do
      %{conn: put_req_header(conn(:get, "/items"), "prefer", "tx=rollback, return=minimal")}
    end

    test "defaults to :commit, which drops tx", %{conn: conn} do
      assert {:ok, %Request{prefer: %Prefer{tx: nil, return: :minimal}}} =
               Request.from_conn(conn, [])

      assert {:ok, %Request{prefer: %Prefer{tx: nil}}} = Request.from_conn(conn, tx_end: :commit)
    end

    test ":commit_allow_override keeps tx", %{conn: conn} do
      assert {:ok, %Request{prefer: %Prefer{tx: :rollback}}} =
               Request.from_conn(conn, tx_end: :commit_allow_override)
    end
  end

  describe "body: Plug.Parsers with PgRest.BodyReader" do
    setup do
      %{
        parser:
          Plug.Parsers.init([body_reader: {PgRest.BodyReader, :read_body, []}] ++ @parser_opts)
      }
    end

    test "raw_body equals the sent bytes and body is the decoded JSON", %{parser: parser} do
      payload = ~s([ {"a": 1},  {"a": 2} ])
      conn = :post |> json_conn("/items", payload) |> Plug.Parsers.call(parser)

      assert {:ok, %Request{raw_body: ^payload, body: [%{"a" => 1}, %{"a" => 2}]}} =
               Request.from_conn(conn, [])
    end

    test "an object with a _json key is an object, a scalar is not", %{parser: parser} do
      payload = ~s({"_json": 5})
      conn = :post |> json_conn("/items", payload) |> Plug.Parsers.call(parser)

      assert {:ok, %Request{body: %{"_json" => 5}, raw_body: ^payload}} =
               Request.from_conn(conn, [])

      conn = :post |> json_conn("/items", "5") |> Plug.Parsers.call(parser)
      assert {:ok, %Request{body: [], raw_body: "[]"}} = Request.from_conn(conn, [])
    end

    test "a cached raw body that is invalid JSON is 400 PGRST102 (exercises the cached path directly)" do
      conn =
        :post
        |> json_conn("/items", "{nope")
        |> put_private(:pgrest_raw_body, "{nope")

      assert {:error, %PgRest.Error{status: 400, code: "PGRST102"}} = Request.from_conn(conn, [])
    end

    test "cached raw body over max_body_bytes is 413", %{parser: parser} do
      conn =
        :post
        |> json_conn("/items", ~s({"a":"#{String.duplicate("x", 100)}"}))
        |> Plug.Parsers.call(parser)

      assert {:error,
              %PgRest.Error{
                status: 413,
                code: "54000",
                message: "request body exceeds max_body_bytes"
              }} =
               Request.from_conn(conn, max_body_bytes: 50)
    end
  end

  describe "body: Plug.Parsers without the reader" do
    setup do
      %{parser: Plug.Parsers.init(@parser_opts)}
    end

    test "an array arrives through _json and raw_body is nil", %{parser: parser} do
      conn = :post |> json_conn("/items", ~s([{"a":1}])) |> Plug.Parsers.call(parser)
      assert {:ok, %Request{body: [%{"a" => 1}], raw_body: nil}} = Request.from_conn(conn, [])
    end

    test "a scalar becomes an empty array; GET behind the parser has a nil body", %{
      parser: parser
    } do
      conn = :post |> json_conn("/items", "5") |> Plug.Parsers.call(parser)
      assert {:ok, %Request{body: []}} = Request.from_conn(conn, [])

      conn = :get |> json_conn("/items", ~s({"a":1})) |> Plug.Parsers.call(parser)
      assert {:ok, %Request{body: nil}} = Request.from_conn(conn, [])
    end

    test "an object is used as is", %{parser: parser} do
      conn = :post |> json_conn("/items", ~s({"a":1})) |> Plug.Parsers.call(parser)
      assert {:ok, %Request{body: %{"a" => 1}, raw_body: nil}} = Request.from_conn(conn, [])
    end
  end

  describe "body: no parser" do
    test "raw_body keeps the sent bytes" do
      payload = ~s({"a": 1})
      conn = json_conn(:post, "/items", payload)
      assert {:ok, %Request{raw_body: ^payload, body: %{"a" => 1}}} = Request.from_conn(conn, [])
    end

    test "empty body on GET is nil; empty on POST is PGRST102" do
      assert {:ok, %Request{body: nil, raw_body: nil}} =
               Request.from_conn(conn(:get, "/items"), [])

      assert {:error,
              %PgRest.Error{status: 400, code: "PGRST102", message: "Empty or invalid json"}} =
               Request.from_conn(json_conn(:post, "/items", ""), [])
    end

    test "invalid JSON is 400 PGRST102" do
      assert {:error, %PgRest.Error{status: 400, code: "PGRST102"}} =
               Request.from_conn(json_conn(:post, "/items", "{nope"), [])
    end

    test "scalar JSON becomes an empty array (recorded: PostgREST inserts nothing, 201)" do
      for scalar <- ["5", ~s("str"), "null"] do
        assert {:ok, %Request{body: [], raw_body: "[]"}} =
                 Request.from_conn(json_conn(:post, "/items", scalar), [])
      end
    end

    test "only POST/PUT/PATCH decode the body; others keep raw bytes and a nil body" do
      for method <- [:get, :delete] do
        assert {:ok, %Request{body: nil, raw_body: ~s({"a":1})}} =
                 Request.from_conn(json_conn(method, "/items", ~s({"a":1})), [])

        assert {:ok, %Request{body: nil, raw_body: "{nope"}} =
                 Request.from_conn(json_conn(method, "/items", "{nope"), [])
      end
    end

    test "an unknown tx_end raises ArgumentError" do
      assert_raise ArgumentError, ~r/tx_end/, fn ->
        Request.from_conn(conn(:get, "/items"), tx_end: :rollback)
      end
    end

    test "a body of exactly max_body_bytes is accepted, one more byte is 413" do
      exact = ~s({"a":"#{String.duplicate("x", 20)}"})
      limit = byte_size(exact)

      assert {:ok, %Request{raw_body: ^exact}} =
               Request.from_conn(json_conn(:post, "/items", exact), max_body_bytes: limit)

      assert {:error,
              %PgRest.Error{
                status: 413,
                code: "54000",
                message: "request body exceeds max_body_bytes"
              }} =
               Request.from_conn(json_conn(:post, "/items", exact <> " "), max_body_bytes: limit)
    end

    test "a large body is cut off by the limit, not read in full" do
      body = ~s({"a":"#{String.duplicate("x", 5_000)}"})

      assert {:error, %PgRest.Error{status: 413}} =
               Request.from_conn(json_conn(:post, "/items", body), max_body_bytes: 1_000)
    end
  end
end
