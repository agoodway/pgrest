defmodule PgRest.WriteNamesTest do
  use ExUnit.Case, async: true

  alias PgRest.Write

  test "client bulk columns are quoted identifiers" do
    assert {:ok, ["username", "status"]} =
             Write.columns([{"columns", ~s("username","status")}])
  end

  test "quoted identifiers retain commas and decode backslash escapes" do
    assert {:ok, ["a,b", ~s(a"b)]} =
             Write.columns([{"columns", ~s("a,b","a\\"b")}])
  end

  test "on_conflict uses the same identifier grammar" do
    assert {:ok, ["username"]} = Write.on_conflict([{"on_conflict", ~s("username")}])
  end
end
