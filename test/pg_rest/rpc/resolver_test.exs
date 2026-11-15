defmodule PgRest.RPC.ResolverTest do
  use ExUnit.Case, async: true

  alias PgRest.{Error, Function}
  alias PgRest.Function.{Param, Return}
  alias PgRest.Registry.Snapshot
  alias PgRest.RPC.Resolver

  defp param(name, type \\ "integer", opts \\ []),
    do: %Param{name: name, type: type, required?: !Keyword.get(opts, :optional, false)}

  defp fun(name, params, schema \\ "test") do
    %Function{
      schema: schema,
      name: name,
      params: params,
      returns: %Return{kind: :scalar, type: "integer"},
      volatility: :stable
    }
  end

  defp snap(functions), do: Snapshot.build(:rpc_test, ["test"], [], functions: functions)

  defp resolve(functions, name, keys, invocation \\ :read),
    do: Resolver.resolve(snap(functions), "test", name, keys, invocation)

  describe "matching" do
    test "no params matches no keys" do
      f = fun("f", [])
      assert {:ok, ^f} = resolve([f], "f", [])
      assert {:error, %Error{code: "PGRST202"}} = resolve([f], "f", ["a"])
    end

    test "required params need exactly the required names" do
      f = fun("f", [param("a"), param("b")])
      assert {:ok, ^f} = resolve([f], "f", ["b", "a"])
      assert {:error, %Error{code: "PGRST202"}} = resolve([f], "f", ["a"])
      assert {:error, %Error{code: "PGRST202"}} = resolve([f], "f", ["a", "b", "c"])
    end

    test "optional params accept any subset, including none" do
      f = fun("f", [param("a", "integer", optional: true), param("b", "text", optional: true)])
      assert {:ok, ^f} = resolve([f], "f", [])
      assert {:ok, ^f} = resolve([f], "f", ["b"])
      assert {:error, %Error{code: "PGRST202"}} = resolve([f], "f", ["c"])
    end

    test "with both, the keys minus the optional names must equal the required names" do
      f = fun("f", [param("a"), param("o", "text", optional: true)])
      assert {:ok, ^f} = resolve([f], "f", ["a"])
      assert {:ok, ^f} = resolve([f], "f", ["o", "a"])
      assert {:error, %Error{code: "PGRST202"}} = resolve([f], "f", ["o"])
    end

    test "picks the one matching overload" do
      one = fun("f", [param("a")])
      two = fun("f", [param("b")])
      assert {:ok, ^two} = resolve([one, two], "f", ["b"])
    end
  end

  describe "the unnamed json fallback" do
    test "applies to a POST only" do
      f = fun("f", [param("", "json")])
      assert {:ok, ^f} = resolve([f], "f", ["a", "b"], :post)
      assert {:error, %Error{code: "PGRST202"}} = resolve([f], "f", ["a", "b"], :read)
    end

    test "json takes json or jsonb, and an exact match still wins" do
      for type <- ~w(json jsonb) do
        f = fun("f", [param("", type)])
        assert {:ok, ^f} = resolve([f], "f", ["x"], :post)
      end

      text = fun("f", [param("", "text")])
      assert {:error, %Error{code: "PGRST202"}} = resolve([text], "f", ["x"], :post)

      named = fun("f", [param("x")])
      unnamed = fun("f", [param("", "json")])
      assert {:ok, ^named} = resolve([named, unnamed], "f", ["x"], :post)
    end

    test "several fallbacks are ambiguous" do
      a = fun("f", [param("", "json")])
      b = fun("f", [param("", "jsonb")])
      assert {:error, %Error{status: 300, code: "PGRST203"}} = resolve([a, b], "f", ["k"], :post)
    end

    test "a function with another unnamed parameter is not in the schema cache" do
      f = fun("f", [param("", "integer")])
      assert {:error, %Error{code: "PGRST202"}} = resolve([f], "f", [""], :post)
      assert {:error, %Error{code: "PGRST202"}} = resolve([f], "f", [], :post)
    end
  end

  describe "non-JSON bodies" do
    test "reach only the single unnamed parameter of the body's type" do
      for {media, type} <- [text: "text", xml: "xml", bytea: "bytea"] do
        f = fun("f", [param("", type)])
        assert {:ok, ^f} = resolve([f], "f", [], {:post, media})
      end

      json = fun("f", [param("", "json")])
      assert {:error, %Error{code: "PGRST202"}} = resolve([json], "f", [], {:post, :text})
    end

    test "never match a function by argument names, even one without parameters" do
      none = fun("f", [])
      named = fun("g", [param("a")])
      assert {:error, %Error{code: "PGRST202"}} = resolve([none], "f", [], {:post, :text})
      assert {:error, %Error{code: "PGRST202"}} = resolve([named], "g", ["a"], {:post, :xml})
    end

    test "report the unnamed parameter in the PGRST202 text, with no hint" do
      f = fun("sayhello", [param("", "json")])

      assert {:error, error} = resolve([f], "sayhell", ["x"], {:post, :bytea})

      assert %Error{
               status: 404,
               message: "Could not find the function test.sayhell in the schema cache",
               details:
                 "Searched for the function test.sayhell with a single unnamed bytea parameter, " <>
                   "but no matches were found in the schema cache.",
               hint: nil
             } = error
    end
  end

  describe "PGRST203" do
    test "lists the candidates with their parameter types" do
      a = fun("f", [param("a", "integer")])
      b = fun("f", [param("a", "text"), param("n", "integer", optional: true)])

      assert {:error, error} = resolve([a, b], "f", ["a"])

      assert %Error{
               status: 300,
               code: "PGRST203",
               message:
                 "Could not choose the best candidate function between: " <>
                   "test.f(a => integer), test.f(a => text, n => integer)",
               details: nil,
               hint:
                 "Try renaming the parameters or the function itself in the database so " <>
                   "function overloading can be resolved"
             } = error
    end
  end

  describe "PGRST202 text" do
    setup do
      %{
        funs: [
          fun("sayhello", [param("name", "text")]),
          fun("add_them", [param("a"), param("b")])
        ]
      }
    end

    test "no keys, on a read", %{funs: funs} do
      assert {:error, error} = resolve(funs, "sayhell", [])

      assert %Error{
               status: 404,
               code: "PGRST202",
               message:
                 "Could not find the function test.sayhell without parameters in the schema cache",
               details:
                 "Searched for the function test.sayhell without parameters, " <>
                   "but no matches were found in the schema cache.",
               hint: "Perhaps you meant to call the function test.sayhello"
             } = error
    end

    test "no keys, on a post", %{funs: funs} do
      assert {:error, %Error{details: details}} = resolve(funs, "sayhell", [], :post)

      assert details ==
               "Searched for the function test.sayhell without parameters or with a single " <>
                 "unnamed json/jsonb parameter, but no matches were found in the schema cache."
    end

    test "one key, with a parameter-list hint when the name exists", %{funs: funs} do
      assert {:error, error} = resolve(funs, "sayhello", ["nam"])

      assert %Error{
               message: "Could not find the function test.sayhello(nam) in the schema cache",
               details:
                 "Searched for the function test.sayhello with parameter nam, " <>
                   "but no matches were found in the schema cache.",
               hint: "Perhaps you meant to call the function test.sayhello(name)"
             } = error
    end

    test "two keys, keys sorted, on a post", %{funs: funs} do
      assert {:error, error} = resolve(funs, "add_them", ["smthelse", "b", "a"], :post)

      assert %Error{
               message:
                 "Could not find the function test.add_them(a, b, smthelse) in the schema cache",
               details:
                 "Searched for the function test.add_them with parameters a, b, smthelse or " <>
                   "with a single unnamed json/jsonb parameter, but no matches were found in " <>
                   "the schema cache.",
               hint: "Perhaps you meant to call the function test.add_them(a, b)"
             } = error
    end

    test "no hint when nothing is close", %{funs: funs} do
      assert {:error, %Error{hint: nil}} = resolve(funs, "zzzzzzzz", ["a"])
      assert {:error, %Error{hint: nil}} = resolve(funs, "sayhello", ["qqqqqqqq"])
    end

    test "the parameter-list hint follows the recorded PostgREST scoring" do
      funs = [fun("add_them", [param("a"), param("b")])]

      for {keys, hint?} <- [{["a"], true}, {["b"], true}, {["x", "y"], true}, {["c"], false}] do
        assert {:error, %Error{hint: hint}} = resolve(funs, "add_them", keys)
        assert is_binary(hint) == hint?
      end

      many = ~w(a b c d e f g)
      assert {:error, %Error{hint: nil}} = resolve(funs, "add_them", many)
    end

    test "the hint compares sorted parameter lists" do
      funs = [fun("f", [param("name", "text"), param("age")])]

      assert {:error, %Error{hint: "Perhaps you meant to call the function test.f(age, name)"}} =
               resolve(funs, "f", ["nam"])
    end

    test "a POST with thousands of keys gets no hint" do
      funs = [fun("f", [param("a")])]
      keys = for i <- 1..10_000, do: "key_number_#{i}"

      assert {:error, %Error{code: "PGRST202", hint: nil}} = resolve(funs, "f", keys, :post)

      long = String.duplicate("x", 100_000)
      assert {:error, %Error{hint: nil}} = resolve(funs, long, [], :read)
    end

    # The key-count cap decides before any text is built: no second sort/join of the keys, and
    # no `Enum.uniq/1` (about 0.6 s on this many keys).
    test "half a million keys, repeated, are deduplicated and answered with no hint" do
      funs = [fun("f", [param("a")])]
      keys = for i <- 1..250_000, _ <- 1..2, do: "key_number_#{i}"

      assert {:error, %Error{code: "PGRST202", hint: nil, message: message}} =
               resolve(funs, "f", keys, :post)

      assert message =~ "test.f(key_number_1, key_number_10, key_number_100,"
      refute message =~ "key_number_1, key_number_1,"
    end

    test "duplicate keys still match a function by its parameter names" do
      f = fun("f", [param("a"), param("b")])
      assert {:ok, ^f} = resolve([f], "f", ["b", "a", "b", "a"])
    end

    test "a function in another schema is not found" do
      f = fun("f", [], "other")
      assert {:error, %Error{code: "PGRST202"}} = resolve([f], "f", [])
    end
  end
end
