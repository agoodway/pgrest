defmodule DemoWeb.TaskFilterController do
  @moduledoc """
  Filters tasks with PostgREST syntax on a plain Ecto query (`PgRest.Ecto.Filter`),
  the same grammar the `/api` routes accept.
  """
  use DemoWeb, :controller

  alias Demo.Tasks

  @doc "Lists tasks filtered by the PostgREST filters in the query string."
  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    case Tasks.list_filtered(params) do
      {:ok, tasks} ->
        json(conn, Enum.map(tasks, &Map.take(&1, [:id, :title, :status, :priority, :complexity])))

      {:error, %PgRest.Error{} = error} ->
        conn
        |> put_status(error.status)
        |> json(%{
          code: error.code,
          message: error.message,
          details: error.details,
          hint: error.hint
        })
    end
  end
end
