# Differential run against live PostgREST (`mix test --only differential`).
#
# Per scenario: the recording must equal live PostgREST (sanity), and PgRest must
# equal live PostgREST. Stateful scenarios run `reset, PgRest, reset, PostgREST`.
alias PgRest.Compat.{Compare, Scenario}

pending = Scenario.pending()

for stateful? <- [false, true] do
  module =
    if stateful?, do: PgRest.Compat.StatefulDifferentialTest, else: PgRest.Compat.DifferentialTest

  defmodule module do
    use ExUnit.Case, async: false

    setup_all do
      Enum.each(Scenario.registries(), &start_supervised!/1)
      :ok
    end

    @moduletag :differential

    for area <- Scenario.areas(),
        {scenario, expected} <- Scenario.recorded_scenarios(area, stateful?) do
      @scenario scenario

      if scenario.only == :both do
        @expected expected
        test "#{scenario.id}: recording equals live PostgREST" do
          actual = Scenario.run_live(@scenario)

          assert :ok =
                   Compare.diff(@expected, actual,
                     sort: @scenario.sort,
                     compare: @scenario.compare,
                     headers: @scenario.response_headers
                   )
        end
      end

      if scenario.id in pending, do: @tag(skip: "pending: PgRest cannot serve it yet")

      test "#{scenario.id}: PgRest equals PostgREST" do
        {pgrest, postgrest} = Scenario.run_pair(@scenario)

        assert :ok =
                 Compare.diff(postgrest, pgrest,
                   sort: @scenario.sort,
                   compare: @scenario.compare,
                   headers: @scenario.response_headers
                 )
      end
    end
  end
end
