defmodule PgRest.GeneratedChangeTest do
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [json: 1, register: 1]

  alias PgRest.Compat.Repo
  alias PgRest.Test.WriteResources.GeneratedSecret

  @merge {"prefer", "resolution=merge-duplicates"}

  setup do
    register([GeneratedSecret])
    on_exit(fn -> Repo.query!("DELETE FROM test.accounts WHERE id >= 900") end)
    :ok
  end

  defp call(method, path, body, headers \\ []) do
    headers
    |> Enum.reduce(Plug.Test.conn(method, path, Jason.encode!(body)), fn {k, v}, c ->
      Plug.Conn.put_req_header(c, k, v)
    end)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> PgRest.Plug.call(PgRest.Plug.init(repo: Repo))
  end

  defp password(id),
    do: Repo.query!("SELECT hashed_password FROM test.accounts WHERE id = $1", [id]).rows

  test "a generated change to a redacted field is written on POST" do
    assert call("POST", "/accounts", %{"id" => 900, "email" => "g@x"}).status == 201
    assert password(900) == [["generated"]]
  end

  test "a generated change to a redacted field is written on PATCH" do
    Repo.query!(
      "INSERT INTO test.accounts (id, email, hashed_password) VALUES (901, 'p@x', 'old')"
    )

    assert call("PATCH", "/accounts?id=eq.901", %{"email" => "q@x"}).status == 204
    assert password(901) == [["generated"]]
  end

  test "a generated change to a redacted field is written on upsert merge" do
    Repo.query!(
      "INSERT INTO test.accounts (id, email, hashed_password) VALUES (902, 'm@x', 'old')"
    )

    conn = call("POST", "/accounts", %{"id" => 902, "email" => "n@x"}, [@merge])
    assert conn.status in [200, 201]
    assert password(902) == [["generated"]]
  end

  test "columns= naming a redacted column is 42501" do
    conn =
      call("POST", "/accounts?columns=id,hashed_password", %{
        "id" => 904,
        "hashed_password" => "h"
      })

    assert conn.status == 401
    assert %{"code" => "42501"} = json(conn)
  end

  test "supplying the redacted key directly is still 42501" do
    conn = call("POST", "/accounts", %{"id" => 903, "email" => "s@x", "hashed_password" => "h"})

    assert conn.status == 401
    assert %{"code" => "42501"} = json(conn)
  end
end
