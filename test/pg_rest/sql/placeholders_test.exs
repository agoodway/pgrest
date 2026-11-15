defmodule PgRest.SQL.PlaceholdersTest do
  use ExUnit.Case, async: true

  alias PgRest.SQL.Placeholders

  @untouched [
    {"'$1'", "string"},
    {"'it''s $1'", "doubled quote"},
    {"E'\\'$1'", "E string"},
    {"$$ $1 $$", "dollar quote"},
    {"$q$ $1 $q$", "tagged dollar quote"},
    {"/* $1 */", "block comment"},
    {"/* a /* $1 */ $1 */", "nested comment"},
    {~s("col$1"), "quoted identifier"},
    {~s("a""$1"), "quoted identifier with doubled quote"},
    {"col$1", "identifier with $"}
  ]

  describe "renumber/3" do
    for {token, name} <- @untouched do
      test "leaves a placeholder inside a #{name} alone and shifts the real ones" do
        token = unquote(token)
        sql = "SELECT #{token}, $1, $2 FROM t WHERE x = $1"
        assert Placeholders.renumber(sql, 3, 2) == "SELECT #{token}, $4, $5 FROM t WHERE x = $4"
      end
    end

    test "a line comment hides placeholders until the newline" do
      assert Placeholders.renumber("SELECT $1 -- $1\n, $2", 1, 2) == "SELECT $2 -- $1\n, $3"
      assert Placeholders.renumber("SELECT $1 -- $9", 1, 1) == "SELECT $2 -- $9"
    end

    test "shifts adjacent to punctuation and casts" do
      assert Placeholders.renumber("($1::text,$2)", 10, 2) == "($11::text,$12)"
    end

    test "offset zero is the identity" do
      assert Placeholders.renumber("a = $1 AND b = $2", 0, 2) == "a = $1 AND b = $2"
      assert Placeholders.renumber("SELECT 1", 4, 0) == "SELECT 1"
    end

    test "raises when a placeholder is missing" do
      assert_raise ArgumentError, ~r/\$1\.\.\$3/, fn ->
        Placeholders.renumber("a = $1 AND b = $3", 0, 3)
      end
    end

    test "raises when placeholders are fewer than the parameter count" do
      assert_raise ArgumentError, fn -> Placeholders.renumber("a = $1", 0, 2) end
    end

    test "raises when placeholders exceed the parameter count" do
      assert_raise ArgumentError, fn -> Placeholders.renumber("a = $1 AND b = $2", 0, 1) end
    end

    test "raises on an unclassifiable $ and on unterminated tokens" do
      assert_raise ArgumentError, ~r/classify/, fn ->
        Placeholders.renumber("SELECT $ x", 0, 0)
      end

      assert_raise ArgumentError, fn -> Placeholders.renumber("SELECT 'abc $1", 0, 1) end
      assert_raise ArgumentError, fn -> Placeholders.renumber("SELECT $a$ $1", 0, 0) end
      assert_raise ArgumentError, fn -> Placeholders.renumber("SELECT /* $1", 0, 0) end
    end
  end
end
