defmodule PgRest.StatementCache do
  @moduledoc """
  Promotes hot SQL texts to named prepared statements.

  A node-wide ETS table (owned by `PgRest.Cache`) counts how often each SQL text
  is executed, keyed by SQL text and database role (SHA-256). After `promote_after`
  sightings the text is promoted. Later executions carry
  `cache_statement: "pgrest_<32 hex chars>"`, so Postgrex prepares it once per connection.
  At most `max` texts are promoted
  node-wide; once the cap is reached other texts stay unnamed, with no eviction churn.
  Request-controlled aliases and select shapes can mint unlimited SQL texts, so the cap
  is what bounds server-side prepared statements: settled promotions never exceed `max`.
  Concurrent claims can briefly overshoot the counter, and a claim that loses is rolled
  back (see `confirm/3`); a caller that read the loser's name in that window prepares one
  extra statement on its connection, so the transient excess is bounded by the number of
  concurrent callers, never by the number of distinct texts. The sightings table is bounded
  too: whenever a caller finds it above `10 * max` entries, the counters of unpromoted texts
  are cleared.

  The cap and the table are node-wide: every `PgRest.Plug` instance on the node shares them,
  and the first instance's `max` that fills the cap wins. The cap holds per lifetime of the
  table's owner: a restarted `PgRest.Cache` starts an empty table (and a fresh count), while
  connections keep the statements they already prepared.

  Without the table (the `:pgrest` application is not started) nothing is promoted, and a
  warning is logged once.

  Role partitions share the same node-wide bound. Prepared plans may fold or inline
  privileged functions, so a statement prepared for one role must never be reused by
  another role on the same connection.

  With `statement_cache: false` nothing is promoted.

  ## Differences from PostgREST

  Prepared statements are partitioned by database role. PostgREST v14.18 can
  reuse a privileged role's folded function result for anon after plan caching.
  """

  alias PgRest.Options

  require Logger

  @table __MODULE__
  @defaults [promote_after: 3, max: 500]

  @type config :: keyword() | false | nil

  @doc "The default `statement_cache` configuration."
  @spec defaults() :: keyword()
  def defaults, do: @defaults

  @doc false
  # Only `PgRest.Cache` calls this, so it owns the table. Idempotent: an existing table is left
  # alone.
  @spec create_table() :: :ok
  def create_table do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    :ets.insert(@table, {:promoted, 0})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Repo options for executing `sql`: `[cache_statement: name]` once the text is
  promoted, `[]` otherwise.
  """
  @spec query_opts(String.t(), config(), String.t() | nil) :: keyword()
  def query_opts(sql, config, role \\ nil)
  def query_opts(_sql, false, _role), do: []
  def query_opts(sql, nil, role), do: query_opts(sql, @defaults, role)

  # Without the table (its owner is down or restarting) nothing is promoted; a table that
  # disappears mid-lookup is the same case.
  def query_opts(sql, config, role) when is_binary(sql) do
    if :ets.whereis(@table) == :undefined,
      do: missing_table(),
      else: lookup(sql, Keyword.merge(@defaults, config), role)
  rescue
    ArgumentError -> []
  end

  # A host that does not start the `:pgrest` application runs every statement unnamed; say so
  # once per node.
  defp missing_table do
    key = {__MODULE__, :warned_missing_table}

    Options.log_once(key, fn ->
      Logger.warning(
        "PgRest.StatementCache has no table (is the :pgrest application started?); " <>
          "statements run unnamed"
      )
    end)

    []
  end

  defp lookup(sql, config, role) do
    hash = :crypto.hash(:sha256, cache_key(sql, role))

    case :ets.lookup(@table, {:named, hash}) do
      [{_key, name}] -> [cache_statement: name]
      [] -> sighted(hash, config)
    end
  end

  defp cache_key(sql, nil), do: sql
  defp cache_key(sql, role), do: :erlang.term_to_binary({sql, role})

  defp sighted(hash, config) do
    count = :ets.update_counter(@table, hash, 1, {hash, 0})

    if count > config[:promote_after], do: promote(hash, config), else: unnamed(config)
  end

  # A capped cache is detected by a plain read of the settled counter, so there is no
  # permanent flag to set wrongly and no write contention once the cap is reached.
  defp promote(hash, config) do
    if :ets.lookup_element(@table, :promoted, 2) >= config[:max],
      do: unnamed(config),
      else: claim(hash, config)
  end

  # Claims the text with `insert_new/2` before counting it, so concurrent first sightings
  # of one text count once (the loser just reads the winner's name). A claim that pushes the
  # counter over the cap is deleted again, and the text is retried on a later sighting.
  defp claim(hash, config) do
    case reserve(hash) do
      {:ok, name} -> confirm(hash, name, config)
      {:taken, name} -> [cache_statement: name]
    end
  end

  @doc false
  # Step 1 of a promotion: put the name entry in the table. `{:taken, name}` when another
  # caller already claimed the text.
  @spec reserve(binary()) :: {:ok | :taken, String.t()}
  def reserve(hash) do
    name = "pgrest_" <> binary_part(Base.encode16(hash, case: :lower), 0, 32)
    if :ets.insert_new(@table, {{:named, hash}, name}), do: {:ok, name}, else: {:taken, name}
  end

  @doc false
  # Step 2: count the claim. Over the cap, step 3 rolls it back (the entry is deleted and
  # the counter decremented). Between steps 1 and 3 the rejected name is visible, so a
  # concurrent lookup may use it once; that only prepares one extra statement transiently.
  @spec confirm(binary(), String.t(), keyword()) :: keyword()
  def confirm(hash, name, config) do
    if :ets.update_counter(@table, :promoted, 1) > config[:max] do
      :ets.delete(@table, {:named, hash})
      :ets.update_counter(@table, :promoted, -1)
      unnamed(config)
    else
      [cache_statement: name]
    end
  end

  defp unnamed(config) do
    if :ets.info(@table, :size) > 10 * config[:max] do
      :ets.select_delete(@table, [{{:"$1", :_}, [{:is_binary, :"$1"}], [true]}])
    end

    []
  end
end
