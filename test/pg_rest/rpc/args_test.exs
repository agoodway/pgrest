defmodule PgRest.RPC.ArgsTest do
  use ExUnit.Case, async: true

  alias PgRest.Request
  alias PgRest.RPC.Args

  defp request(params, body \\ nil), do: %Request{params: params, body: body}

  describe "split/2 for a read" do
    test "a parameter without a value is dropped" do
      assert Args.split(request([{"a", nil}, {"b", "1"}, {"id", nil}]), :read) == {["b"], []}
      assert Args.split(request([{"id", nil}], %{"x" => 1}), :post) == {["x"], []}
    end

    test "separates arguments from filters and reserved keys" do
      req = request([{"a", "1"}, {"b", "2"}, {"id", "gt.1"}, {"select", "id"}])

      assert Args.split(req, :read) == {["a", "b"], [{"id", "gt.1"}, {"select", "id"}]}
    end

    test "a value that parses as an operator filter is a filter, not an argument" do
      assert Args.split(request([{"name", "eq.x"}]), :read) == {[], [{"name", "eq.x"}]}
    end

    test "reserved keys and keys ending in a reserved word are always filters" do
      params = [
        {"columns", "a"},
        {"on_conflict", "id"},
        {"order", "id"},
        {"limit", "1"},
        {"offset", "1"},
        {"and", "(a.eq.1)"},
        {"or", "(a.eq.1)"},
        {"rel.order", "id"},
        {"rel.limit", "1"},
        {"rel.offset", "1"},
        {"not.and", "(a.eq.1)"}
      ]

      assert Args.split(request(params), :read) == {[], params}
    end

    test "arguments are deduplicated in request order" do
      req = request([{"b", "1"}, {"a", "2"}, {"b", "3"}])

      assert Args.split(req, :read) == {["b", "a"], []}
    end
  end

  describe "split/2 for a post" do
    test "the argument keys are the body's keys; every query parameter is a filter" do
      req = request([{"id", "gt.1"}, {"a", "1"}], %{"x" => 1, "y" => 2})

      assert Args.split(req, :post) == {["x", "y"], [{"id", "gt.1"}, {"a", "1"}]}
    end

    test "an empty body has no arguments" do
      assert Args.split(request([], nil), :post) == {[], []}
      assert Args.split(request([], []), :post) == {[], []}
      assert Args.split(request([], %{}), :post) == {[], []}
    end

    test "an array body takes the keys of its first object" do
      assert Args.split(request([], [%{"a" => 1, "b" => 2}, %{"a" => 3}]), :post) ==
               {["a", "b"], []}
    end
  end
end
