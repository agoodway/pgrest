defmodule PgRest.UpsertTest do
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [json: 1, register: 1]

  alias PgRest.Compat.{Repo, Resources}
  alias PgRest.{Request, Write}
  alias PgRest.SQL.Write, as: SQLWrite
  alias PgRest.Test.{TelemetryProbe, WriteResources}
  alias PgRest.Test.WriteResources.More

  @merge {"prefer", "resolution=merge-duplicates, return=representation, tx=rollback"}
  @ignore {"prefer", "resolution=ignore-duplicates, return=representation, tx=rollback"}

  defp post(path, body, opts \\ [], headers \\ [@merge]) do
    plug_opts = Keyword.merge([repo: Repo, tx_end: :commit_allow_override], opts)

    headers
    |> Enum.reduce(Plug.Test.conn("POST", path, Jason.encode!(body)), fn {k, v}, c ->
      Plug.Conn.put_req_header(c, k, v)
    end)
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> PgRest.Plug.call(PgRest.Plug.init(plug_opts))
  end

  defp events do
    for {[:pgrest, :query, :stop], _m, meta} <- TelemetryProbe.drain(), do: meta
  end

  defp row(id),
    do: Repo.query!("SELECT to_jsonb(a) FROM test.accounts a WHERE id = $1", [id]).rows

  defp rows_text(sql), do: sql |> Repo.query!() |> Map.fetch!(:rows)

  @alice_row %{"id" => 1, "email" => "alice@example.com", "role" => "user"}

  describe "merge sets only the payload columns" do
    setup do
      register(Resources.all())
      :ok
    end

    test "a partial payload leaves the other columns intact" do
      conn = post("/projects?select=id,name,client_id", %{"id" => 3, "name" => "Renamed"})

      assert conn.status == 200
      assert json(conn) == [%{"id" => 3, "name" => "Renamed", "client_id" => 2}]
    end

    test "the statement lists exactly the payload columns in DO UPDATE SET" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      post("/projects", %{"id" => 3, "name" => "Renamed"})

      assert [%{sql: sql}] = Enum.filter(events(), &String.contains?(&1.sql, "INSERT INTO"))
      assert sql =~ ~s|DO UPDATE SET "id" = EXCLUDED."id", "name" = EXCLUDED."name" WHERE|
      refute sql =~ "client_id\" = EXCLUDED"
    end

    test "a bulk upsert is one statement with one parameter" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      rows = for id <- 1..1000, do: %{"id" => id + 1000, "name" => "n#{id}"}

      assert post("/projects", rows, [], [{"prefer", "resolution=merge-duplicates, tx=rollback"}]).status ==
               201

      assert [%{params_count: 1}] =
               Enum.filter(events(), &String.contains?(&1.sql, "INSERT INTO"))
    end
  end

  describe "ownership-safe conflicts" do
    setup do
      register([WriteResources.ScopedAccounts])
      on_exit(fn -> Repo.query!("UPDATE test.accounts SET owner_id = 'owner-1' WHERE id = 1") end)
      :ok
    end

    defp bob_hijack do
      %{"id" => 2, "email" => "bob@example.com", "role" => "user", "owner_id" => "owner-1"}
    end

    test "upserting one of Bob's rows is a 42501 and leaves it untouched" do
      before = row(2)
      conn = post("/accounts", bob_hijack())

      assert conn.status == 401
      assert %{"code" => "42501"} = json(conn)
      assert row(2) == before
    end

    test "the same without tx=rollback persists nothing" do
      before = row(2)
      conn = post("/accounts", bob_hijack(), [], [{"prefer", "resolution=merge-duplicates"}])

      assert conn.status == 401
      assert row(2) == before
    end

    test "a bulk upsert mixing an own row and one of Bob's writes nothing" do
      own = row(1)
      before = row(2)

      rows = [
        %{
          "id" => 1,
          "email" => "alice@example.com",
          "role" => "admin",
          "owner_id" => "owner-1"
        },
        bob_hijack()
      ]

      conn = post("/accounts", rows, [], [{"prefer", "resolution=merge-duplicates"}])

      assert conn.status == 401
      assert row(1) == own
      assert row(2) == before
    end

    test "a bulk upsert of own rows only, and a new row, passes" do
      rows = [
        %{"id" => 1, "email" => "alice@example.com", "role" => "admin", "owner_id" => "owner-1"},
        %{"id" => 900, "email" => "n@x", "role" => "user", "owner_id" => "owner-1"}
      ]

      conn = post("/accounts?select=id,role&order=id", rows)

      assert conn.status == 201
      assert json(conn) == [%{"id" => 1, "role" => "admin"}, %{"id" => 900, "role" => "user"}]
    end

    test "two concurrent upserts on the same out-of-scope key both get 42501" do
      before = row(2)

      tasks =
        for _ <- 1..2,
            do:
              Task.async(fn ->
                post("/accounts", bob_hijack(), [], [{"prefer", "resolution=merge-duplicates"}])
              end)

      for conn <- Task.await_many(tasks, 10_000) do
        assert conn.status == 401
        assert %{"code" => "42501"} = json(conn)
      end

      assert row(2) == before
    end

    test "ignore on a scoped conflict returns no row and changes nothing" do
      before = row(2)
      conn = post("/accounts", bob_hijack(), [], [@ignore])

      assert conn.status == 201
      assert json(conn) == []
      assert row(2) == before
    end

    test "P-H4: the conflict guard is a correlated EXISTS, never IN (SELECT" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      post("/accounts", Map.put(bob_hijack(), "owner_id", "owner-1"))

      assert [%{sql: sql}] = Enum.filter(events(), &String.contains?(&1.sql, "INSERT INTO"))
      assert sql =~ "WHERE EXISTS (SELECT 1"
      refute sql =~ "IN (SELECT"
    end

    test "P-H4: EXPLAIN shows no hashed SubPlan in the Conflict Filter at 10 000 scoped rows" do
      {:ok, request} =
        Request.from_conn(Plug.Test.conn("POST", "/accounts", ~s|{"id":1}|), [])

      config = WriteResources.ScopedAccounts.__pgrest_config__()

      {:ok, plan} =
        Write.plan(
          request,
          config,
          %{repo: Repo, authorization: nil, graph: PgRest.Registry.graph()},
          false
        )

      {sql, params} =
        SQLWrite.insert(
          WriteResources.ScopedAccounts,
          {:raw, ~s|{"id":1,"role":"x"}|, ["id", "role"]},
          repo: Repo,
          on_conflict: %{
            target: ["id"],
            action: :merge,
            guard: %{plan: plan, key: [{"id", "id"}]}
          }
        )

      result =
        Repo.transaction(fn ->
          Repo.query!("""
          INSERT INTO test.accounts
          SELECT g, 'e' || g, 'h', 'user', 'owner-1' FROM generate_series(10000, 19999) g
          """)

          Repo.query!("ANALYZE test.accounts")
          plan_text = Repo.query!("EXPLAIN " <> sql, params).rows |> Enum.map_join("\n", &hd/1)
          Repo.rollback(plan_text)
        end)

      assert {:error, plan_text} = result
      assert plan_text =~ "Conflict Filter"
      assert plan_text =~ "Index Cond"
      refute plan_text =~ "hashed SubPlan"
    end
  end

  describe "S-L1: the guard reads the statement snapshot" do
    setup do
      register([WriteResources.ScopedAccounts])
      on_exit(fn -> Repo.query!("UPDATE test.accounts SET owner_id = 'owner-1' WHERE id = 1") end)
      :ok
    end

    # Waits until some backend is blocked by `blocker`, this test's own transaction (a lock
    # waiter of another test does not count).
    defp wait_for_lock(_blocker, 0), do: false

    defp wait_for_lock(blocker, tries) do
      %{rows: [[waiting]]} =
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
          [blocker]
        )

      if waiting > 0 do
        true
      else
        Process.sleep(20)
        wait_for_lock(blocker, tries - 1)
      end
    end

    # T1 moves Alice's row to Bob and holds the row lock; the upsert starts and blocks on
    # it; T1 commits; the upsert's result is returned.
    defp race(payload) do
      parent = self()

      t1 =
        Task.async(fn ->
          Repo.transaction(fn ->
            Repo.query!("UPDATE test.accounts SET owner_id = 'owner-2' WHERE id = 1")
            %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()")
            send(parent, {:locked, pid})

            receive do
              :commit -> :ok
            after
              10_000 -> Repo.rollback(:timeout)
            end
          end)
        end)

      assert_receive {:locked, blocker}, 5_000

      upsert =
        Task.async(fn ->
          post("/accounts?select=id,role,owner_id", payload, [], [@merge])
        end)

      assert wait_for_lock(blocker, 50), "the upsert should be blocked on the row lock"
      assert Task.yield(upsert, 0) == nil
      send(t1.pid, :commit)
      assert {:ok, _} = Task.await(t1, 10_000)
      Task.await(upsert, 10_000)
    end

    test "a payload without the ownership column is caught by the post-write check" do
      conn = race(%{"id" => 1, "role" => "admin"})

      assert conn.status == 401
      assert %{"code" => "42501"} = json(conn)
      assert [[%{"owner_id" => "owner-2", "role" => "user"}]] = row(1)
    end

    test "a payload that sets the ownership column takes the row back (documented race)" do
      conn = race(@alice_row |> Map.put("owner_id", "owner-1") |> Map.put("role", "admin"))

      assert conn.status == 200
      assert [%{"id" => 1, "role" => "admin", "owner_id" => "owner-1"}] = json(conn)
      # The request rolled back (tx=rollback), so Bob's committed change stays.
      assert [[%{"owner_id" => "owner-2"}]] = row(1)
    end
  end

  describe "fix round 1" do
    setup do
      on_exit(fn ->
        Repo.query!("DELETE FROM test.compound_pk")
        Repo.query!("UPDATE test.accounts SET owner_id = 'owner-1' WHERE id = 1")
      end)

      :ok
    end

    test "a scoped merge whose representation drops a row (!inner embed) is not a 42501" do
      register([More.SClients, More.SProjects])

      rows = [
        %{"id" => 1, "name" => "x", "client_id" => 1},
        %{"id" => 100, "name" => "y", "client_id" => nil}
      ]

      conn = post("/projects?select=id,client!inner(id)&order=id", rows)

      assert conn.status == 201
      assert json(conn) == [%{"id" => 1, "client" => %{"id" => 1}}]
    end

    test "an upsert changeset sees operation :upsert" do
      register([More.Conditional])
      opts = [context_builder: fn _conn, _opts -> %{report_to: self()} end]

      post("/clients", %{"id" => 5}, opts, [
        {"prefer", "resolution=merge-duplicates, tx=rollback"}
      ])

      assert_receive {:changeset, :upsert}

      post("/clients", %{"id" => 5}, opts, [{"prefer", "tx=rollback"}])
      assert_receive {:changeset, :create}
    end

    test "an upsert whose rows generate different columns is a 400 PGRST102" do
      register([More.Conditional])
      rows = [%{"id" => 1}, %{"id" => 2}]

      conn = post("/clients", rows, [], [@merge])

      assert conn.status == 400
      assert %{"code" => "PGRST102", "message" => "All object keys must match"} = json(conn)
    end

    test "on_conflict names an unknown or non-readable column: 42703, no SQL" do
      register([WriteResources.ScopedAccounts])
      TelemetryProbe.attach([:pgrest, :query, :stop])

      for name <- ["nope", "hashed_password"] do
        conn = post("/accounts?on_conflict=" <> name, bob_row())

        assert conn.status == 400
        assert %{"code" => "42703", "message" => message} = json(conn)
        assert message == ~s|column "#{name}" does not exist|
      end

      assert events() == []
    end

    defp bob_row,
      do: %{"id" => 70, "email" => "bob@example.com", "role" => "user", "owner_id" => "owner-1"}

    test "a scoped merge with on_conflict=email targeting Bob's row is a 42501" do
      register([WriteResources.ScopedAccounts])
      before = row(2)

      conn = post("/accounts?on_conflict=email", bob_row())

      assert conn.status == 401
      assert %{"code" => "42501"} = json(conn)
      assert row(2) == before
    end

    test "a scoped composite-key resource guards the conflicting row" do
      register([More.ScopedCompound])
      Repo.query!("INSERT INTO test.compound_pk VALUES (1, 'a', 1), (2, 'b', 2)")

      out = post("/compound_pk", %{"k1" => 2, "k2" => "b", "extra" => 1})

      assert out.status == 401
      assert %{"code" => "42501"} = json(out)
      assert rows_text("SELECT extra FROM test.compound_pk WHERE k1 = 2") == [[2]]

      own = post("/compound_pk", %{"k1" => 1, "k2" => "a", "extra" => 1})
      assert own.status == 200
    end

    test "a scoped unique_key resource guards the conflicting row" do
      register([More.UniqueKeyed])
      before = row(2)

      conn = post("/accounts?on_conflict=email", bob_row())

      assert conn.status == 401
      assert %{"code" => "42501"} = json(conn)
      assert row(2) == before
    end
  end

  describe "authorization (S-H1)" do
    setup do
      register(Resources.all())
      :ok
    end

    test "create and update without read: minimal succeeds, representation and count are denied" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      opts = [authorization: WriteResources.CreateOnly]
      before = rows_text("SELECT count(*) FROM test.items")
      merge = "resolution=merge-duplicates"

      for prefer <- ["#{merge}, return=representation", "#{merge}, count=exact"] do
        conn = post("/items", %{"id" => 1}, opts, [{"prefer", prefer <> ", tx=rollback"}])
        assert conn.status == 401
        assert %{"code" => "42501"} = json(conn)
      end

      assert events() == []
      assert rows_text("SELECT count(*) FROM test.items") == before

      conn = post("/items", %{"id" => 1}, opts, [{"prefer", merge <> ", tx=rollback"}])
      assert conn.status == 200
    end

    test "merge needs :update, ignore does not" do
      defmodule NoUpdate do
        def authorize(_conn, _resource, :update, _context), do: {:error, "no"}
        def authorize(_conn, _resource, _operation, _context), do: :ok
      end

      opts = [authorization: NoUpdate]

      conn = post("/items", %{"id" => 1}, opts, [@merge])
      assert conn.status == 401
      assert %{"code" => "42501"} = json(conn)

      assert post("/items", %{"id" => 1}, opts, [@ignore]).status == 201
    end
  end
end
