defmodule PgRest.Compat.FixtureSelectionTest do
  # Resets and advances the shared supabase sequence, so it must not overlap other modules.
  use ExUnit.Case, async: false

  alias PgRest.Compat.{Fixture, Scenario, SupabaseRepo}

  describe "fixture selection" do
    @messages_seq "public.messages_id_seq"

    defp messages_state do
      %{rows: [[last, called?]]} =
        SupabaseRepo.query!("SELECT last_value, is_called FROM #{@messages_seq}")

      {last, called?}
    end

    test "a scenario's sequence baseline follows its fixture" do
      assert Scenario.baseline_for(%{fixture: :test}) == Fixture.sequence_baseline(:test)
      assert Scenario.baseline_for(%{fixture: :supabase}) == Fixture.sequence_baseline(:supabase)

      assert Scenario.baseline_for(%{fixture: :supabase_scope}) ==
               Fixture.sequence_baseline(:supabase)

      assert Scenario.baseline_for(%{fixture: :supabase}).repo == SupabaseRepo
    end

    test "run_isolated resets the supabase baseline before and after the run" do
      baseline = messages_state()
      SupabaseRepo.query!("SELECT setval($1::text::regclass, $2)", [@messages_seq, 4_000])

      spy = fn _scenario ->
        assert messages_state() == baseline
        SupabaseRepo.query!("SELECT nextval($1::text::regclass)", [@messages_seq])
        %{status: 200, headers: %{}, body: ""}
      end

      assert %{status: 200} = Scenario.run_isolated(spy, %{fixture: :supabase, id: "x/spy"})
      assert messages_state() == baseline
    end
  end
end
