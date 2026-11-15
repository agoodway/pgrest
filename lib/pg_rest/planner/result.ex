defmodule PgRest.Planner.Result do
  @moduledoc """
  Helpers for planner steps that run over a list and stop at the first error.
  """

  @doc """
  Maps `fun` (returning `{:ok, value} | {:error, error}`) over `enum`: `{:ok, values}` in
  order, or the first error.
  """
  @spec map_ok(Enumerable.t(), (term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, list()} | {:error, term()}
  def map_ok(enum, fun) do
    enum
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} -> prepend(fun.(item), acc) end)
    |> reverse()
  end

  defp prepend({:ok, value}, acc), do: {:cont, {:ok, [value | acc]}}
  defp prepend({:error, _} = error, _acc), do: {:halt, error}

  defp reverse({:ok, acc}), do: {:ok, Enum.reverse(acc)}
  defp reverse({:error, _} = error), do: error

  @doc """
  Folds `fun` (returning `{:ok, acc} | {:error, error}`) over `enum`, stopping at the
  first error.
  """
  @spec reduce_ok(Enumerable.t(), term(), (term(), term() -> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def reduce_ok(enum, acc, fun) do
    Enum.reduce_while(enum, {:ok, acc}, fn item, {:ok, acc} -> continue(fun.(item, acc)) end)
  end

  defp continue({:ok, acc}), do: {:cont, {:ok, acc}}
  defp continue({:error, _} = error), do: {:halt, error}

  @doc "Runs `fun` (returning `:ok | {:error, error}`) on each item: `:ok`, or the first error."
  @spec all_ok(Enumerable.t(), (term() -> :ok | {:error, term()})) :: :ok | {:error, term()}
  def all_ok(enum, fun) do
    Enum.reduce_while(enum, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
