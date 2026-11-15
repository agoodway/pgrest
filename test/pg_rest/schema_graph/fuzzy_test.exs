defmodule PgRest.SchemaGraph.FuzzyTest do
  use ExUnit.Case, async: true

  alias PgRest.SchemaGraph.Fuzzy

  # The cases of PostgREST's noRelBetweenHint doctests (Error.hs).
  describe "closest/2" do
    test "suggests a parent for a near miss" do
      assert Fuzzy.closest(["films"], "film") == "films"
    end

    test "suggests a child for a near miss" do
      assert Fuzzy.closest(["directors", "roles", "actors"], "role") == "roles"
    end

    test "has no suggestion when nothing is close" do
      assert Fuzzy.closest(["roles"], "noclosealternative") == nil
      assert Fuzzy.closest(["directors", "roles", "actors"], "noclosealternative") == nil
    end

    test "an exact match scores 1.0, which callers treat as no suggestion" do
      assert [{score, "actors"} | _] = Fuzzy.get(["directors", "roles", "actors"], "actors")
      assert score == 1.0
    end

    test "ties are broken alphabetically" do
      assert Fuzzy.closest(["users", "files"], "items") == "files"
    end
  end

  # PostgREST's RPC hints (Error.hs): functions at 0.75, parameter lists at 0.33.
  describe "closest/3" do
    test "suggests the best candidate above the minimum score" do
      assert Fuzzy.closest(["sayhello", "add_them"], "sayhell", 0.75) == "sayhello"
      assert Fuzzy.closest(["projects"], "projectx", 0.75) == "projects"
    end

    test "has no suggestion below the minimum score" do
      assert Fuzzy.closest(["projects"], "projxxxx", 0.75) == nil
    end

    test "a lower minimum score admits looser parameter lists" do
      assert Fuzzy.closest(["(a, b)"], "(a)", 0.33) == "(a, b)"
      assert Fuzzy.closest(["(a, b)"], "(c)", 0.33) == nil
    end

    test "rescoring is the unpadded ratio of the lowercased originals" do
      # 0.667 upstream (0.75 only with padding counted), so no PGRST205 hint
      assert Fuzzy.closest(["actors"], "aktorz", 0.75) == nil
      assert [{score, "roles"}] = Fuzzy.get(["roles"], "rol", 0.0)
      assert_in_delta score, 0.6, 1.0e-9
    end

    test "a URL-sized term against many candidates skips the hopeless rescoring" do
      candidates = for i <- 1..499, do: "table_name_number_#{i}"
      term = String.duplicate("table_name_", 1_500)

      {micros, result} = :timer.tc(fn -> Fuzzy.closest(candidates, term, 0.75) end)

      assert result == nil
      assert micros < 300_000
    end

    test "the length bound never drops a candidate that could pass" do
      assert Fuzzy.closest(["projects", "p"], "projectx", 0.75) == "projects"
      assert Fuzzy.closest(["projects"], "pro", 0.33) == "projects"
    end

    test "a request-sized term is matched in linear time" do
      term = String.duplicate("abcdefghij, ", 5_000)

      {micros, _} = :timer.tc(fn -> Fuzzy.get(["abcdefghij"], term, 0.33) end)

      assert micros < 500_000
    end

    test "get/3 applies the minimum score" do
      assert [{score, "projects"}] = Fuzzy.get(["projects"], "projectx", 0.75)
      assert score >= 0.75
      assert Fuzzy.get(["projects"], "projxxxx", 0.75) == []
    end
  end
end
