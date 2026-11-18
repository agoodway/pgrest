defmodule Demo.Tasks do
  @moduledoc """
  Task queries that reuse PostgREST filter syntax on plain Ecto queries through
  `PgRest.Ecto.Filter`, without going through `PgRest.Plug`.
  """

  import Ecto.Query, only: [from: 2, order_by: 2]

  alias Demo.Repo
  alias Demo.Tasks.Task
  alias PgRest.Ecto.Filter
  alias PgRest.Grammar.Filter, as: Grammar

  @logic_keys ~w(and or not.and not.or)

  @doc """
  Lists live tasks narrowed by PostgREST filters such as `status=in.(pending,in_progress)`
  or `or=(priority.eq.high,complexity.lt.3)`.

  Returns `{:error, %PgRest.Error{}}` for an unknown column or an uncastable value.
  """
  @spec list_filtered(%{optional(String.t()) => String.t()}) ::
          {:ok, [struct()]} | {:error, PgRest.Error.t()}
  def list_filtered(params) do
    with {:ok, nodes} <- parse_nodes(params),
         {:ok, query} <- Filter.where(from(t in Task, where: is_nil(t.deleted_at)), nodes) do
      {:ok, query |> order_by(asc: :id) |> Repo.all()}
    end
  end

  defp parse_nodes(params) do
    params
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {key, value}, {:ok, nodes} ->
      case parse_node(key, value) do
        {:ok, node} -> {:cont, {:ok, [node | nodes]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, nodes} -> {:ok, Enum.reverse(nodes)}
      error -> error
    end)
  end

  defp parse_node(key, value) when key in @logic_keys, do: Grammar.parse_logic(key, value)
  defp parse_node(key, value), do: Grammar.parse_condition(key, value)
end
