defmodule PgRest.AuthorizationScopeTest do
  use ExUnit.Case, async: false
  alias PgRest.Compat.{JWT, Scenario, SupabaseScopeRouter}

  setup_all do
    Enum.each(Scenario.registries(), &start_supervised!/1)

    start_supervised!(
      {PgRest.Registry, name: __MODULE__.Plain, modules: [PgRest.Compat.Supabase.RlsNote]}
    )

    :ok
  end

  test "scope-mode constraint errors hide details, identity mode retains them" do
    for body <- [
          %{owner: "alice", slug: "new-check", body: String.duplicate("x", 101)},
          %{owner: "alice", slug: "a1", body: "duplicate"}
        ] do
      conn =
        Plug.Test.conn(:post, "/rls_notes", Jason.encode!(body))
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header(
          "authorization",
          "Bearer " <> JWT.sign(%{"role" => "authenticated", "sub" => "alice"})
        )
        |> Plug.Conn.put_req_header("prefer", "tx=rollback")

      scoped = SupabaseScopeRouter.call(conn, [])
      assert scoped.status in [400, 409]
      assert Jason.decode!(scoped.resp_body)["details"] == nil

      plain =
        PgRest.Plug.call(
          conn,
          PgRest.Plug.init(repo: PgRest.Compat.SupabaseRepo, registry: __MODULE__.Plain, rls: nil)
        )

      assert plain.status in [400, 409]
      assert is_binary(Jason.decode!(plain.resp_body)["details"])
    end
  end
end
