defmodule Mix.Tasks.Pgrest.Compat.Record do
  @shortdoc "Records golden scenario expectations from live PostgREST"

  @moduledoc """
  Records `test/compat/expected/<area>.json` from live PostgREST.

      MIX_ENV=test mix pgrest.compat.record <area>
      MIX_ENV=test mix pgrest.compat.record --all

  Rebuilds the compat database first so recordings start from the fixture state.
  Scenarios marked `only: :pgrest` are not recorded.
  """

  use Mix.Task

  alias PgRest.Compat.{Fixture, Scenario}

  @requirements ["app.start"]

  @impl Mix.Task
  def run(["--all"]), do: record(Scenario.areas())
  def run([area]), do: record([area])
  def run(_), do: Mix.raise("usage: mix pgrest.compat.record <area> | --all")

  defp record(areas) do
    :ok = Fixture.load!()

    Enum.each(areas, &record_area/1)
  end

  defp record_area(area) do
    recorded =
      area
      |> Scenario.load()
      |> Enum.filter(&(&1.only == :both))
      |> Enum.map(fn scenario ->
        response = Scenario.run_isolated(:postgrest, scenario)
        stored = Scenario.to_stored(response, scenario.response_headers)
        {scenario.id, stored}
      end)

    path = Scenario.expected_path(area)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, encode(recorded))
    Mix.shell().info("recorded #{length(recorded)} scenarios -> #{Path.relative_to_cwd(path)}")
  end

  defp encode(recorded) do
    recorded
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {id, stored} -> {id, ordered(stored)} end)
    |> Jason.OrderedObject.new()
    |> Jason.encode!(pretty: true)
    |> Kernel.<>("\n")
  end

  defp ordered(%{"headers" => headers} = stored) do
    stored
    |> Map.put("headers", headers |> Enum.sort() |> Jason.OrderedObject.new())
    |> Enum.sort()
    |> Jason.OrderedObject.new()
  end
end
