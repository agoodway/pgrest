defmodule PgRest.PlannerColdTest do
  # Sync: it empties the global catalog caches and counts repo queries.
  use ExUnit.Case

  import Plug.Test

  alias PgRest.{Catalog, Error, Planner, Request, SchemaGraph}
  alias PgRest.Compat.Repo
  alias PgRest.Compat.Resources, as: R

  defmodule Deny do
    @moduledoc false
    def authorize(_conn, resource, :read, %{denied: denied}),
      do: if(resource in denied, do: {:error, "no"}, else: :ok)
  end

  @event [:pg_rest, :compat, :repo, :query]
  @graph SchemaGraph.build(R.all())

  def handle(_event, _measure, _meta, test), do: send(test, :repo_query)

  defp plan(path, context) do
    {:ok, request} = Request.from_conn(conn("GET", path), [])
    Planner.plan_read(request, R.Clients, Map.merge(%{repo: Repo, graph: @graph}, context))
  end

  defp cold, do: Catalog.forget(Repo)

  defp queries(fun) do
    id = {__MODULE__, make_ref()}
    :telemetry.attach(id, @event, &__MODULE__.handle/4, self())

    try do
      fun.()
      drain(0)
    after
      :telemetry.detach(id)
    end
  end

  defp drain(count) do
    receive do
      :repo_query -> drain(count + 1)
    after
      0 -> count
    end
  end

  test "a denied request issues no repo query on a cold catalog cache" do
    cold()
    context = %{authorization: Deny, denied: [R.Projects]}

    assert 0 ==
             queries(fn ->
               assert {:error, %Error{code: "42501"}} =
                        plan("/clients?select=id,projects(id)", context)
             end)
  end

  test "control: an allowed request on a cold cache does query the catalog" do
    cold()
    assert queries(fn -> assert {:ok, _} = plan("/clients?select=id", %{}) end) >= 1
  end
end
