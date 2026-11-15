defmodule PgRest.PutTest do
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [header: 2, json: 1, register: 1, request: 5]

  alias PgRest.Compat.{Repo, Resources}
  alias PgRest.Test.SQLResources.Where, as: ScopedProject
  alias PgRest.Test.TelemetryProbe
  alias PgRest.Test.WriteResources.{Changesets, More}

  @rep "return=representation"
  @roll "tx=rollback"

  defp put(path, body, prefer \\ @rep, opts \\ []) do
    plug_opts = Keyword.merge([tx_end: :commit_allow_override], opts)
    request("PUT", path, body, [{"prefer", prefer}], plug_opts)
  end

  defp client(id), do: [context_builder: fn _conn, _opts -> %{client_id: id} end]
  defp admin, do: [context_builder: fn _conn, _opts -> %{client_id: 1, admin?: true} end]

  defp project(id),
    do: Repo.query!("SELECT name, client_id FROM test.projects WHERE id = $1", [id]).rows

  defp insert_sql do
    for {[:pgrest, :query, :stop], _m, %{sql: sql} = meta} <- TelemetryProbe.drain(),
        String.contains?(sql, "INSERT INTO"),
        do: meta
  end

  describe "ownership-safe PUT over a scope" do
    setup do
      register([ScopedProject])
      :ok
    end

    test "putting a row of another client is 42501 and leaves it unchanged" do
      conn =
        put(
          "/projects?id=eq.3",
          %{"id" => 3, "name" => "stolen", "client_id" => 1},
          @rep,
          client(1)
        )

      assert conn.status == 401

      assert %{
               "code" => "42501",
               "message" => "new row violates row-level security policy for table \"projects\""
             } =
               json(conn)

      assert project(3) == [["IOS", 2]]
    end

    test "a new in-scope row is 201" do
      conn =
        put(
          "/projects?id=eq.900",
          %{"id" => 900, "name" => "n", "client_id" => 1},
          @rep <> ", " <> @roll,
          client(1)
        )

      assert conn.status == 201
      assert json(conn) == [%{"id" => 900, "name" => "n", "client_id" => 1}]
      assert header(conn, "content-range") == nil
    end

    test "updating an own row is 200 with a representation and 204 minimal" do
      body = %{"id" => 1, "name" => "Renamed", "client_id" => 1}

      assert (rep = put("/projects?id=eq.1", body, @rep <> ", " <> @roll, client(1))).status ==
               200

      assert json(rep) == [body]
      assert header(rep, "preference-applied") == "return=representation, tx=rollback"

      min = put("/projects?id=eq.1", body, "return=minimal, " <> @roll, client(1))
      assert min.status == 204
      assert min.resp_body == ""
      assert header(min, "preference-applied") == "return=minimal, tx=rollback"
    end

    test "a new row that leaves the scope fails the post-write check and persists nothing" do
      conn =
        put(
          "/projects?id=eq.901",
          %{"id" => 901, "name" => "n", "client_id" => 2},
          @rep,
          client(1)
        )

      assert conn.status == 401
      assert %{"code" => "42501"} = json(conn)
      assert project(901) == []
    end

    test "an own row moved out of the scope fails the post-write check" do
      conn =
        put(
          "/projects?id=eq.1",
          %{"id" => 1, "name" => "moved", "client_id" => 2},
          @rep,
          client(1)
        )

      assert conn.status == 401

      assert %{
               "code" => "42501",
               "message" => "new row violates row-level security policy for table \"projects\""
             } =
               json(conn)

      assert project(1) == [["Windows 7", 1]]
    end

    test "the guard is a correlated EXISTS, never IN (SELECT" do
      TelemetryProbe.attach([:pgrest, :query, :stop])

      put("/projects?id=eq.1", %{"id" => 1, "name" => "x"}, @roll, client(1))

      assert [%{sql: sql}] = insert_sql()
      assert sql =~ "DO UPDATE SET"
      assert sql =~ "WHERE EXISTS (SELECT 1 FROM ("
      refute sql =~ " IN (SELECT"
    end

    test "EXPLAIN of the statement probes the key index inside the conflict filter" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      row = %{"id" => 1, "name" => "x"}
      put("/projects?id=eq.1", row, @roll, client(1))

      assert [%{sql: sql, params_count: 4}] = insert_sql()

      result =
        Repo.transaction(fn ->
          Repo.query!("""
          INSERT INTO test.projects SELECT g, 'p' || g, 1 FROM generate_series(10000, 19999) g
          """)

          Repo.query!("ANALYZE test.projects")
          plan = Repo.query!("EXPLAIN " <> sql, [Jason.encode!(row), 1, "id", "1"]).rows
          Repo.rollback(Enum.map_join(plan, "\n", &hd/1))
        end)

      assert {:error, plan} = result
      assert plan =~ "Conflict Filter"
      assert plan =~ "Index Cond"
      refute plan =~ "hashed SubPlan"
    end

    test "constraint details are scrubbed over a scope" do
      body = %{"id" => 1, "name" => String.duplicate("x", 101), "client_id" => 1}
      conn = put("/projects?id=eq.1", body, @rep, client(1))

      assert conn.status == 400
      assert %{"code" => "23514", "details" => nil} = json(conn)
    end
  end

  describe "PUT over an identity scope" do
    setup do
      register([ScopedProject])
      :ok
    end

    test "has no ownership guard and keeps constraint details" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      body = %{"id" => 3, "name" => String.duplicate("x", 101), "client_id" => 2}
      conn = put("/projects?id=eq.3", body, @rep, admin())

      assert conn.status == 400
      assert %{"code" => "23514", "details" => "Failing row contains " <> _} = json(conn)
      assert [%{sql: sql}] = insert_sql()
      refute sql =~ "EXISTS"
    end

    test "writes a row of another client" do
      body = %{"id" => 3, "name" => "taken", "client_id" => 1}
      assert put("/projects?id=eq.3", body, @rep <> ", " <> @roll, admin()).status == 200
    end
  end

  describe "authorization" do
    setup do
      register(Resources.all())
      :ok
    end

    test "PUT needs :read as well as :create and :update" do
      for prefer <- [@rep, "return=minimal"] do
        conn =
          put("/projects?id=eq.1", %{"id" => 1, "name" => "x"}, prefer,
            authorization: More.DenyProjects
          )

        assert conn.status == 401

        assert %{"code" => "42501", "message" => "permission denied for table projects"} =
                 json(conn)

        assert project(1) == [["Windows 7", 1]]
      end
    end
  end

  describe "payload and URL" do
    setup do
      register(Resources.all())
      :ok
    end

    test "a payload missing a key column is PGRST115" do
      conn = put("/compound_pk?k1=eq.1&k2=eq.2", %{"k1" => 1})

      assert conn.status == 400
      assert %{"code" => "PGRST115"} = json(conn)
    end

    test "the array element matching the URL is the one written" do
      body = [%{"name" => "Swift", "rank" => 12}, %{"name" => "Java", "rank" => 19}]
      conn = put("/tiobe_pls?name=eq.Java", body, @rep <> ", " <> @roll)

      assert conn.status == 200
      assert json(conn) == [%{"name" => "Java", "rank" => 19}]
    end

    test "an array with no matching element is PGRST115" do
      conn = put("/tiobe_pls?name=eq.Java", [%{"name" => "Swift", "rank" => 12}])
      assert %{"code" => "PGRST115"} = json(conn)
    end

    test "no element is written when none matches, or a bad one follows the miss" do
      for body <- [
            [%{"name" => "Zig", "rank" => 3}],
            [%{"name" => "Zig", "rank" => 3}, %{"name" => "Rust", "rank" => "x"}]
          ] do
        conn = put("/tiobe_pls?name=eq.Go", body)
        assert conn.status == 400
      end

      assert Repo.query!("SELECT count(*) FROM test.tiobe_pls WHERE name IN ('Zig', 'Go')").rows ==
               [[0]]
    end

    test "two matching elements are a 400 and write nothing" do
      body = [%{"name" => "Java", "rank" => 19}, %{"name" => "Java", "rank" => 20}]
      conn = put("/tiobe_pls?name=eq.Java", body)

      assert conn.status == 400
      assert %{"code" => "PGRST102", "message" => "PUT takes one row" <> _} = json(conn)
      assert Repo.query!("SELECT rank FROM test.tiobe_pls WHERE name = 'Java'").rows == [[1]]
    end

    test "the key is compared typed, as the column reads it" do
      for {query, body} <- [{"id=eq.01", %{"id" => 1}}, {"id=eq.1", %{"id" => "01"}}] do
        conn = put("/only_pk?" <> query, body, @rep <> ", " <> @roll)
        assert conn.status == 200, query
        assert json(conn) == [%{"id" => 1}]
      end
    end

    test "a key value the column cannot read is 22P02" do
      for {query, value} <- [{"id=eq.1", 1.0}, {"id=eq.1", true}, {"id=eq.x", "x"}] do
        conn = put("/only_pk?" <> query, %{"id" => value})
        assert conn.status == 400

        assert %{"code" => "22P02", "message" => "invalid input syntax for type integer: " <> _} =
                 json(conn)
      end
    end

    test "every element is read by Postgres, and none is written unless it is the one" do
      for {body, code} <- [
            {[%{"name" => "Java", "rank" => 1}, %{"name" => "Rust", "bogus" => 2}], "PGRST102"},
            {[%{"name" => "Java", "rank" => 1}, 5], "PGRST102"},
            {[%{"name" => "Java", "rank" => 1}, %{"name" => "Rust", "rank" => "x"}], "22P02"}
          ] do
        conn = put("/tiobe_pls?name=eq.Java", body)
        assert conn.status == 400
        assert %{"code" => ^code} = json(conn)
      end

      assert Repo.query!("SELECT rank FROM test.tiobe_pls WHERE name = 'Java'").rows == [[1]]
    end

    test "limit and offset are PGRST114" do
      for query <- ["limit=1", "offset=1"] do
        conn = put("/tiobe_pls?name=eq.Go&" <> query, %{"name" => "Go"})
        assert conn.status == 400
        assert %{"code" => "PGRST114"} = json(conn)
      end
    end

    test "on_conflict, resolution and missing=default do not apply" do
      prefer = "resolution=ignore-duplicates, missing=default, " <> @rep <> ", " <> @roll

      conn =
        put("/tiobe_pls?name=eq.Java&on_conflict=rank", %{"name" => "Java", "rank" => 7}, prefer)

      assert conn.status == 200
      assert json(conn) == [%{"name" => "Java", "rank" => 7}]
    end

    test "a table without a primary key is PGRST105" do
      conn = put("/no_pk?a=eq.one&b=eq.two", %{"a" => "one", "b" => "two"})

      assert conn.status == 405
      assert %{"code" => "PGRST105"} = json(conn)
    end

    test "a filter that is not a bare eq on every key column is PGRST105" do
      for query <- [
            "rank=eq.1",
            "name=neq.Java",
            "name=not.eq.Java",
            "name=in.(Java)",
            "and=(name.eq.Java)",
            "name=eq.Java&rank=eq.1",
            ""
          ] do
        conn = put("/tiobe_pls?" <> query, %{"name" => "Java"})
        assert conn.status == 405, query
        assert %{"code" => "PGRST105"} = json(conn)
      end
    end

    test "a PUT is not bounded by max-affected" do
      prefer = "handling=strict, max-affected=0, " <> @rep <> ", " <> @roll

      assert put("/tiobe_pls?name=eq.Java", %{"name" => "Java", "rank" => 5}, prefer).status ==
               200
    end
  end

  describe "the written columns are the supplied ones" do
    setup do
      register([Changesets.Forced | Resources.all() -- [Resources.ComplexItems]])
      :ok
    end

    test "an explicit null is written" do
      conn =
        put(
          "/complex_items?id=eq.1&select=id,name",
          %{"id" => 1, "name" => nil},
          @rep <> ", " <> @roll
        )

      assert conn.status == 200
      assert json(conn) == [%{"id" => 1, "name" => nil}]
    end

    test "a value equal to the struct default is written by the default changeset path" do
      conn =
        put(
          ~s|/complex_items?id=eq.1&select=id,"field-with_sep"|,
          %{"id" => 1, "field-with_sep" => 0},
          @rep <> ", " <> @roll
        )

      assert conn.status == 200
      assert json(conn) == [%{"id" => 1, "field-with_sep" => 0}]
    end

    test "a custom changeset runs on every element of a PUT array, not only the matched one" do
      conn =
        put(
          "/complex_items?id=eq.1&select=id,name",
          [
            %{"id" => 1, "name" => "ok", "field-with_sep" => 0},
            %{"id" => 2, "name" => "ok", "field-with_sep" => 150}
          ],
          @rep <> ", " <> @roll
        )

      assert conn.status == 400
      assert %{"code" => "23514", "details" => "sep: must be less than 100"} = json(conn)
    end
  end
end
