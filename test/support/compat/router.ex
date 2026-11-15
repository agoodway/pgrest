defmodule PgRest.Compat.Router do
  @moduledoc """
  Test router that forwards every request to `PgRest.Plug` against
  `PgRest.Compat.Repo`, merging per-scenario plug options.

  Scenario options travel in `conn.private[:pgrest_compat_plug_opts]`. The other compat
  routers (`PgRest.Compat.SupabaseRouter`) share `dispatch/2`.
  """

  @behaviour Plug

  @base_opts [
    repo: PgRest.Compat.Repo,
    tx_end: :commit_allow_override,
    aggregates: true,
    plan_enabled: true
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: dispatch(conn, @base_opts)

  @doc "Runs `PgRest.Plug` with `base_opts` overlaid by the scenario's plug options."
  @spec dispatch(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def dispatch(conn, base_opts) do
    scenario_opts = Map.get(conn.private, :pgrest_compat_plug_opts, [])

    PgRest.Plug.call(conn, PgRest.Plug.init(Keyword.merge(base_opts, scenario_opts)))
  end
end
