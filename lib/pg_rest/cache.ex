defmodule PgRest.Cache do
  @moduledoc """
  Owns the node-wide ETS caches every `PgRest.Plug` and `PgRest.Registry` share: the
  compiled scoped SQL (`PgRest.SQL.ScopedSource`) and the prepared-statement promotion
  table (`PgRest.StatementCache`).

  The `:pgrest` application supervises it, independently of any registry, so starting,
  stopping or restarting registries never drops or duplicates the caches. Both tables are
  created idempotently. When the owner is not running (the application is not started, or the
  owner is restarting), readers fall back without error: scoped SQL compiles uncached and
  statements stay unnamed.
  """

  use GenServer

  alias PgRest.SQL.ScopedSource
  alias PgRest.StatementCache

  @doc false
  @spec start_link(term()) :: GenServer.on_start()
  def start_link(_arg), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def init(:ok) do
    :ok = ScopedSource.create_cache()
    :ok = StatementCache.create_table()

    # The tables are created only here; another owner would drop them when it exits.
    for table <- [ScopedSource.cache_table(), StatementCache] do
      unless :ets.info(table, :owner) == self(),
        do: raise(ArgumentError, "#{inspect(table)} is owned by another process")
    end

    {:ok, %{}}
  end
end
