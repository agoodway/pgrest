defmodule PgRest.Integration.Case do
  @moduledoc false
  # Serves the compat fixture tables through `PgRest.Compat.Router` on a random port and
  # hands the test a real `supabase_postgrest` client pointed at it. Tests that write send
  # `tx=rollback` (`PostgREST.rollback/1`) so the fixture keeps its seed state.
  use ExUnit.CaseTemplate

  alias PgRest.Compat.Resources
  alias PgRest.Integration.Router

  setup do
    registry = start_supervised!({PgRest.Registry, modules: Resources.all()})
    bandit = start_supervised!({Bandit, plug: Router, port: 0, ip: :loopback, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit)

    base_url = "http://localhost:#{port}"
    {:ok, client} = Supabase.init_client(base_url, "test-api-key", db: [schema: "test"])

    %{client: client, base_url: base_url, port: port, registry: registry}
  end
end
