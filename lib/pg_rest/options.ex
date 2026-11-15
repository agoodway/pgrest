defmodule PgRest.Options do
  @moduledoc false
  @defaults [
    registry: PgRest.Registry,
    context_builder: nil,
    authorization: nil,
    require_filters_for_mutations: true,
    max_limit: nil,
    max_embed_depth: 8,
    max_body_bytes: 8_000_000,
    max_bulk_rows: 10_000,
    count_modes: [:exact, :planned, :estimated],
    tx_end: :commit,
    statement_cache: PgRest.StatementCache.defaults(),
    statement_timeout: nil,
    aggregates: false,
    plan_enabled: false,
    rls: nil,
    anonymous?: &PgRest.Auth.default_anonymous?/2
  ]

  @doc "Default plug options shared by initialization, requests and planning."
  @spec defaults() :: keyword()
  def defaults, do: @defaults

  @doc "The default value for one plug option."
  @spec default(atom()) :: term()
  def default(key), do: Keyword.fetch!(@defaults, key)

  @doc "Validates the supported transaction-end modes."
  @spec validate_tx_end!(term()) :: :ok
  def validate_tx_end!(value) when value in [:commit, :commit_allow_override], do: :ok

  def validate_tx_end!(value),
    do: raise(ArgumentError, "invalid PgRest.Plug option :tx_end: #{inspect(value)}")

  @doc "Whether a loaded module exports a callback."
  @spec exports?(term(), atom(), non_neg_integer()) :: boolean()
  def exports?(module, function, arity),
    do:
      is_atom(module) and Code.ensure_loaded?(module) and
        function_exported?(module, function, arity)

  @doc "Logs once per key, or once per generation in a reusable slot."
  @spec log_once(term(), (-> term())) :: :ok
  def log_once(key, fun) do
    {slot, value} = log_slot(key)

    unless :persistent_term.get(slot, false) == value do
      :persistent_term.put(slot, value)
      fun.()
    end

    :ok
  end

  defp log_slot({:generation, key, generation}), do: {key, generation}
  defp log_slot(key), do: {key, true}

  # Shared checks for the option lists PgRest's modules validate at startup or compile time.

  @doc """
  Raises `ArgumentError, "unknown <label> options: [...]"` when `opts` has a key outside
  `allowed`.
  """
  @spec validate_keys!(keyword(), [atom()], String.t()) :: :ok
  def validate_keys!(opts, allowed, label) do
    case Keyword.keys(opts) -- allowed do
      [] -> :ok
      unknown -> raise ArgumentError, "unknown #{label} options: #{inspect(unknown)}"
    end
  end

  @doc "Whether `value` is a list of strings."
  @spec strings?(term()) :: boolean()
  def strings?(value), do: is_list(value) and Enum.all?(value, &is_binary/1)
end
