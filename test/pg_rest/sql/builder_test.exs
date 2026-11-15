defmodule PgRest.SQL.BuilderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ecto.Adapters.SQL
  alias PgRest.Compat.Repo
  alias PgRest.Grammar.Common
  alias PgRest.SQL.Builder

  defp sql(iodata), do: IO.iodata_to_binary(iodata)

  describe "param/4" do
    test "text mode binds as text and casts in SQL" do
      b = Builder.new()
      {p1, b} = Builder.param(b, "5", nil, :text)
      {p2, b} = Builder.param(b, "5", "integer", :text)
      {p3, b} = Builder.param(b, ["1", "2"], "integer", :text)
      {p4, b} = Builder.param(b, ["a"], nil, :text)

      assert [sql(p1), sql(p2), sql(p3), sql(p4)] ==
               ["$1::text", "$2::text::integer", "$3::text[]::integer[]", "$4::text[]"]

      assert {_, [_, _, ["1", "2"], ["a"]]} = Builder.to_sql(b, "")
    end

    test "native mode emits $n, or $n::type when typed" do
      b = Builder.new()
      {p1, b} = Builder.param(b, 5, nil, :native)
      {p2, b} = Builder.param(b, 5, "bigint", :native)
      assert [sql(p1), sql(p2)] == ["$1", "$2::bigint"]
      assert {"x", [5, 5]} = Builder.to_sql(b, "x")
    end

    test "a text value executes as $1::text::integer; a bad one is a 22P02" do
      {ph, b} = Builder.param(Builder.new(), "5", "integer", :text)
      {query, params} = Builder.to_sql(b, ["SELECT ", ph])
      assert %{rows: [[5]]} = SQL.query!(Repo, query, params)

      {ph, b} = Builder.param(Builder.new(), "abc", "integer", :text)
      {query, params} = Builder.to_sql(b, ["SELECT ", ph])

      assert_raise Postgrex.Error, fn -> SQL.query!(Repo, query, params) end

      assert {:error, %Postgrex.Error{postgres: %{pg_code: "22P02"}}} =
               SQL.query(Repo, query, params)
    end

    test "append_params keeps later numbering consistent" do
      b = Builder.append_params(Builder.new(), [1, 2])
      {ph, b} = Builder.param(b, 3, nil, :native)
      assert sql(ph) == "$3"
      assert {_, [1, 2, 3]} = Builder.to_sql(b, "")
    end
  end

  describe "ident/1 and qualified/2" do
    test "quotes and escapes" do
      assert sql(Builder.ident("a\"b")) == ~s("a""b")
      assert sql(Builder.qualified("public", "my table")) == ~s("public"."my table")
    end

    test "raises on a NUL byte" do
      assert_raise ArgumentError, ~r/NUL/, fn -> Builder.ident("a\0b") end
    end
  end

  describe "cast/2" do
    test "emits CAST(expr AS type)" do
      assert sql(Builder.cast("x", "int")) == "CAST(x AS int)"
      assert sql(Builder.cast("x", "character varying")) == "CAST(x AS character varying)"
    end

    test "rejects anything that is not a type name" do
      for bad <- ["int) --", "int;", "a.b", String.duplicate("a", 64), "", "int[]", "1a"] do
        assert_raise ArgumentError, fn -> Builder.cast("x", bad) end
      end
    end

    property "accepts exactly the strings the shared cast rule accepts" do
      chars = [?a..?z, ?A..?Z, ?0..?9, [?_, ?\s, ?$, ?(, ?), ?;, ?., ?[, ?]]] |> Enum.concat()

      check all(name <- string(chars, max_length: 70)) do
        if Common.cast_name?(name) do
          assert sql(Builder.cast("x", name)) == "CAST(x AS #{name})"
        else
          assert_raise ArgumentError, fn -> Builder.cast("x", name) end
        end
      end
    end
  end
end
