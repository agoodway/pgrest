defmodule PgRest.BodyReaderTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PgRest.BodyReader

  test "caches the raw body in conn.private while returning it" do
    conn = conn(:post, "/items", ~s({"a":1}))
    assert {:ok, ~s({"a":1}), conn} = BodyReader.read_body(conn, [])
    assert conn.private[:pgrest_raw_body] == ~s({"a":1})
  end

  test "accumulates chunks across {:more, ...} reads" do
    conn = conn(:post, "/items", "abcdefghij")

    assert {:more, "abcd", conn} = BodyReader.read_body(conn, length: 4, read_length: 4)
    assert conn.private[:pgrest_raw_body] == "abcd"
    assert {:more, "efgh", conn} = BodyReader.read_body(conn, length: 4, read_length: 4)
    assert conn.private[:pgrest_raw_body] == "abcdefgh"
    assert {:ok, "ij", conn} = BodyReader.read_body(conn, length: 4, read_length: 4)
    assert conn.private[:pgrest_raw_body] == "abcdefghij"
  end

  test "works as the body_reader of Plug.Parsers" do
    opts =
      Plug.Parsers.init(
        parsers: [:json],
        pass: ["*/*"],
        json_decoder: Jason,
        body_reader: {BodyReader, :read_body, []}
      )

    conn =
      :post
      |> conn("/items", ~s([{"a": 1}]))
      |> put_req_header("content-type", "application/json")
      |> Plug.Parsers.call(opts)

    assert conn.body_params == %{"_json" => [%{"a" => 1}]}
    assert conn.private[:pgrest_raw_body] == ~s([{"a": 1}])
  end
end
