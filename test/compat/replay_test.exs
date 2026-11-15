defmodule PgRest.Compat.ReplayTest do
  # Stateful scenarios must not depend on the order the engines run in: the reverse order
  # (PostgREST, then PgRest) gives each engine the same response as the usual order.
  use ExUnit.Case, async: false

  alias PgRest.Compat.{Compare, Scenario}

  @moduletag :differential

  setup_all do
    Enum.each(Scenario.registries(), &start_supervised!/1)
    :ok
  end

  for {scenario, _expected} <- Scenario.recorded_scenarios("insert", true),
      scenario.only == :both do
    @scenario scenario

    test "#{scenario.id} gives the same responses in reverse engine order" do
      forward = Scenario.run_both(@scenario, [:pgrest, :postgrest])
      reverse = Scenario.run_both(@scenario, [:postgrest, :pgrest])

      for engine <- [:pgrest, :postgrest] do
        assert :ok = Compare.diff(forward[engine], reverse[engine], sort: false)
      end
    end
  end
end
