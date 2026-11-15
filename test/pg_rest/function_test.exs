defmodule PgRest.FunctionTest do
  use ExUnit.Case, async: true

  alias PgRest.Compat.Functions.GetStatus
  alias PgRest.Function
  alias PgRest.Function.{Param, Return}

  defmodule SetOfProjects do
    @moduledoc false
    use PgRest.Function,
      schema: "test",
      name: "getallprojects",
      returns: {:setof, PgRest.Compat.Resources.Projects},
      volatility: :stable,
      result_scope: :none
  end

  defmodule Columns do
    @moduledoc false
    use PgRest.Function,
      schema: "test",
      name: "overloaded_same_args",
      params: [{"arg", "text"}, {"num", "integer", default: true}],
      returns: {:composite, [{"type", "text"}, {"value", "text"}]}
  end

  defmodule Variadic do
    @moduledoc false
    use PgRest.Function,
      schema: "test",
      name: "variadic_param",
      params: [{"v", "text[]", variadic: true}],
      returns: {:setof_scalar, "text"}
  end

  test "use PgRest.Function defines __pgrest_function__/0" do
    assert %Function{
             schema: "public",
             name: "get_status",
             params: [%Param{name: "name_param", type: "text", required?: true, variadic?: false}],
             returns: %Return{kind: :scalar, set?: false, type: "user_status", resource: nil},
             volatility: :immutable,
             result_scope: :stored_rows,
             module: GetStatus
           } = GetStatus.__pgrest_function__()
  end

  test "resource, column, default and variadic declarations" do
    assert %Function{
             returns: %Return{
               kind: :composite,
               set?: true,
               type: "test.projects",
               resource: PgRest.Compat.Resources.Projects
             },
             result_scope: :none
           } = SetOfProjects.__pgrest_function__()

    assert %Function{
             params: [%Param{required?: true}, %Param{name: "num", required?: false}],
             returns: %Return{kind: :composite, set?: false, type: "record", columns: [_, _]},
             volatility: :volatile
           } = Columns.__pgrest_function__()

    assert %Function{
             params: [%Param{variadic?: true}],
             returns: %Return{kind: :scalar, set?: true}
           } = Variadic.__pgrest_function__()

    assert Function.label(Variadic.__pgrest_function__()) == "test.variadic_param"
  end

  test "invalid options raise ArgumentError" do
    base = [schema: "test", name: "f", returns: :void]

    for bad <- [
          Keyword.put(base, :result_scope, :bogus),
          Keyword.put(base, :volatility, :sometimes),
          Keyword.put(base, :returns, {:table, "x"}),
          Keyword.put(base, :params, [{"a", :integer}]),
          Keyword.put(base, :extra, true),
          Keyword.delete(base, :name)
        ] do
      assert_raise ArgumentError, fn -> Function.validate!(bad) end
    end

    assert_raise ArgumentError, ~r/invalid result_scope :bogus for function f/, fn ->
      Function.validate!(Keyword.put(base, :result_scope, :bogus))
    end
  end

  test "an invalid :returns names its shape; invalid columns name the columns" do
    base = [schema: "test", name: "f"]

    assert_raise ArgumentError, ~r/\Ainvalid PgRest.Function :returns: \{:table, "x"\}\z/, fn ->
      Function.validate!(Keyword.put(base, :returns, {:table, "x"}))
    end

    assert_raise ArgumentError,
                 ~r/\Ainvalid PgRest.Function :returns columns: \[\{"a", :integer\}\]\z/,
                 fn ->
                   Function.validate!(Keyword.put(base, :returns, {:setof, [{"a", :integer}]}))
                 end
  end
end
