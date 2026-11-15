defmodule PgRest.Compat.RpcCommitTest do
  use ExUnit.Case, async: false

  alias PgRest.Compat.{Repo, Scenario}

  @moduletag :differential

  setup_all do
    Enum.each(Scenario.registries(), &start_supervised!/1)
    :ok
  end

  test "singular failures leave rows intact in both engine orders under commit" do
    before = Repo.query!("SELECT id FROM test.items ORDER BY id").rows

    for order <- [[:pgrest, :postgrest], [:postgrest, :pgrest]],
        scenario <- Scenario.load("rpc_commit"),
        engine <- order do
      assert %{status: 406, body: body} = Scenario.run_isolated(engine, scenario)
      assert %{"code" => "PGRST116"} = Jason.decode!(body)
      assert Repo.query!("SELECT id FROM test.items ORDER BY id").rows == before
    end
  end
end
