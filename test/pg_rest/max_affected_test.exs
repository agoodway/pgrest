defmodule PgRest.MaxAffectedTest do
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [header: 2, json: 1, request: 5]

  alias PgRest.Compat.{Functions, Repo, Resources}
  alias PgRest.Test.TelemetryProbe

  @strict {"prefer", "handling=strict, max-affected=2"}
  @lenient {"prefer", "handling=lenient, max-affected=2, tx=rollback"}
  @rollback {"prefer", "handling=strict, max-affected=3, tx=rollback"}

  setup do
    start_supervised!(
      {PgRest.Registry,
       modules: Resources.all(), introspect: [repo: Repo, only: Functions.test_functions()]}
    )

    :ok
  end

  defp call(method, path, body, headers),
    do: request(method, path, body, headers, tx_end: :commit_allow_override)

  defp names, do: Repo.query!("SELECT name FROM test.projects ORDER BY id").rows
  defp item_count, do: Repo.query!("SELECT count(*) FROM test.items").rows

  describe "PATCH" do
    test "strict over the limit is PGRST124 and leaves the rows unchanged" do
      before = names()
      conn = call("PATCH", "/projects?id=lte.3", %{"name" => "Renamed"}, [@strict])

      assert conn.status == 400

      assert json(conn) == %{
               "code" => "PGRST124",
               "message" => "Query result exceeds max-affected preference constraint",
               "details" => "The query affects 3 rows",
               "hint" => nil
             }

      assert header(conn, "preference-applied") == nil
      assert names() == before
    end

    test "lenient ignores max-affected and does not echo it" do
      conn = call("PATCH", "/projects?id=lte.3", %{"name" => "Renamed"}, [@lenient])

      assert conn.status == 204
      assert header(conn, "preference-applied") == "tx=rollback, handling=lenient"
    end

    test "strict at the limit succeeds and echoes max-affected" do
      conn = call("PATCH", "/projects?id=lte.3", %{"name" => "Renamed"}, [@rollback])

      assert conn.status == 204
      assert header(conn, "preference-applied") == "tx=rollback, handling=strict, max-affected=3"
    end

    test "strict over the limit rolls back what a trigger wrote to other rows" do
      # `test.stuff` is a view whose INSTEAD OF UPDATE trigger rewrites every row of
      # `private.stuff` and sets `response.status`.
      stuff = fn -> Repo.query!("SELECT id, name FROM private.stuff ORDER BY id").rows end
      before = stuff.()
      strict = {"prefer", "handling=strict, max-affected=0"}

      conn = call("PATCH", "/stuff?id=eq.1", %{"name" => "renamed"}, [strict])

      assert conn.status == 400
      assert %{"code" => "PGRST124", "details" => "The query affects 1 rows"} = json(conn)
      assert stuff.() == before
    end

    test "strict bounds the rows written, not the rows an aggregating select= returns" do
      before = names()

      conn =
        request(
          "PATCH",
          "/projects?id=lte.3&select=count()",
          %{"name" => "Renamed"},
          [{"prefer", "handling=strict, max-affected=2, return=representation"}],
          tx_end: :commit_allow_override,
          aggregates: true
        )

      assert conn.status == 400
      assert %{"code" => "PGRST124", "details" => "The query affects 3 rows"} = json(conn)
      assert names() == before
    end

    test "the statement runs once" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      call("PATCH", "/projects?id=lte.3", %{"name" => "Renamed"}, [@rollback])

      writes =
        for {[:pgrest, :query, :stop], _m, %{sql: sql}} <- TelemetryProbe.drain(),
            String.contains?(sql, "UPDATE"),
            do: sql

      assert length(writes) == 1
    end
  end

  describe "DELETE" do
    test "strict over the limit is PGRST124 and deletes nothing" do
      conn = call("DELETE", "/items?id=lt.5", nil, [@strict])

      assert conn.status == 400
      assert %{"code" => "PGRST124", "details" => "The query affects 4 rows"} = json(conn)
      assert item_count() == [[15]]
    end
  end

  describe "RPC" do
    test "strict max-affected on a function that returns no set is PGRST128" do
      conn = call("POST", "/rpc/add_them", %{"a" => 1, "b" => 2}, [@strict])

      assert conn.status == 400

      assert json(conn) == %{
               "code" => "PGRST128",
               "message" =>
                 "Function must return SETOF or TABLE when max-affected preference is used with handling=strict",
               "details" => nil,
               "hint" => nil
             }
    end

    test "strict over the limit on a set-returning function is PGRST124" do
      conn = call("GET", "/rpc/getallprojects", nil, [@strict])

      assert conn.status == 400
      assert %{"code" => "PGRST124", "details" => "The query affects 5 rows"} = json(conn)
    end

    test "a volatile call rejected as not singular rolls its side effects back" do
      object = {"accept", "application/vnd.pgrst.object+json"}
      before = item_count()

      conn = call("POST", "/rpc/delete_items_returns_setof", nil, [object])
      assert conn.status == 406
      assert %{"code" => "PGRST116"} = json(conn)
      assert item_count() == before
    end

    test "singularity is checked before max-affected, as PostgREST orders them" do
      object = {"accept", "application/vnd.pgrst.object+json"}
      before = item_count()

      conn = call("POST", "/rpc/delete_items_returns_setof", nil, [object, @strict])
      assert %{"code" => "PGRST116", "details" => "The result contains 15 rows"} = json(conn)
      assert item_count() == before
    end

    test "a volatile call over max-affected rolls back under commit" do
      before = item_count()

      conn = call("POST", "/rpc/delete_items_returns_setof", nil, [@strict])
      assert %{"code" => "PGRST124"} = json(conn)
      assert item_count() == before
    end

    test "lenient ignores a function that returns no set" do
      conn = call("POST", "/rpc/add_them", %{"a" => 1, "b" => 2}, [@lenient])
      assert conn.status == 200
    end
  end
end
