defmodule PgRest.Grammar.OrderTest do
  use ExUnit.Case, async: true

  alias PgRest.AST.{Field, OrderTerm}
  alias PgRest.Error
  alias PgRest.Grammar.Order

  defp parse!(input) do
    assert {:ok, terms} = Order.parse(input)
    terms
  end

  defp error!(input) do
    assert {:error, %Error{status: 400, code: "PGRST100"} = error} = Order.parse(input)
    error
  end

  test "direction and nulls placement" do
    assert [%OrderTerm{field: %Field{name: "a"}, dir: :desc, nulls: :last}] =
             parse!("a.desc.nullslast")

    assert [%OrderTerm{dir: :asc, nulls: :first}] = parse!("a.asc.nullsfirst")
    assert [%OrderTerm{dir: :asc, nulls: nil}] = parse!("a")
    assert [%OrderTerm{dir: :desc, nulls: nil}] = parse!("a.desc")
    assert [%OrderTerm{dir: :asc, nulls: :first}] = parse!("a.nullsfirst")
  end

  test "JSON paths and several terms" do
    assert [
             %OrderTerm{field: %Field{name: "a"}, dir: :desc, nulls: :last},
             %OrderTerm{field: %Field{name: "data", json_path: [{:double_arrow, "x"}]}},
             %OrderTerm{field: %Field{name: "name"}, relation: "clients", dir: :asc}
           ] = parse!("a.desc.nullslast,data->>x,clients(name).asc")
  end

  test "relation terms" do
    assert [
             %OrderTerm{
               relation: "clients",
               field: %Field{name: "name"},
               dir: :desc,
               nulls: :first
             }
           ] = parse!("clients(name).desc.nullsfirst")

    assert [%OrderTerm{relation: "clients", field: %Field{name: "j", json_path: [{:arrow, "k"}]}}] =
             parse!("clients(j->k)")

    assert [%OrderTerm{relation: nil}, %OrderTerm{relation: "clients"}, %OrderTerm{relation: nil}] =
             parse!("name,clients(name),id")
  end

  test "whitespace around tokens is ignored" do
    assert [
             %OrderTerm{field: %Field{name: "a"}, dir: :desc},
             %OrderTerm{field: %Field{name: "b"}}
           ] =
             parse!(" a .desc , b ")
  end

  test "quoted field names" do
    assert [%OrderTerm{field: %Field{name: "a.b"}, dir: :desc}] = parse!(~S|"a.b".desc|)
  end

  describe "errors" do
    test "positions and expectations follow PostgREST" do
      assert %Error{
               message: ~S|"failed to parse order (id.nulsfist)" (line 1, column 4)|,
               details: ~S|unexpected "n" expecting "asc", "desc", "nullsfirst" or "nullslast"|
             } = error!("id.nulsfist")

      assert %Error{
               message: ~S|"failed to parse order (id.asc.desc)" (line 1, column 8)|,
               details: ~S|unexpected "d" expecting "nullsfirst" or "nullslast"|
             } = error!("id.asc.desc")

      assert %Error{message: ~S|"failed to parse order (id,)" (line 1, column 4)|} = error!("id,")
    end

    test "malformed terms are rejected" do
      for input <- ["", "id,,id", "id.descc", "id.nullslasttt", "clients(name,id)", "a.b.c(", ","] do
        error!(input)
      end
    end

    test "NUL is rejected" do
      assert %Error{message: "Invalid identifier"} = error!("a\x00b")
    end
  end
end
