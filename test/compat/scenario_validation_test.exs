defmodule PgRest.Compat.ScenarioValidationTest do
  use ExUnit.Case, async: true

  alias PgRest.Compat.Scenario

  @area "area"

  defp build!(scenarios), do: Scenario.build!(scenarios, @area)

  defp valid(overrides \\ %{}), do: Map.merge(%{id: "area/one"}, overrides)

  defp assert_invalid(scenarios, message) do
    assert_raise ArgumentError, message, fn -> build!(scenarios) end
  end

  test "a minimal scenario gets its defaults" do
    assert [%{id: "area/one", method: "GET", only: :both, stateful: false}] = build!([valid()])
  end

  test "rejects a scenario without an id" do
    assert_invalid([%{path: "/"}], ~r/has no :id/)
  end

  test "rejects an id outside the area" do
    assert_invalid([valid(%{id: "other/one"})], ~r|must start with "area/"|)
  end

  test "rejects duplicate ids" do
    assert_invalid([valid(), valid()], ~r/duplicate scenario ids/)
  end

  test "rejects unknown keys" do
    assert_invalid([valid(%{bogus: 1})], ~r/unknown scenario keys \[:bogus\]/)
  end

  test "rejects an unknown method" do
    assert_invalid([valid(%{method: "BREW"})], ~r/unknown method "BREW"/)
  end

  describe "mutations" do
    test "need stateful: true" do
      assert_invalid([valid(%{method: "POST"})], ~r/must set `stateful: true`/)
    end

    test "need Prefer: tx=rollback" do
      assert_invalid(
        [valid(%{method: "POST", stateful: true})],
        ~r/must send `Prefer: tx=rollback`/
      )
    end

    test "a stateless POST /rpc is accepted and always gets Prefer: tx=rollback" do
      assert [%{stateful: false, headers: [{"prefer", "tx=rollback"}]}] =
               build!([valid(%{method: "POST", path: "/rpc/f"})])

      scenario = valid(%{method: "POST", path: "/rpc/f", headers: [{"Prefer", "tx=rollback"}]})
      assert [%{headers: [{"Prefer", "tx=rollback"}]}] = build!([scenario])
    end

    test "a stateful RPC can explicitly exercise commit" do
      scenario =
        valid(%{
          method: "POST",
          path: "/rpc/f",
          stateful: true,
          headers: [{"Prefer", "tx=commit"}]
        })

      assert [%{stateful: true, headers: [{"Prefer", "tx=commit"}]}] = build!([scenario])
    end

    test "a stateless POST outside /rpc is still rejected" do
      assert_invalid([valid(%{method: "POST", path: "/items"})], ~r/must set `stateful: true`/)
    end

    test "are accepted with both" do
      scenario =
        valid(%{method: "POST", stateful: true, headers: [{"Prefer", "tx=rollback"}]})

      assert [%{stateful: true}] = build!([scenario])
    end
  end

  describe "only: :pgrest" do
    test "needs expect" do
      assert_invalid([valid(%{only: :pgrest})], ~r/needs `expect:`/)
    end

    test ":both forbids expect" do
      assert_invalid([valid(%{expect: %{status: 200}})], ~r/needs `expect:`/)
    end

    test "rejects non-string expect header keys" do
      scenario = valid(%{only: :pgrest, expect: %{status: 200, headers: %{content_type: "x"}}})
      assert_invalid([scenario], ~r/expect headers must be a map with string keys/)
    end

    test "rejects a term body without a JSON content-type" do
      for headers <- [%{}, %{"content-type" => "text/plain"}] do
        scenario = valid(%{only: :pgrest, expect: %{status: 200, headers: headers, body: []}})
        assert_invalid([scenario], ~r/term body in expect needs a JSON content-type/)
      end
    end

    test "accepts a term body with a JSON content-type in any header case" do
      scenario =
        valid(%{
          only: :pgrest,
          expect: %{status: 200, headers: %{"Content-Type" => "application/json"}, body: []}
        })

      assert [%{only: :pgrest}] = build!([scenario])
    end

    test "a non-string content-type value is rejected, not a crash" do
      scenario =
        valid(%{
          only: :pgrest,
          expect: %{status: 200, headers: %{"content-type" => 1}, body: []}
        })

      assert_invalid([scenario], ~r/term body in expect needs a JSON content-type/)
    end

    test "expected_response downcases expect header keys" do
      expect = %{status: 200, headers: %{"Content-Type" => "application/json"}, body: [1]}
      [scenario] = build!([valid(%{only: :pgrest, expect: expect})])

      assert %{headers: %{"content-type" => "application/json"}, body: "[1]"} =
               Scenario.expected_response(scenario, %{})
    end

    test "accepts a binary or empty body without a content-type" do
      for body <- [nil, "text"] do
        scenario = valid(%{only: :pgrest, expect: %{status: 204, body: body}})
        assert [%{only: :pgrest}] = build!([scenario])
      end
    end
  end

  describe "fixture and compare" do
    test "default to :test and :exact" do
      assert [%{fixture: :test, compare: :exact}] = build!([valid()])
    end

    test "accept every fixture and compare mode" do
      for fixture <- [:test, :supabase, :supabase_scope], compare <- [:exact, :plan] do
        assert [%{fixture: ^fixture, compare: ^compare}] =
                 build!([valid(%{fixture: fixture, compare: compare})])
      end
    end

    test "reject unknown values" do
      assert_invalid([valid(%{fixture: :other})], ~r/unknown fixture :other/)
      assert_invalid([valid(%{compare: :fuzzy})], ~r/unknown compare mode :fuzzy/)
    end

    test "server: :limits is only valid with the test fixture" do
      assert [%{server: :limits}] = build!([valid(%{server: :limits})])

      assert_invalid(
        [valid(%{server: :limits, fixture: :supabase})],
        ~r/`server: :limits` needs `fixture: :test`/
      )
    end
  end
end
