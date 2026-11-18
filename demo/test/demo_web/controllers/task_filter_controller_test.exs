defmodule DemoWeb.TaskFilterControllerTest do
  use DemoWeb.ConnCase, async: true

  alias Demo.Repo
  alias Demo.Tasks.Task

  setup do
    Enum.each(
      [
        %{title: "Alpha", status: "pending", priority: "high", complexity: 5},
        %{title: "Beta", status: "completed", priority: "low", complexity: 1},
        %{title: "Gamma", status: "in_progress", priority: "low", complexity: 2},
        %{
          title: "Deleted",
          status: "pending",
          priority: "high",
          deleted_at: ~U[2026-01-01 00:00:00Z]
        }
      ],
      &Repo.insert!(struct!(Task, &1))
    )

    :ok
  end

  test "applies column filters and skips soft-deleted rows", %{conn: conn} do
    titles =
      conn
      |> get(~p"/ecto/tasks?status=in.(pending,in_progress)")
      |> json_response(200)
      |> titles()

    assert titles == ["Alpha", "Gamma"]
  end

  test "applies logic trees", %{conn: conn} do
    titles =
      conn
      |> get("/ecto/tasks?or=(priority.eq.high,complexity.lt.2)")
      |> json_response(200)
      |> titles()

    assert titles == ["Alpha", "Beta"]
  end

  test "returns a PostgREST-shaped error for an unknown column", %{conn: conn} do
    assert %{"code" => "42703", "message" => message} =
             conn |> get("/ecto/tasks?nope=eq.1") |> json_response(400)

    assert message =~ "nope"
  end

  test "returns a PostgREST-shaped error for an uncastable value", %{conn: conn} do
    assert %{"code" => "22P02"} =
             conn |> get("/ecto/tasks?complexity=eq.abc") |> json_response(400)
  end

  test "the REST API serves the same rows through PgRest.Plug", %{conn: conn} do
    titles =
      conn
      |> get("/api/tasks?status=in.(pending,in_progress)&order=id.asc")
      |> json_response(200)
      |> titles()

    assert titles == ["Alpha", "Gamma"]
  end

  test "the REST API rejects writes", %{conn: conn} do
    assert %{"code" => "42501"} =
             conn |> post("/api/tasks", %{"title" => "x"}) |> json_response(405)
  end

  defp titles(rows), do: Enum.map(rows, & &1["title"])
end
