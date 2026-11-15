defmodule PgRest.Registry.SnapshotHintTest do
  use ExUnit.Case, async: true

  alias PgRest.Error
  alias PgRest.Registry.Snapshot

  defp snap(count) do
    resources = Map.new(1..count, &{{"public", "table_number_#{&1}"}, %{}})

    %Snapshot{
      name: :hint,
      generation: 1,
      schemas: ["public"],
      default_schema: "public",
      resources: resources,
      by_module: %{},
      graph: nil,
      graphs: %{}
    }
  end

  test "a small schema gets a table hint" do
    assert {:error, %Error{code: "PGRST205", hint: hint}} =
             Snapshot.fetch_resource(snap(3), "public", "table_number_")

    assert hint =~ "Perhaps you meant the table 'public.table_number_"
  end

  test "a schema with 500 tables or more gets no hint (maxDbTablesForFuzzySearch)" do
    assert {:error, %Error{hint: nil}} =
             Snapshot.fetch_resource(snap(500), "public", "table_number_")

    assert {:error, %Error{hint: hint}} =
             Snapshot.fetch_resource(snap(499), "public", "table_number_")

    assert is_binary(hint)
  end

  test "a URL-sized table name is answered quickly" do
    name = String.duplicate("table_number_", 1_200)

    {micros, result} = :timer.tc(fn -> Snapshot.fetch_resource(snap(499), "public", name) end)

    assert {:error, %Error{code: "PGRST205"}} = result
    assert micros < 300_000
  end
end
