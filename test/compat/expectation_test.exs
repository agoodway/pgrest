# Replays every recorded scenario against PgRest and compares with the recording.
# Stateless scenarios run async; stateful ones run serially with sequence resets.
alias PgRest.Compat.{Compare, Scenario}

pending = Scenario.pending()

for stateful? <- [false, true] do
  module =
    if stateful?, do: PgRest.Compat.StatefulExpectationTest, else: PgRest.Compat.ExpectationTest

  defmodule module do
    use ExUnit.Case, async: not stateful?

    setup_all do
      Enum.each(Scenario.registries(), &start_supervised!/1)
      :ok
    end

    for area <- Scenario.areas(),
        {scenario, expected} <- Scenario.recorded_scenarios(area, stateful?) do
      @scenario scenario
      @expected expected
      @stateful stateful?
      if scenario.id in pending, do: @tag(skip: "pending: PgRest cannot serve it yet")

      test "#{scenario.id}" do
        actual =
          if @stateful,
            do: Scenario.run_isolated(:pgrest, @scenario),
            else: Scenario.run_pgrest(@scenario)

        assert :ok =
                 Compare.diff(@expected, actual,
                   sort: @scenario.sort,
                   compare: @scenario.compare,
                   headers: @scenario.response_headers
                 )
      end
    end
  end
end
