defmodule PgRest.Application do
  @moduledoc false
  # Starts the node-wide owner of PgRest's shared ETS caches (`PgRest.Cache`), so the caches
  # outlive any one `PgRest.Registry`.

  use Application

  @impl Application
  def start(_type, _args) do
    Supervisor.start_link([PgRest.Cache], strategy: :one_for_one, name: PgRest.Supervisor)
  end
end
