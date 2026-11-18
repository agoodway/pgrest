defmodule PgRest.Grammar.FilterTest do
  use ExUnit.Case, async: true

  alias PgRest.AST.{Condition, Field, Logic}
  alias PgRest.Error
  alias PgRest.Grammar.{Common, Filter}

  defp cond!(field, value) do
    assert {:ok, %Condition{} = condition} = Filter.parse_condition(field, value)
    condition
  end

  defp field(name, json_path \\ []), do: %Field{name: name, json_path: json_path}

  describe "parse_condition/2 operators" do
    @operators [
      {"eq.5", :eq, "5"},
      {"neq.5", :neq, "5"},
      {"gt.5", :gt, "5"},
      {"gte.5", :gte, "5"},
      {"lt.5", :lt, "5"},
      {"lte.5", :lte, "5"},
      {"like.*a*", :like, "*a*"},
      {"ilike.*a*", :ilike, "*a*"},
      {"match.^a", :match, "^a"},
      {"imatch.^a", :imatch, "^a"},
      {"isdistinct.5", :isdistinct, "5"},
      {"fts.cat", :fts, "cat"},
      {"plfts.cat", :plfts, "cat"},
      {"phfts.cat", :phfts, "cat"},
      {"wfts.cat", :wfts, "cat"},
      {"cs.{1,2}", :cs, "{1,2}"},
      {"cd.{1,2}", :cd, "{1,2}"},
      {"ov.[1,5)", :ov, "[1,5)"},
      {"sl.(1,10)", :sl, "(1,10)"},
      {"sr.(1,10)", :sr, "(1,10)"},
      {"nxr.(1,10)", :nxr, "(1,10)"},
      {"nxl.(1,10)", :nxl, "(1,10)"},
      {"adj.(1,10)", :adj, "(1,10)"}
    ]

    for {value, op, expected} <- @operators do
      test "parses #{value}" do
        assert %Condition{
                 field: %Field{name: "col", json_path: []},
                 op: unquote(op),
                 negate: false,
                 modifier: nil,
                 value: unquote(expected),
                 fts_config: nil
               } = cond!("col", unquote(value))
      end
    end

    test "top-level values are raw, including quotes and dots" do
      assert %Condition{value: "\"a b\".c"} = cond!("id", ~s(eq."a b".c))
    end

    test "not. negates" do
      assert %Condition{op: :eq, negate: true, value: "5"} = cond!("id", "not.eq.5")
    end

    test "any/all modifiers parse the array literal" do
      assert %Condition{op: :like, modifier: :any, value: ["a*", "b*"]} =
               cond!("name", "like(any).{a*,b*}")

      assert %Condition{op: :eq, modifier: :all, negate: true, value: ["1"]} =
               cond!("n", "not.eq(all).{1}")

      assert %Condition{modifier: :any, value: ["a,b", "c"]} =
               cond!("n", ~s[ilike(any).{"a,b",c}])
    end

    test "any/all on a non-array value keeps the raw literal" do
      assert %Condition{modifier: :any, value: "abc"} = cond!("n", "eq(any).abc")
    end

    test "modifiers are rejected on operators that do not take them" do
      assert {:error, %Error{code: "PGRST100"}} = Filter.parse_condition("n", "neq(any).{1}")
      assert {:error, %Error{code: "PGRST100"}} = Filter.parse_condition("n", "in(any).(1)")
    end

    test "in lists" do
      assert %Condition{op: :in, value: ["1", "x,y", "z"]} = cond!("id", ~s[in.(1,"x,y",z)])
      assert %Condition{value: ["a\"b"]} = cond!("id", ~S[in.("a\"b")])
      assert %Condition{value: ["a\\b"]} = cond!("id", ~S[in.("a\\b")])
      assert %Condition{value: [""]} = cond!("id", "in.()")
      assert %Condition{value: [""]} = cond!("id", "in.( )")
      assert %Condition{value: [""]} = cond!("id", ~S[in.("")])
      assert %Condition{negate: true, value: ["a", "b"]} = cond!("id", "not.in.(a,b)")
    end

    test "in without parentheses is a syntax error" do
      assert {:error, %Error{status: 400, code: "PGRST100"}} =
               Filter.parse_condition("id", "in.5")
    end

    test "is values" do
      assert %Condition{op: :is, negate: false, value: :null} = cond!("a", "is.null")
      assert %Condition{negate: true, value: :null} = cond!("a", "not.is.null")
      assert %Condition{value: :not_null} = cond!("a", "is.not_null")
      assert %Condition{value: :unknown} = cond!("a", "is.unknown")
      assert %Condition{value: true} = cond!("a", "is.true")
      assert %Condition{value: false} = cond!("a", "is.FALSE")
      assert %Condition{value: :null} = cond!("a", "is.NULL")
    end

    test "is with an unknown value is a syntax error" do
      assert {:error, %Error{code: "PGRST100"}} = Filter.parse_condition("a", "is.maybe")
    end

    test "fts config" do
      assert %Condition{op: :fts, fts_config: "english", value: "cat"} =
               cond!("tsv", "fts(english).cat")

      assert %Condition{op: :wfts, negate: true, fts_config: "french"} =
               cond!("tsv", "not.wfts(french).cat")

      assert {:error, %Error{}} = Filter.parse_condition("tsv", "fts().cat")
    end
  end

  describe "parse_condition/2 fields" do
    test "json paths" do
      assert %Condition{field: %Field{name: "data", json_path: [arrow: "a", double_arrow: "b"]}} =
               cond!("data->a->>b", "eq.1")

      assert %Condition{field: %Field{name: "arr", json_path: [arrow: 0]}} =
               cond!("arr->0", "eq.1")

      assert %Condition{field: %Field{json_path: [double_arrow: -2]}} = cond!("arr->>-2", "eq.1")
      assert %Condition{field: %Field{json_path: [arrow: "k-1"]}} = cond!("d->k-1", "eq.1")
    end

    test "quoted names" do
      assert %Condition{field: %Field{name: "a.b"}} = cond!(~s("a.b"), "eq.1")
    end

    test "dashes inside names" do
      assert %Condition{field: %Field{name: "first-name"}} = cond!("first-name", "eq.1")
    end

    test "NUL bytes in identifiers are a 400" do
      assert {:error, %Error{status: 400, code: "PGRST100"}} =
               Filter.parse_condition("id\0x", "eq.1")

      assert {:error, %Error{status: 400, code: "PGRST100"}} =
               Filter.parse_condition("data->a\0b", "eq.1")

      assert {:error, %Error{status: 400, code: "PGRST100"}} =
               Filter.parse_condition(~s("a\0b"), "eq.1")
    end
  end

  describe "parse_condition/2 errors match recorded PostgREST text" do
    test "operator without a delimiter" do
      assert {:error, error} = Filter.parse_condition("id", "eq")
      assert error.status == 400
      assert error.code == "PGRST100"
      assert error.message == ~s|"failed to parse filter (eq)" (line 1, column 3)|
      assert error.details == "unexpected end of input expecting operator (eq, gt, ...)"
    end

    test "in and is failures" do
      assert {:error, %Error{details: ~S|unexpected "5" expecting "("|, message: message}} =
               Filter.parse_condition("id", "in.5")

      assert message == ~s|"failed to parse filter (in.5)" (line 1, column 4)|

      assert {:error, %Error{details: details}} = Filter.parse_condition("id", "is.maybe")
      assert details == ~S|unexpected "m" expecting isVal: (null, not_null, true, false, unknown)|

      assert {:error, %Error{details: ~S|unexpected "f" expecting operator (eq, gt, ...)|}} =
               Filter.parse_condition("id", "eq(foo).1")
    end

    test "unknown operator" do
      assert {:error, error} = Filter.parse_condition("id", "foo.1")
      assert error.message == ~s|"failed to parse filter (foo.1)" (line 1, column 1)|
      assert error.details == ~s|unexpected "f" expecting "not" or operator (eq, gt, ...)|
    end
  end

  describe "parse_logic/2" do
    test "builds a nested tree" do
      assert {:ok, tree} = Filter.parse_logic("or", "(a.eq.1,and(b.gt.2,not.or(c.eq.3,d.eq.4)))")

      assert tree == %Logic{
               op: :or,
               negate: false,
               children: [
                 %Condition{field: field("a"), op: :eq, value: "1"},
                 %Logic{
                   op: :and,
                   children: [
                     %Condition{field: field("b"), op: :gt, value: "2"},
                     %Logic{
                       op: :or,
                       negate: true,
                       children: [
                         %Condition{field: field("c"), op: :eq, value: "3"},
                         %Condition{field: field("d"), op: :eq, value: "4"}
                       ]
                     }
                   ]
                 }
               ]
             }
    end

    test "not.and key negates the root" do
      assert {:ok, %Logic{op: :and, negate: true, children: [_, _]}} =
               Filter.parse_logic("not.and", "(a.gte.0,a.lte.100)")
    end

    test "values with quoting, lists, negation and arrays" do
      assert {:ok, %Logic{op: :and, children: children}} =
               Filter.parse_logic(
                 "and",
                 ~S|(b.gt.2,c.not.is.null,d.in.("x,y",z),r.adj."[18,21)",t.cs.{a,b},j->>k.eq."q\"r")|
               )

      assert [
               %Condition{op: :gt},
               %Condition{field: %Field{name: "c"}, op: :is, negate: true, value: :null},
               %Condition{op: :in, value: ["x,y", "z"]},
               %Condition{op: :adj, value: "[18,21)"},
               %Condition{op: :cs, value: "{a,b}"},
               %Condition{field: %Field{name: "j", json_path: [double_arrow: "k"]}, value: "q\"r"}
             ] = children
    end

    test "whitespace around structure is ignored; values keep theirs" do
      assert {:ok, %Logic{children: [%Condition{value: "1 "}, %Condition{value: "2 "}]}} =
               Filter.parse_logic("or", "( a.eq.1 , b.eq.2 )")
    end

    test "text after the closing parenthesis is ignored, as upstream does" do
      assert {:ok, %Logic{children: [_]}} = Filter.parse_logic("or", "(id.eq.1)garbage")
    end

    test "depth: 16 levels parse, 17 do not" do
      assert {:ok, %Logic{}} = Filter.parse_logic("or", nested(16))

      assert {:error, error} = Filter.parse_logic("or", nested(17))
      assert error.status == 400
      assert error.code == "PGRST100"
      assert error.message == "logic tree depth exceeds 16"
    end

    test "unclosed tree matches the recorded error" do
      assert {:error, error} = Filter.parse_logic("or", "(id.eq.1")
      assert error.status == 400
      assert error.code == "PGRST100"
      assert error.message == ~s|"failed to parse logic tree ((id.eq.1)" (line 1, column 11)|
      assert error.details == ~s|unexpected end of input expecting "," or ")"|
    end

    test "other syntax errors" do
      assert {:error, %Error{code: "PGRST100", details: details}} = Filter.parse_logic("or", "()")

      assert details ==
               ~s|unexpected ")" expecting field name (* or [a..z0..9_$]), negation operator (not) or logic operator (and, or)|

      assert {:error, %Error{details: ~s[unexpected "x" expecting logic operator (and, or)]}} =
               Filter.parse_logic("or", "(id.eq.1,not.xor(id.eq.2,id.eq.3))")

      assert {:error, %Error{details: ~s[unexpected "1" expecting "("]}} =
               Filter.parse_logic("or", "(id.in.1,2)")
    end

    test "error text matches live PostgREST" do
      cases = [
        {"(id.eq.1,ord(id.eq.1))", 14, ~S|unexpected "d" expecting "("|},
        {"(id.eq.1,x.foo.2)", 14, ~S|unexpected "f" expecting "not" or operator (eq, gt, ...)|},
        {"(id.eq.1,x)", 13,
         ~S|unexpected ")" expecting letter, digit, "-", "->>", "->" or delimiter (.)|},
        {"(id.is.maybe)", 10,
         ~S|unexpected "m" expecting isVal: (null, not_null, true, false, unknown)|},
        {"(id.eq.1,id.in.(1,2)x)", 23, ~S|unexpected "x" expecting "," or ")"|}
      ]

      for {value, column, details} <- cases do
        assert {:error, error} = Filter.parse_logic("or", value)

        assert error.message ==
                 ~s|"failed to parse logic tree (#{value})" (line 1, column #{column})|

        assert error.details == details
      end
    end

    test "NUL in a quoted identifier is a 400" do
      assert {:error, %Error{status: 400, code: "PGRST100"}} =
               Filter.parse_logic("or", ~s[("a\0b".eq.1)])
    end
  end

  describe "Common.cast_name?/1" do
    test "accepts plain and single-spaced type names" do
      for name <- ["integer", "timestamp with time zone", "character varying", "_x$1", "numeric"] do
        assert Common.cast_name?(name), name
      end
    end

    test "rejects anything else" do
      too_long = String.duplicate("a", 64)

      for name <- [
            "",
            "1a",
            "a;b",
            "a\"b",
            "text[",
            "text[]",
            "int[]",
            "a)\n",
            "a\0b",
            "a-b",
            "text $1",
            "x $q$",
            "$a",
            "a  b",
            " a",
            "a ",
            too_long
          ] do
        refute Common.cast_name?(name), inspect(name)
      end

      assert Common.cast_name?(String.duplicate("a", 63))
    end
  end

  describe "embed paths" do
    test "Common.parse_tree_path/1 splits the embed path from the column" do
      assert {:ok, {["a", "b"], %Field{name: "col", json_path: [arrow: "x"]}}} =
               Common.parse_tree_path("a.b.col->x")

      assert {:ok, {["a.b"], %Field{name: "c"}}} = Common.parse_tree_path(~s("a.b".c))
      assert {:ok, {[], %Field{name: "id"}}} = Common.parse_tree_path("id")
      assert {:error, %Error{code: "PGRST100"}} = Common.parse_tree_path("")
      assert {:error, %Error{code: "PGRST100"}} = Common.parse_tree_path("a..b")
      assert {:error, %Error{code: "PGRST100"}} = Common.parse_tree_path(~s("a\0b".c))
    end

    test "parse_filter/2 returns the embed path, parse_condition/2 the condition" do
      assert {:ok, {["rel"], %Condition{field: %Field{name: "col"}, value: "1"}}} =
               Filter.parse_filter("rel.col", "eq.1")

      assert %Condition{field: %Field{name: "col"}} = cond!("rel.col", "eq.1")
    end

    test "logic keys behind an embed path" do
      assert {:ok, %Logic{op: :or, negate: false}} = Filter.parse_logic("client.or", "(a.eq.1)")

      assert {:ok, %Logic{op: :and, negate: true}} =
               Filter.parse_logic("client.not.and", "(a.eq.1)")

      assert {:ok, {["client"], %Logic{op: :or}}} =
               Filter.parse_logic_tree("client.or", "(a.eq.1)")
    end

    test "other logic keys are a 400, never a crash" do
      assert {:error, %Error{status: 400, code: "PGRST100"}} =
               Filter.parse_logic("foo", "(a.eq.1)")

      assert {:error, %Error{status: 400, code: "PGRST100"}} = Filter.parse_logic("", "(a.eq.1)")

      assert {:error, %Error{status: 400, code: "PGRST100"}} =
               Filter.parse_logic("or\0", "(a.eq.1)")
    end
  end

  describe "error rendering" do
    test "control and non-ASCII characters are shown the Haskell way" do
      assert {:error, %Error{details: details}} = Filter.parse_condition("id", "\x01")
      assert details == ~S|unexpected "\SOH" expecting "not" or operator (eq, gt, ...)|

      assert {:error, %Error{details: details}} = Filter.parse_condition("id", "\r")
      assert details == ~S|unexpected "\r" expecting "not" or operator (eq, gt, ...)|

      assert {:error, %Error{details: details}} = Filter.parse_condition("id", "\x7f")
      assert details == ~S|unexpected "\DEL" expecting "not" or operator (eq, gt, ...)|

      assert {:error, %Error{details: details}} = Filter.parse_condition("id", "é")
      assert details == ~S|unexpected "\233" expecting "not" or operator (eq, gt, ...)|

      assert {:error, %Error{details: details}} = Filter.parse_condition("id", <<0xFF>>)
      assert details == ~S|unexpected "\65533" expecting "not" or operator (eq, gt, ...)|
    end

    test "quotes inside the echoed input are not escaped in the message" do
      assert {:error, %Error{message: message}} = Filter.parse_condition("id", ~S|x"y|)
      assert message == ~S|"failed to parse filter (x"y)" (line 1, column 1)|
    end

    test "a lone character after a complete token is single-quoted" do
      assert {:error, %Error{details: details}} = Filter.parse_logic("or", "(a.eq.1,b.in.(1)x)")
      assert details == ~S|unexpected "x" expecting "," or ")"|
    end

    test "columns count code points, not graphemes" do
      assert {:error, %Error{message: message}} = Filter.parse_logic("or", "(é.eq.1,x)")
      assert message == "\"failed to parse logic tree ((é.eq.1,x))\" (line 1, column 13)"
    end
  end

  describe "parse_array_literal/1" do
    test "splits a PostgreSQL array literal, unquoting and trimming elements" do
      assert {:ok, ["a", "b c", "d,e"]} = Filter.parse_array_literal(~s|{a, b c ,"d,e"}|)
    end

    test "an empty literal is the empty list" do
      assert {:ok, []} = Filter.parse_array_literal("{}")
    end

    test "anything else is not an array literal" do
      assert :error = Filter.parse_array_literal("[1,5)")
      assert :error = Filter.parse_array_literal(~s|{"a":1}|)
      assert :error = Filter.parse_array_literal("{a}{b}")
    end
  end

  describe "operator_prefix?/1" do
    test "true when the value starts with [not.]op[(modifier)]., whatever follows" do
      for value <- ~w[eq.1 not.gt.5 is.maybe in.abc eq(any).x fts(english).cats cs.] do
        assert Filter.operator_prefix?(value), value
      end
    end

    test "false when there is no operator prefix" do
      for value <- ~w[hello john.smith not.hello ilikefoo gt not. (any).x] ++ [""] do
        refute Filter.operator_prefix?(value), value
      end
    end
  end

  defp nested(1), do: "(a.eq.1)"
  defp nested(depth), do: "(and" <> nested(depth - 1) <> ")"
end
