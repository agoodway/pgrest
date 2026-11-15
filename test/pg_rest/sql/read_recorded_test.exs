defmodule PgRest.SQL.ReadRecordedTest do
  # Replays the recorded select, ordering and embedding scenarios through the planner and
  # the read compiler (no Plug yet): each GET runs as one statement and its JSON body is
  # compared with what PostgREST returned. Errors compare status and body.
  use ExUnit.Case, async: true

  import Plug.Test

  alias PgRest.Compat.{Repo, Resources, Scenario}
  alias PgRest.{Error, Planner, Request, SchemaGraph}
  alias PgRest.Error.Translate
  alias PgRest.SQL.Read

  @areas ["select", "ordering", "embedding"]
  @graph SchemaGraph.build(Resources.all())
  @tables Map.new(Resources.all(), &{&1.__pgrest_config__().table, &1})

  defp run(scenario) do
    conn =
      Enum.reduce(scenario.headers, conn("GET", scenario.path), fn {k, v}, acc ->
        Plug.Conn.put_req_header(acc, k, v)
      end)

    %URI{path: "/" <> table} = URI.parse(scenario.path)
    context = %{repo: Repo, graph: @graph, max_limit: if(scenario.server == :limits, do: 2)}

    with {:ok, request} <- Request.from_conn(conn, []),
         {:ok, plan} <- Planner.plan_read(request, Map.fetch!(@tables, table), context) do
      {sql, params} = Read.statement(plan, context)

      case Repo.query(sql, params, log: false) do
        {:ok, %{rows: [[total, _page_total, body, _headers, _status]]}} -> {:ok, total, body}
        {:error, exception} -> {:error, Translate.from_exception(exception, :anon)}
      end
    end
  end

  for area <- @areas, {scenario, expected} <- Scenario.recorded_scenarios(area, false) do
    @scenario scenario
    @expected expected

    test "#{scenario.id}" do
      case {run(@scenario), @expected} do
        {{:ok, total, body}, %{status: status} = expected} when status in [200, 206] ->
          assert Jason.decode!(body) == Jason.decode!(expected.body)

          assert total_of(expected) in [nil, total]

        {{:error, %Error{} = error}, expected} ->
          assert error.status == expected.status

          assert Jason.decode!(Jason.encode!(Error.to_body(error))) ==
                   Jason.decode!(expected.body)

        {{:ok, _total, body}, expected} ->
          flunk("expected #{expected.status} #{expected.body}, got rows #{body}")
      end
    end
  end

  # `Content-Range: 0-1/5` carries the exact total.
  defp total_of(%{headers: headers}) do
    case Regex.run(~r{/(\d+)$}, Map.get(headers, "content-range", "")) do
      [_, total] -> String.to_integer(total)
      _ -> nil
    end
  end
end
