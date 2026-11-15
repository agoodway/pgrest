defmodule PgRest.Compat.CompareTest do
  use ExUnit.Case, async: true

  alias PgRest.Compat.Compare

  @json {"content-type", "application/json; charset=utf-8"}

  defp resp(body, headers \\ [], status \\ 200) do
    %{status: status, headers: Map.new([@json | headers]), body: body}
  end

  defp diff(expected, actual, sort \\ false), do: Compare.diff(expected, actual, sort: sort)

  test "identical responses match" do
    assert diff(resp(~s([{"a":1}])), resp(~s([{"a":1}]))) == :ok
  end

  test "transport headers are ignored" do
    assert diff(resp("[]", [{"server", "a"}, {"date", "x"}]), resp("[]", [{"server", "b"}])) ==
             :ok
  end

  test "a differing content-range is an error" do
    assert {:error, msg} =
             diff(
               resp("[]", [{"content-range", "0-1/*"}]),
               resp("[]", [{"content-range", "0-2/*"}])
             )

    assert msg =~ "content-range"
  end

  test "a header missing on one side is an error" do
    assert {:error, _} = diff(resp("[]", [{"location", "/x"}]), resp("[]"))
  end

  test "content-type charset is ignored" do
    a = %{
      status: 200,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: "[]"
    }

    b = %{status: 200, headers: %{"content-type" => "application/json"}, body: "[]"}
    assert diff(a, b) == :ok
  end

  test "a different status is an error" do
    assert {:error, msg} = diff(resp("[]"), resp("[]", [], 201))
    assert msg =~ "status"
  end

  test "JSON bodies compare structurally, ignoring whitespace and key order" do
    assert diff(resp(~s({"a":1,"b":[1,2]})), resp(~s({ "b": [1, 2], "a": 1 }))) == :ok
  end

  test "sort: true ignores top-level array order, sort: false does not" do
    a = resp(~s([{"id":1},{"id":2}]))
    b = resp(~s([{"id":2},{"id":1}]))

    assert diff(a, b, true) == :ok
    assert {:error, _} = diff(a, b, false)
  end

  test "sort: true still detects different elements" do
    assert {:error, _} = diff(resp(~s([{"id":1}])), resp(~s([{"id":2}])), true)
  end

  test "CSV bodies compare as raw text" do
    csv = fn body ->
      %{status: 200, headers: %{"content-type" => "text/csv; charset=utf-8"}, body: body}
    end

    assert diff(csv.(~s(id,name\n1,"a"\n)), csv.(~s(id,name\n1,"a"\n))) == :ok
    assert {:error, _} = diff(csv.(~s(id,name\n1,"a"\n)), csv.(~s(id,name\n1,"a\n)))
  end

  test "an empty body equals only another empty body" do
    assert diff(resp(""), resp("")) == :ok
    assert {:error, _} = diff(resp(""), resp("[]"))
    assert {:error, _} = diff(resp("[]"), resp(""))
  end

  test "an invalid JSON body under a JSON content type is an error" do
    assert {:error, msg} = diff(resp("[]"), resp("not json"))
    assert msg =~ "JSON"
  end

  describe "headers: option" do
    test "a named custom header is compared" do
      a = resp("[]", [{"x-test", "a"}])
      b = resp("[]", [{"x-test", "b"}])

      assert {:error, msg} = Compare.diff(a, b, headers: ["x-test"])
      assert msg =~ "x-test"
    end

    test "an unnamed custom header is transport and ignored" do
      assert Compare.diff(resp("[]", [{"x-test", "a"}]), resp("[]", [{"x-test", "b"}]), []) ==
               :ok
    end

    test "a multi-valued header compares as an ordered list" do
      a = resp("[]", [{"set-cookie", ["a=1", "b=2"]}])

      assert Compare.diff(a, a, headers: ["set-cookie"]) == :ok

      assert {:error, _} =
               Compare.diff(a, resp("[]", [{"set-cookie", ["b=2", "a=1"]}]),
                 headers: ["set-cookie"]
               )
    end

    test "two headers are not one merged header" do
      two = resp("[]", [{"set-cookie", ["a=1", "b=2"]}])
      merged = resp("[]", [{"set-cookie", "a=1, b=2"}])

      assert {:error, msg} = Compare.diff(two, merged, headers: ["set-cookie"])
      assert msg =~ "set-cookie"
    end
  end

  describe "compare: :plan" do
    @plan_type ~s(application/vnd.pgrst.plan+json; for="application/json"; options="")
    @text_type ~s(application/vnd.pgrst.plan+text; for="application/json"; options="")

    defp plan(body, type \\ @plan_type, status \\ 200),
      do: %{status: status, headers: %{"content-type" => type}, body: body}

    defp plan_diff(expected, actual), do: Compare.diff(expected, actual, compare: :plan)

    test "accepts two different JSON plans with equal status and content type" do
      a = plan(~s([{"Plan":{"Node Type":"Seq Scan","Total Cost":1.0}}]))
      b = plan(~s([{"Plan":{"Node Type":"Index Scan","Total Cost":9.5},"Planning Time":0.1}]))

      assert plan_diff(a, b) == :ok
      assert {:error, _} = Compare.diff(a, b, [])
    end

    test "rejects an empty plan array and a non-plan element" do
      good = plan(~s([{"Plan":{}}]))

      assert {:error, msg} = plan_diff(good, plan("[]"))
      assert msg =~ "plan"
      assert {:error, _} = plan_diff(good, plan(~s([{"Other":{}}])))
      assert {:error, _} = plan_diff(good, plan(~s([{"Plan":{}},{"Plan":{}}])))
      assert {:error, _} = plan_diff(good, plan(~s({"Plan":{}})))
    end

    test "still compares status and content type" do
      good = plan(~s([{"Plan":{}}]))

      assert {:error, msg} = plan_diff(good, plan(~s([{"Plan":{}}]), @plan_type, 206))
      assert msg =~ "status"

      assert {:error, msg} = plan_diff(good, plan(~s([{"Plan":{}}]), "application/json"))
      assert msg =~ "content-type"
    end

    test "accepts a text plan whose first line carries a cost" do
      text = "Aggregate  (cost=1.00..2.00 rows=1 width=32)\n  ->  Seq Scan on items\n"
      other = "Seq Scan on items  (cost=0.00..1.05 rows=5 width=8)\n"

      assert plan_diff(plan(text, @text_type), plan(other, @text_type)) == :ok
    end

    test "rejects an empty text plan and one without a cost on the first line" do
      text = plan("Aggregate  (cost=1.00..2.00 rows=1 width=32)\n", @text_type)

      assert {:error, _} = plan_diff(text, plan("", @text_type))
      assert {:error, _} = plan_diff(text, plan("not a plan\n(cost=1)\n", @text_type))
      assert {:error, _} = plan_diff(text, plan(" indented (cost=1)\n", @text_type))
    end

    test "an error response is compared exactly" do
      err = fn code -> plan(~s({"code":"#{code}"}), "application/json; charset=utf-8", 400) end

      assert plan_diff(err.("PGRST100"), err.("PGRST100")) == :ok
      assert {:error, _} = plan_diff(err.("PGRST100"), err.("PGRST200"))
    end
  end
end
