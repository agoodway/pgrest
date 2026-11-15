defmodule PgRest.Grammar.SelectTest do
  use ExUnit.Case, async: true

  alias PgRest.AST.{Aggregate, Embed, Field, SelectField}
  alias PgRest.Error
  alias PgRest.Grammar.Select

  defp parse!(input) do
    assert {:ok, items} = Select.parse(input)
    items
  end

  defp error!(input) do
    assert {:error, %Error{} = error} = Select.parse(input)
    error
  end

  test "commits to a negative JSON index after the arrow" do
    assert %Error{
             code: "PGRST100",
             message:
               "\"failed to parse select parameter (arr_data->>--34)\" (line 1, column 13)",
             details: "unexpected \"-\" expecting digit"
           } = error!("arr_data->>--34")
  end

  describe "fields" do
    test "plain, aliased, cast and JSON-path columns" do
      assert [
               %SelectField{field: %Field{name: "id"}},
               %SelectField{field: %Field{name: "name"}, alias: "alias"},
               %SelectField{field: %Field{name: "price"}, cast: "text"},
               %SelectField{
                 field: %Field{name: "data", json_path: [{:arrow, "a"}, {:double_arrow, "b"}]}
               }
             ] = parse!("id,alias:name,price::text,data->a->>b")
    end

    test "alias, JSON path and cast combine" do
      assert [
               %SelectField{
                 field: %Field{name: "data", json_path: [{:double_arrow, "k"}, {:arrow, 2}]},
                 alias: "x",
                 cast: "int"
               }
             ] = parse!("x:data->>k->2::int")
    end

    test "star, empty input and quoted names" do
      assert [%SelectField{field: :star}] = parse!("*")
      assert [] = parse!("")
      assert [%SelectField{field: %Field{name: "a,b"}}] = parse!(~s("a,b"))
    end

    test "whitespace around tokens is ignored" do
      assert [%SelectField{field: %Field{name: "id"}}, %SelectField{field: %Field{name: "name"}}] =
               parse!(" id , name ")

      assert [%SelectField{field: :star}, %Embed{name: "clients", select: [_, _]}] =
               parse!(" * , clients ( id , name ) ")
    end

    test "empty items and stray parentheses are parse errors" do
      assert %Error{status: 400, code: "PGRST100"} = error!("id,,name")
      assert %Error{status: 400, code: "PGRST100"} = error!("id,")
      assert %Error{status: 400, code: "PGRST100"} = error!("id)")
    end
  end

  describe "casts" do
    test "type names with spaces and $ parse; an array suffix is a 400 as upstream" do
      assert [%SelectField{cast: "timestamp with time zone"}] =
               parse!("id::timestamp with time zone")

      assert %Error{status: 400, code: "PGRST100"} = error!("id::int[]")
      assert [%SelectField{cast: "my_type$1"}] = parse!("id::my_type$1")
    end

    test "whitespace around the cast type is trimmed, single interior spaces are kept" do
      assert [%SelectField{cast: "double precision"}, %SelectField{field: %Field{name: "b"}}] =
               parse!("a:: double precision ,b")
    end

    test "double interior spaces are a 400" do
      assert %Error{status: 400} = error!("a::double  precision")
    end

    for {label, input} <- [
          {"close paren", "id::int)"},
          {"semicolon", "id::int;"},
          {"double quote", ~s(id::"int")},
          {"dash", "id::int--"},
          {"dot", "id::a.b"},
          {"open paren", "id::int("},
          {"slash", "id::int/x"},
          {"star", "id::int*"},
          {"single quote", "id::int'"},
          {"nul", "id::int\x00"},
          {"empty", "id::"},
          {"leading digit", "id::1x"},
          {"too long", "id::" <> String.duplicate("a", 64)},
          {"injection", "id::int) FROM x UNION SELECT 1--"}
        ] do
      test "rejects a cast with #{label}" do
        assert %Error{status: 400, code: "PGRST100"} = error!(unquote(input))
      end
    end

    test "a 63 byte cast is accepted" do
      name = String.duplicate("a", 63)
      assert [%SelectField{cast: ^name}] = parse!("id::" <> name)
    end

    test "a comma ends the cast: `id::int,x` is two columns" do
      assert [%SelectField{cast: "int"}, %SelectField{field: %Field{name: "x"}}] =
               parse!("id::int,x")
    end

    test "casts on aggregates are validated too" do
      assert %Error{code: "PGRST100"} = error!("amount.sum()::int)")
      assert %Error{code: "PGRST100"} = error!("count()::in;t")
    end
  end

  describe "embeds" do
    test "plain embed with star" do
      assert [%SelectField{field: :star}, %Embed{name: "clients", select: [_, _]} = embed] =
               parse!("*,clients(id,name)")

      assert %Embed{alias: nil, hint: nil, join: :left, spread: false} = embed
    end

    test "alias, hint and !inner" do
      assert [
               %Embed{
                 name: "clients",
                 alias: "c",
                 hint: "client_id_fkey",
                 join: :inner,
                 select: [%SelectField{field: :star}]
               }
             ] = parse!("c:clients!client_id_fkey!inner(*)")
    end

    test "hint and join type in either order, !left explicit" do
      assert [%Embed{hint: "h", join: :inner}] = parse!("r!inner!h(*)")
      assert [%Embed{hint: nil, join: :left}] = parse!("projects!left(id)")
      assert [%Embed{hint: "parent"}] = parse!("family_tree!parent(*)")
      assert [%Embed{hint: "a", join: :left}] = parse!("r!a!b(*)")
      assert [%Embed{hint: nil, join: :inner}] = parse!("r!inner!left(*)")
      assert [%Embed{hint: nil, join: :left}] = parse!("r!left!inner(*)")
    end

    test "spreads" do
      assert [%Embed{name: "clients", spread: true, select: [%SelectField{}]}] =
               parse!("...clients(name)")

      assert [%Embed{name: "c", spread: true, hint: "fk", join: :inner}] =
               parse!("...c!fk!inner(*)")
    end

    test "empty embed" do
      assert [%SelectField{}, %Embed{name: "clients", select: []}] = parse!("id,clients()")
    end

    test "nests three levels" do
      assert [
               %Embed{
                 name: "a",
                 select: [
                   %SelectField{},
                   %Embed{
                     name: "b",
                     select: [%Embed{name: "c", select: [%SelectField{field: :star}]}]
                   }
                 ]
               }
             ] = parse!("a(id,b(c(*)))")
    end

    test "aliases the same relation twice" do
      assert [%Embed{alias: "a", hint: "parent"}, %Embed{alias: "b", hint: "child"}] =
               parse!("a:family_tree!parent(*),b:family_tree!child(*)")
    end

    test "unbalanced parentheses fail" do
      assert %Error{code: "PGRST100"} = error!("clients(id")
      assert %Error{code: "PGRST100"} = error!("clients(id))")
    end

    test "an embed opened and never filled expects an item or the closing parenthesis" do
      assert %Error{details: details} = error!("id(")
      assert details =~ ~s|"count()" or ")"|
      assert %Error{details: after_field} = error!("clients(id")
      refute after_field =~ ~s|"count()"|
    end

    test "aggregates may sit inside embeds" do
      assert [%Embed{select: [%Aggregate{fun: :count, field: nil}]}] = parse!("tasks(count())")
    end
  end

  describe "aggregates" do
    test "count() and aliased aggregate with cast" do
      assert [
               %Aggregate{fun: :count, field: nil, alias: nil, cast: nil},
               %Aggregate{
                 fun: :sum,
                 field: %Field{name: "amount"},
                 alias: "total",
                 cast: "int"
               }
             ] = parse!("count(),total:amount.sum()::int")
    end

    test "every function, a JSON-path column, and a field cast before aggregating" do
      for {name, fun} <- [sum: :sum, avg: :avg, min: :min, max: :max, count: :count] do
        assert [%Aggregate{fun: ^fun, field: %Field{name: "v"}}] = parse!("v.#{name}()")
      end

      assert [%Aggregate{fun: :avg, cast: "int"}] = parse!("col.avg()::int")

      assert [%Aggregate{field: %Field{json_path: [{:double_arrow, "n"}]}, input_cast: "numeric"}] =
               parse!("data->>n::numeric.sum()")
    end

    test "an alias, a JSON path, an input cast and a result cast combine" do
      assert [
               %Aggregate{
                 fun: :sum,
                 field: %Field{name: "jsonb_col", json_path: [double_arrow: "key"]},
                 input_cast: "integer",
                 cast: "text",
                 alias: "s"
               }
             ] = parse!("s:jsonb_col->>key::integer.sum()::text")
    end

    test "count() takes an alias and a cast" do
      assert [%Aggregate{fun: :count, alias: "n", cast: "text"}] = parse!("n:count()::text")

      assert [%Aggregate{fun: :count, field: nil, alias: nil, cast: "text", input_cast: nil}] =
               parse!("count()::text")
    end

    test "a bare `count` is a field; the planner decides whether it is the legacy count()" do
      assert [%Embed{name: "projects", select: [%SelectField{field: %Field{name: "count"}}]}] =
               parse!("projects(count)")
    end

    for {label, input} <- [
          {"close paren", "id.sum()::int)"},
          {"semicolon", "id.sum()::int;"},
          {"quote in the input cast", "id::int'.sum()"},
          {"double quote", ~s[id.sum()::"int"]},
          {"dash", "id.sum()::int--"},
          {"64 byte result cast", "id.sum()::" <> String.duplicate("a", 64)},
          {"64 byte input cast", "id::" <> String.duplicate("a", 64) <> ".sum()"}
        ] do
      test "rejects an aggregate cast with #{label}" do
        assert %Error{status: 400, code: "PGRST100"} = error!(unquote(input))
      end
    end

    test "a comma ends an aggregate cast, as upstream: `id.sum()::int,x` is two items" do
      assert [%Aggregate{fun: :sum, cast: "int"}, %SelectField{field: %Field{name: "x"}}] =
               parse!("id.sum()::int,x")
    end

    test "an unknown aggregate function is a parse error" do
      assert %Error{code: "PGRST100"} = error!("v.median()")
      assert %Error{code: "PGRST100"} = error!("v.sum")
    end
  end

  describe "errors" do
    test "message and details follow PostgREST's shape" do
      assert %Error{
               status: 400,
               code: "PGRST100",
               message: ~S|"failed to parse select parameter (id)x)" (line 1, column 3)|,
               details: details
             } = error!("id)x")

      assert details =~ ~S|unexpected ")" expecting|
    end

    test "NUL anywhere is rejected" do
      assert %Error{code: "PGRST100", message: "Invalid identifier"} = error!("a\x00b")
      assert %Error{code: "PGRST100", message: "Invalid identifier"} = error!("x\x00:id")
    end
  end
end
