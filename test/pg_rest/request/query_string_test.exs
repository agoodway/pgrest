defmodule PgRest.Request.QueryStringTest do
  use ExUnit.Case, async: true

  alias PgRest.Request.QueryString

  test "preserves order and duplicate keys, decoding + as a space" do
    assert {:ok, [{"price", "gt.1"}, {"price", "lt.5"}, {"name", "eq.a b"}]} =
             QueryString.parse("price=gt.1&price=lt.5&name=eq.a+b")
  end

  test "decodes percent-encoding on both sides" do
    assert {:ok, [{"name", ~s|in.(1,"x,y")|}]} =
             QueryString.parse("name=in.%281%2C%22x%2Cy%22%29")

    assert {:ok, [{"a b", "c"}]} = QueryString.parse("a%20b=c")
  end

  test "a key without = has a nil value, distinct from an empty value" do
    assert {:ok, [{"id", nil}]} = QueryString.parse("id")
    assert {:ok, [{"id", ""}]} = QueryString.parse("id=")
  end

  test "splits on semicolons like ampersands (recorded)" do
    assert {:ok, [{"id", "eq.1"}, {"limit", "0"}]} = QueryString.parse("id=eq.1;limit=0")
  end

  test "decodes UTF-8 percent-encoding" do
    assert {:ok, [{"name", "eq.été"}]} = QueryString.parse("name=eq.%C3%A9t%C3%A9")
  end

  test "splits on the first equals sign only" do
    assert {:ok, [{"a", "b=c"}]} = QueryString.parse("a=b=c")
  end

  test "a key without a value gets an empty value; empty segments are skipped" do
    assert {:ok, [{"a", nil}, {"b", "1"}]} = QueryString.parse("a&&b=1&")
    assert {:ok, []} = QueryString.parse("")
  end

  test "malformed percent-encoding is a 400, never a raise" do
    for bad <- ["id=eq.%zz", "id=eq.%", "id=eq.%4", "%zz=1", "id=%E0%A4%A", "id=%FF"] do
      assert {:error, %PgRest.Error{status: 400, code: "PGRST100"}} = QueryString.parse(bad)
    end
  end
end
