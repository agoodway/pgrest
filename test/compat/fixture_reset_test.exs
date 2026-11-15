defmodule PgRest.Compat.FixtureResetTest do
  use ExUnit.Case, async: false

  alias PgRest.Compat.{Fixture, Repo, Scenario}

  defp rolled_back_insert,
    do: Fixture.rolled_back_insert!(Repo, "INSERT INTO test.items DEFAULT VALUES RETURNING id")

  test "reset_sequences!/1 makes two rolled-back inserts receive the same id" do
    baseline = Scenario.baseline_for(%{fixture: :test})

    first = rolled_back_insert()
    second_without_reset = rolled_back_insert()
    :ok = Fixture.reset_sequences!(baseline)
    second = rolled_back_insert()
    :ok = Fixture.reset_sequences!(baseline)

    assert second_without_reset != first
    assert second == first
  end
end
