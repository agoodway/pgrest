defmodule PgRest.Grammar.FilterPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PgRest.AST.Condition
  alias PgRest.Grammar.Filter

  defp quote_value(value),
    do: ~s("#{value |> String.replace("\\", "\\\\") |> String.replace(~s("), ~s(\\"))}")

  defp value_gen do
    [string(:printable, max_length: 6), member_of(~w[, . : ( ) " \\ é 日 😀])]
    |> one_of()
    |> list_of(max_length: 6)
    |> map(&Enum.join/1)
    |> filter(&String.valid?/1)
  end

  property "quoted in-list values round-trip" do
    check all(v1 <- value_gen(), v2 <- value_gen()) do
      input = "in.(#{quote_value(v1)},#{quote_value(v2)})"

      assert {:ok, %Condition{op: :in, value: [^v1, ^v2]}} = Filter.parse_condition("id", input)
    end
  end

  property "quoted values round-trip inside logic trees" do
    check all(v1 <- value_gen(), v2 <- value_gen()) do
      input = "(a.eq.#{quote_value(v1)},b.in.(#{quote_value(v2)}))"

      assert {:ok, %{children: [%Condition{value: ^v1}, %Condition{value: [^v2]}]}} =
               Filter.parse_logic("or", input)
    end
  end
end
