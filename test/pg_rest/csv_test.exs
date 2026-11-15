defmodule PgRest.CsvTest do
  @moduledoc """
  Review Focus 5: the CSV body of PgRest equals live PostgREST byte for byte, on rows whose
  text needs quoting (commas, quotes, newlines, unicode, NULL, an empty string, jsonb, arrays).
  """
  use ExUnit.Case, async: false

  alias PgRest.Compat.{Compare, Scenario}

  @moduletag :differential

  @csv [{"accept", "text/csv"}]

  setup_all do
    Enum.each(Scenario.registries(), &start_supervised!/1)
    :ok
  end

  defp scenario(path, headers \\ @csv) do
    [scenario] = Scenario.build!([%{id: "csv/adhoc", path: path, headers: headers}], "csv")
    scenario
  end

  defp assert_same(path) do
    {pgrest, postgrest} = path |> scenario() |> Scenario.run_pair()

    assert :ok = Compare.diff(postgrest, pgrest, [])
    assert pgrest.body == postgrest.body
    assert pgrest.status == 200
    {pgrest.body, postgrest.body}
  end

  test "every edge row, with the columns that need quoting" do
    {body, _} = assert_same("/csv_edge_cases?select=id,txt,js,arr&order=id")

    assert body =~ "id,txt,js,arr\n"
    assert body =~ ~s|1,"a,b",,\n|
  end

  for id <- 1..9 do
    test "edge case #{id} alone" do
      assert_same("/csv_edge_cases?select=id,txt,js,arr&id=eq.#{unquote(id)}")
    end
  end

  test "a column subset" do
    assert_same("/csv_edge_cases?select=txt&order=id")
  end

  test "an empty result is whatever PostgREST emits, and only that" do
    {pgrest, postgrest} =
      "/csv_edge_cases?select=id,txt&id=eq.0" |> scenario() |> Scenario.run_pair()

    assert pgrest.body == postgrest.body
    assert pgrest.body == "\n"
    assert pgrest.status == postgrest.status
    assert :ok = Compare.diff(postgrest, pgrest, [])
  end

  test "HEAD sends the CSV headers and no body" do
    {pgrest, postgrest} =
      [%{id: "csv/head", method: "HEAD", path: "/csv_edge_cases?select=id", headers: @csv}]
      |> Scenario.build!("csv")
      |> hd()
      |> Scenario.run_pair()

    assert pgrest.body == "" and postgrest.body == ""
    assert :ok = Compare.diff(postgrest, pgrest, [])
  end
end
