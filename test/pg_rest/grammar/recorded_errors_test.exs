defmodule PgRest.Grammar.RecordedErrorsTest do
  # Every recorded (or inline) PGRST100 parse failure of the grammar scenarios must be
  # reproduced byte for byte by the grammar modules alone, pending or not.
  use ExUnit.Case, async: true

  alias PgRest.Compat.Scenario
  alias PgRest.Error
  alias PgRest.Grammar.{Filter, Order, Select}

  @areas ~w(filter_syntax select_syntax order_syntax)
  @logic_keys ~w(or and not.or not.and)

  defp parse("select", value), do: Select.parse(value)
  defp parse("order", value), do: Order.parse(value)
  defp parse(key, value) when key in @logic_keys, do: Filter.parse_logic(key, value)
  defp parse(key, value), do: Filter.parse_condition(key, value)

  failures =
    for area <- @areas,
        {scenario, expected} <- Scenario.recorded_scenarios(area, false),
        %{status: 400, body: encoded} <- [expected],
        {:ok, %{"code" => "PGRST100"} = body} <- [Jason.decode(encoded)],
        [{key, value}] =
          scenario.path
          |> URI.parse()
          |> Map.fetch!(:query)
          |> URI.query_decoder()
          |> Enum.to_list() do
      {scenario.id, key, value, body}
    end

  @failures failures

  test "there are recorded parse failures to compare" do
    assert length(@failures) >= 20
  end

  for {id, key, value, body} <- @failures do
    test "#{id} matches its recording" do
      assert {:error, %Error{} = error} = parse(unquote(key), unquote(value))
      assert Error.to_body(error) == unquote(Macro.escape(body))
    end
  end
end
