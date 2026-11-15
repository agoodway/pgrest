defmodule PgRest.UpdateDeleteTest do
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [header: 2, json: 1, register: 1]

  alias PgRest.Compat.{Repo, Resources}
  alias PgRest.PlugCase
  alias PgRest.Test.{TelemetryProbe, WriteResources}
  alias PgRest.Test.WriteResources.{Changesets, Mutations}

  @rollback {"prefer", "tx=rollback"}
  @rep {"prefer", "return=representation, tx=rollback"}

  defp call(method, path, body, opts, headers) do
    plug_opts = Keyword.merge([repo: Repo, tx_end: :commit_allow_override], opts)

    conn =
      Enum.reduce(headers, Plug.Test.conn(method, path, body && Jason.encode!(body)), fn {k, v},
                                                                                         c ->
        Plug.Conn.put_req_header(c, k, v)
      end)

    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> PgRest.Plug.call(PgRest.Plug.init(plug_opts))
  end

  defp patch(path, body, opts \\ [], headers \\ [@rollback]),
    do: call("PATCH", path, body, opts, headers)

  defp delete(path, opts \\ [], headers \\ [@rollback]),
    do: call("DELETE", path, nil, opts, headers)

  defp events do
    for {[:pgrest, :query, :stop], _m, meta} <- TelemetryProbe.drain(), do: meta
  end

  defp rows(sql), do: Repo.query!(sql).rows
  defp account(id), do: rows("SELECT to_jsonb(a) FROM test.accounts a WHERE id = #{id}")

  describe "identity scope (PostgREST's shape)" do
    setup do
      register(Resources.all())
      :ok
    end

    test "PATCH is 204 with Content-Range and no body" do
      conn = patch("/clients?id=eq.1", %{"name" => "Renamed"})

      assert conn.status == 204
      assert conn.resp_body == ""
      assert header(conn, "content-range") == "0-0/*"
      assert header(conn, "preference-applied") == "tx=rollback"
      assert rows("SELECT name FROM test.clients WHERE id = 1") == [["Microsoft"]]
    end

    test "PATCH with no match is 204 */*; return=representation is [] with 200" do
      conn = patch("/clients?id=eq.999", %{"name" => "x"})
      assert {conn.status, header(conn, "content-range")} == {204, "*/*"}

      conn = patch("/clients?id=eq.999", %{"name" => "x"}, [], [@rep])
      assert conn.status == 200
      assert json(conn) == []
    end

    test "PATCH return=representation honours select and order" do
      conn = patch("/clients?id=gt.0&select=id,name&order=id.desc", %{"name" => "z"}, [], [@rep])

      assert conn.status == 200
      assert json(conn) == [%{"id" => 2, "name" => "z"}, %{"id" => 1, "name" => "z"}]
      assert header(conn, "content-range") == "0-1/*"
    end

    test "count=exact fills the Content-Range total" do
      conn =
        patch("/clients?id=gt.0", %{"name" => "z"}, [], [
          {"prefer", "count=exact, tx=rollback"}
        ])

      assert header(conn, "content-range") == "0-1/2"

      conn = delete("/clients?id=eq.999", [], [{"prefer", "count=exact, tx=rollback"}])
      assert header(conn, "content-range") == "*/0"
    end

    test "DELETE is 204 with Content-Range */*; representation returns the rows" do
      conn = delete("/projects?id=eq.5")
      assert {conn.status, header(conn, "content-range")} == {204, "*/*"}

      conn = delete("/projects?id=eq.5&select=id,name", [], [@rep])
      assert conn.status == 200
      assert json(conn) == [%{"id" => 5, "name" => "Orphan"}]
      assert rows("SELECT count(*) FROM test.projects WHERE id = 5") == [[1]]
    end

    test "a filter on a column the PATCH also sets still returns the row" do
      conn =
        patch(
          "/clients?or=(name.like.*Micro*,name.is.null)&select=id,name",
          %{"name" => "Other"},
          [],
          [
            @rep
          ]
        )

      assert json(conn) == [%{"id" => 1, "name" => "Other"}]
    end

    test "P0 #1: a typo in a filter is a 400 and nothing changes" do
      for conn <- [patch("/items?idd=eq.1", %{"id" => 99}), delete("/items?idd=eq.1")] do
        assert conn.status == 400
        assert %{"code" => "42703"} = json(conn)
      end

      assert rows("SELECT count(*) FROM test.items") == [[15]]
    end

    test "PK-less tables work (UpdateSpec 122-143)" do
      conn = patch("/no_pk?b=eq.0", %{"b" => "1"}, [], [@rep])
      assert conn.status == 200
      assert header(conn, "content-range") == "0-1/*"
      assert json(conn) |> Enum.map(& &1["a"]) |> Enum.sort() == ["1", "2"]

      conn = delete("/no_pk?a=eq.1", [], [@rep])
      assert json(conn) == [%{"a" => "1", "b" => "0"}]
      assert rows("SELECT count(*) FROM test.no_pk") == [[3]]
    end

    test "PATCH {name: null} sets NULL; {} and [] touch nothing" do
      conn = patch("/complex_items?id=eq.1&select=id,name", %{"name" => nil}, [], [@rep])
      assert json(conn) == [%{"id" => 1, "name" => nil}]

      for body <- [%{}, []] do
        conn = patch("/clients?id=eq.1", body, [], [@rep])
        assert conn.status == 200
        assert json(conn) == []
        assert header(conn, "content-range") == "*/*"
      end

      assert patch("/clients?id=eq.1", %{}).status == 204
    end

    test "columns= limits the keys written" do
      conn = patch("/clients?id=eq.1&columns=name", %{"name" => "A", "id" => 55}, [], [@rep])
      assert json(conn) == [%{"id" => 1, "name" => "A"}]

      conn = patch("/clients?id=eq.1&columns=helicopter", %{"name" => "A"})
      assert %{"code" => "PGRST204"} = json(conn)
    end

    test "a payload array of several objects is a 400" do
      conn = patch("/clients?id=eq.1", [%{"name" => "a"}, %{"name" => "b"}])
      assert conn.status == 400
      assert %{"code" => "PGRST102"} = json(conn)
    end

    test "a single-object Accept needs exactly one row (406, rolled back)" do
      single = {"accept", "application/vnd.pgrst.object+json"}

      conn = patch("/clients?id=gt.0", %{"name" => "z"}, [], [@rep, single])
      assert conn.status == 406
      assert %{"code" => "PGRST116"} = json(conn)

      conn = delete("/projects?id=eq.5", [], [@rep, single])
      assert conn.status == 200
      assert json(conn) == %{"id" => 5, "name" => "Orphan", "client_id" => nil}
    end

    test "P-H3: an enum column is set from request text" do
      conn = patch("/type_cases?id=eq.1&select=id,status", %{"status" => "archived"}, [], [@rep])

      assert conn.status == 200
      assert json(conn) == [%{"id" => 1, "status" => "archived"}]
    end

    test "missing=default resets an absent column named in columns=" do
      conn =
        patch(
          "/complex_items?id=eq.3&columns=name,field-with_sep&select=id,name,field-with_sep",
          %{"name" => "N"},
          [],
          [{"prefer", "missing=default, return=representation, tx=rollback"}]
        )

      assert json(conn) == [%{"id" => 3, "name" => "N", "field-with_sep" => 1}]
      assert header(conn, "preference-applied") =~ "missing=default"
    end
  end

  describe "require_filters_for_mutations" do
    setup do
      register(Resources.all())
      :ok
    end

    test "defaults to on: no filter is a 400 21000 and nothing changes" do
      conn = patch("/clients", %{"name" => "x"})
      assert conn.status == 400

      assert %{"code" => "21000", "message" => "UPDATE requires a WHERE clause"} = json(conn)

      conn = delete("/clients")
      assert %{"code" => "21000", "message" => "DELETE requires a WHERE clause"} = json(conn)
      assert rows("SELECT count(*) FROM test.clients") == [[2]]
    end

    test "a filter that is only a logic tree satisfies it" do
      assert patch("/clients?or=(id.eq.1,id.eq.2)", %{"name" => "x"}).status == 204
      assert delete("/no_pk?not.and=(a.eq.1,b.eq.0)").status == 204
    end

    test "limit, order and select are not filters" do
      assert patch("/clients?limit=1&order=id", %{"name" => "x"}).status == 400
    end

    test "false lets an unfiltered request through" do
      assert patch("/clients", %{"name" => "x"}, require_filters_for_mutations: false).status ==
               204

      conn = delete("/no_pk", [require_filters_for_mutations: false], [@rep])
      assert conn.status == 200
      assert length(json(conn)) == 3
    end

    test "an update that sets nothing needs no filter" do
      assert patch("/clients", %{}).status == 204
    end

    test "invalid options are rejected" do
      assert_raise ArgumentError, fn ->
        PgRest.Plug.init(repo: Repo, require_filters_for_mutations: :maybe)
      end
    end
  end

  describe "changesets" do
    test "validate_required errors are dropped for fields the payload does not supply" do
      register([Mutations.RequiredName])

      conn = patch("/clients?id=eq.1&select=id,name", %{"name" => "N"}, [], [@rep])
      assert conn.status == 200
      assert json(conn) == [%{"id" => 1, "name" => "N"}]

      conn = patch("/clients?id=eq.1", %{"id" => 1}, [], [@rep])
      assert conn.status == 200
    end

    test "a required field supplied as null is a 400" do
      register([Mutations.RequiredName])

      conn = patch("/clients?id=eq.1", %{"name" => nil})
      assert conn.status == 400
      assert %{"code" => "23514", "details" => details} = json(conn)
      assert details =~ "name: can't be blank"
    end

    test "the changeset sees operation :update" do
      register([Mutations.RequiredName])
      opts = [context_builder: fn _conn, _opts -> %{report_to: self()} end]

      patch("/clients?id=eq.1", %{"name" => "N"}, opts)
      assert_receive {:changeset, :update}
    end

    test "a change the changeset adds is written" do
      register([Mutations.Stamping])

      conn = patch("/defaults_demo?id=eq.1&select=id,label,note", %{"label" => "L"}, [], [@rep])
      assert json(conn) == [%{"id" => 1, "label" => "L", "note" => "stamped"}]
    end

    test "explicit null, zero and the empty string are written, not dropped" do
      register([Mutations.Literal])

      conn =
        patch(
          "/complex_items?id=eq.3&select=id,name,field-with_sep",
          %{"field-with_sep" => 0, "name" => ""},
          [],
          [@rep]
        )

      assert json(conn) == [%{"id" => 3, "name" => "", "field-with_sep" => 0}]

      conn = patch("/complex_items?id=eq.3&select=id,name", %{"name" => nil}, [], [@rep])
      assert json(conn) == [%{"id" => 3, "name" => nil}]
    end

    test "a changeset error that is not :required is a 400" do
      register([WriteResources.Counting])

      conn = patch("/complex_items?id=eq.1", %{"name" => String.duplicate("x", 30)})
      assert conn.status == 400
      assert %{"code" => "23514"} = json(conn)
    end
  end

  describe "authorization (S-H1)" do
    setup do
      register([WriteResources.PlainAccounts])
      TelemetryProbe.attach([:pgrest, :query, :stop])
      %{opts: [authorization: Mutations.ReadDenied]}
    end

    test "filters are a read channel: update without read is 42501 before SQL", %{opts: opts} do
      before = account(1)

      for headers <- [
            [{"prefer", "return=minimal, tx=rollback"}],
            [@rep],
            [{"prefer", "count=exact, tx=rollback"}]
          ] do
        conn = patch("/accounts?email=like.a*", %{"role" => "admin"}, opts, headers)
        assert conn.status == 401
        assert %{"code" => "42501"} = json(conn)
      end

      conn = delete("/accounts?id=eq.1", opts)
      assert conn.status == 401
      assert %{"code" => "42501"} = json(conn)

      assert Enum.filter(events(), &String.contains?(&1.sql, "accounts")) == []
      assert account(1) == before
    end

    test "unfiltered, return=minimal needs only the operation", %{opts: opts} do
      opts = Keyword.put(opts, :require_filters_for_mutations, false)

      conn = patch("/accounts", %{"role" => "user"}, opts)
      assert conn.status == 204
      assert Enum.any?(events(), &String.contains?(&1.sql, "UPDATE"))
    end

    test "operations asked of the hook", %{} do
      opts = [
        authorization: Mutations.Recording,
        context_builder: fn _c, _o -> %{report_to: self()} end
      ]

      patch("/accounts?id=eq.1", %{"role" => "user"}, opts)
      assert_received {:authorize, WriteResources.PlainAccounts, :update}
      assert_received {:authorize, WriteResources.PlainAccounts, :read}

      delete("/accounts?id=eq.1", opts)
      assert_received {:authorize, WriteResources.PlainAccounts, :delete}
    end
  end

  describe "column exposure (S-M2)" do
    setup do
      register(Resources.all())
      :ok
    end

    test "a redacted column cannot be written or filtered" do
      conn = patch("/accounts?id=eq.1", %{"hashed_password" => "x"})
      assert conn.status == 401
      assert %{"code" => "42501"} = json(conn)

      conn = patch("/accounts?hashed_password=eq.x", %{"role" => "user"})
      assert conn.status == 401

      conn = delete("/accounts?hashed_password=eq.hash-alice")
      assert conn.status == 401
      assert account(1) != []
    end
  end

  describe "scoped resources" do
    setup do
      register([WriteResources.ScopedAccounts])
      on_exit(fn -> Repo.query!("UPDATE test.accounts SET owner_id = 'owner-1' WHERE id = 1") end)
      :ok
    end

    test "PATCH goes through the scope with FOR UPDATE and only touches in-scope rows" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      conn = patch("/accounts?id=gt.0&select=id,role&order=id", %{"role" => "admin"}, [], [@rep])

      assert json(conn) == [%{"id" => 1, "role" => "admin"}, %{"id" => 3, "role" => "admin"}]
      assert [%{sql: sql}] = Enum.filter(events(), &String.contains?(&1.sql, "UPDATE"))
      assert sql =~ "FOR UPDATE"
      assert sql =~ ~s|IN (SELECT s."id" FROM|
      refute sql =~ "public"
    end

    test "Bob's row is invisible to PATCH and DELETE" do
      before = account(2)

      conn = patch("/accounts?id=eq.2", %{"role" => "admin"}, [], [@rep])
      assert json(conn) == []

      conn = delete("/accounts?id=eq.2", [], [@rep])
      assert json(conn) == []
      assert account(2) == before
    end

    test "moving a row out of the scope is a 42501 and rolls back" do
      conn =
        patch("/accounts?id=eq.1", %{"owner_id" => "owner-2"}, [], [{"prefer", "return=minimal"}])

      assert conn.status == 401
      assert %{"code" => "42501"} = json(conn)
      assert [[%{"owner_id" => "owner-1"}]] = account(1)
    end

    test "S-H5: details are scrubbed on constraint errors" do
      conn = patch("/accounts?id=eq.1", %{"role" => "root"})
      assert conn.status == 400
      assert %{"code" => "23514", "details" => nil} = json(conn)

      conn = patch("/accounts?id=eq.1", %{"email" => "bob@example.com"})
      assert conn.status == 409
      assert %{"code" => "23505", "details" => nil} = json(conn)
    end
  end

  describe "S-H5 on the identity scope" do
    test "an unrestricted identity resource keeps the details" do
      register([Resources.Clients, Resources.Projects])

      conn = patch("/projects?id=eq.1", %{"client_id" => 999})
      assert conn.status == 409
      assert %{"code" => "23503", "details" => details} = json(conn)
      assert details =~ "client_id"
    end
  end

  describe "tx=rollback" do
    setup do
      register(Resources.all())
      on_exit(fn -> Repo.query!("UPDATE test.clients SET name = 'Microsoft' WHERE id = 1") end)
      :ok
    end

    test "S-L2: under :commit the preference is ignored, not echoed, and the write commits" do
      conn = patch("/clients?id=eq.1", %{"name" => "Committed"}, [tx_end: :commit], [@rollback])

      assert conn.status == 204
      assert header(conn, "preference-applied") == nil
      assert rows("SELECT name FROM test.clients WHERE id = 1") == [["Committed"]]
    end

    test "S-L2: under :commit_allow_override it rolls back and is echoed" do
      conn = patch("/clients?id=eq.1", %{"name" => "Gone"})

      assert header(conn, "preference-applied") == "tx=rollback"
      assert rows("SELECT name FROM test.clients WHERE id = 1") == [["Microsoft"]]
    end
  end

  describe "S-L1: concurrent change of ownership" do
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

    # T1 moves Alice's row to Bob and holds the lock; `request` starts and blocks; T1 commits.
    defp race(request) do
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
      task = Task.async(request)
      assert wait_for_lock(blocker, 50), "the request should be blocked on the row lock"
      assert Task.yield(task, 0) == nil
      send(t1.pid, :commit)
      assert {:ok, _} = Task.await(t1, 10_000)
      Task.await(task, 10_000)
    end

    test "PATCH re-checks the scope after the lock and updates nothing" do
      conn =
        race(fn -> patch("/accounts?id=eq.1&select=id", %{"role" => "admin"}, [], [@rep]) end)

      assert conn.status == 200
      assert json(conn) == []
      assert [[%{"owner_id" => "owner-2", "role" => "user"}]] = account(1)
    end

    test "DELETE re-checks the scope after the lock and deletes nothing" do
      conn = race(fn -> delete("/accounts?id=eq.1&select=id", [], [@rep]) end)

      assert conn.status == 200
      assert json(conn) == []
      assert [[%{"owner_id" => "owner-2"}]] = account(1)
    end
  end

  describe "keys and composite primary keys" do
    test "a scoped composite-key resource is updated through its whole key" do
      register([WriteResources.More.ScopedCompound])
      on_exit(fn -> Repo.query!("DELETE FROM test.compound_pk") end)

      Repo.query!("INSERT INTO test.compound_pk VALUES (1, 'a', 1), (1, 'b', 2), (2, 'a', 1)")

      conn =
        patch("/compound_pk?k1=eq.1&select=k1,k2,extra&order=k2", %{"extra" => 1}, [], [@rep])

      assert json(conn) == [%{"k1" => 1, "k2" => "a", "extra" => 1}]

      conn = delete("/compound_pk?k1=gt.0&select=k1,k2&order=k1,k2", [], [@rep])
      assert json(conn) == [%{"k1" => 1, "k2" => "a"}, %{"k1" => 2, "k2" => "a"}]
    end

    test "a renamed primary key field is addressed by its source column" do
      register([WriteResources.More.RenamedKey])

      on_exit(fn ->
        Repo.query!("UPDATE test.accounts SET email = 'alice@example.com' WHERE id = 1")
      end)

      conn =
        patch("/accounts?id=eq.1&select=id,email", %{"email" => "a2@example.com"}, [], [
          @rep
        ])

      assert json(conn) == [%{"id" => 1, "email" => "a2@example.com"}]
    end
  end

  describe "embedded parameters never select silently" do
    setup do
      register(Resources.all())
      TelemetryProbe.attach([:pgrest, :query, :stop])
      :ok
    end

    test "PATCH and DELETE name no embed: 400 PGRST108, nothing changes, no statement" do
      for unsafe <- [true, false], opts = [require_filters_for_mutations: not unsafe] do
        for conn <- [
              patch("/projects?clients.id=eq.1", %{"name" => "x"}, opts),
              patch("/projects?id=lt.3&clients.name=eq.Nope", %{"name" => "x"}, opts),
              delete("/projects?id=gt.4&clients.id=eq.1", opts, [
                {"prefer", "count=exact, tx=rollback"}
              ])
            ] do
          assert conn.status == 400
          assert %{"code" => "PGRST108"} = json(conn)
        end
      end

      assert Enum.filter(events(), &String.contains?(&1.sql, "UPDATE")) == []
      assert Enum.filter(events(), &String.contains?(&1.sql, "DELETE")) == []
      assert rows("SELECT count(*) FROM test.projects WHERE name = 'x'") == [[0]]
    end

    test "embed=is.null with a representation is a column filter: 42703" do
      conn =
        patch("/projects?id=eq.1&select=id,clients(id)&clients=is.null", %{"name" => "x"}, [], [
          @rep
        ])

      assert conn.status == 400
      assert %{"code" => "42703"} = json(conn)
    end
  end

  describe "supplied-key mask" do
    setup do
      register([Mutations.Subset])
      on_exit(fn -> Repo.query!(~s|DELETE FROM test.complex_items WHERE id >= 50|) end)
      :ok
    end

    test "PATCH leaves an uncast key unchanged" do
      conn =
        patch(
          ~s|/complex_items?id=eq.3&select=id,name,field-with_sep|,
          %{"name" => "N", "field-with_sep" => 7},
          [],
          [@rep]
        )

      assert json(conn) == [%{"id" => 3, "name" => "N", "field-with_sep" => 3}]
    end

    test "POST of an uncast key gets the database default, not the struct default" do
      conn =
        call(
          "POST",
          "/complex_items?select=id,field-with_sep",
          %{"id" => 50, "name" => "n", "field-with_sep" => 7},
          [],
          [@rep]
        )

      assert conn.status == 201
      assert json(conn) == [%{"id" => 50, "field-with_sep" => 1}]
    end
  end

  test "a denied request never runs the user's changeset" do
    register([Mutations.RequiredName])

    opts = [
      authorization: Mutations.DenyClientsRead,
      context_builder: fn _conn, _opts -> %{report_to: self()} end
    ]

    conn = patch("/clients?id=eq.1&select=id", %{"name" => "N"}, opts, [@rep])
    assert conn.status == 401
    refute_received {:changeset, _}
  end

  describe "round 2" do
    setup do
      PlugCase.register(Resources.all())
      :ok
    end

    defp req(method, path, body, headers, opts \\ []),
      do: PlugCase.request(method, path, body, headers, [tx_end: :commit_allow_override] ++ opts)

    test "a dot inside a JSON key or a quoted column is a root filter, never an embed path" do
      before = rows("SELECT name FROM test.complex_items ORDER BY id")

      for unsafe? <- [true, false], method <- ["PATCH", "DELETE"] do
        opts = [require_filters_for_mutations: not unsafe?]
        body = if method == "PATCH", do: %{"name" => "mass"}
        conn = req(method, "/complex_items?settings-%3E%3E%22a.b%22=eq.zzz", body, [@rep], opts)

        assert conn.status == 200
        assert PlugCase.json(conn) == []
        assert header(conn, "content-range") == "*/*"
      end

      assert rows("SELECT name FROM test.complex_items ORDER BY id") == before
    end

    test "embedded logic trees are refused on mutations" do
      for path <- [
            "/projects?id=eq.1&clients.or=(id.eq.1)",
            "/projects?id=eq.1&clients.not.or=(id.eq.1)"
          ],
          headers <- [[@rollback], [@rep]] do
        conn = req("PATCH", path, %{"name" => "x"}, headers)
        assert conn.status == 400
        assert %{"code" => "PGRST100"} = PlugCase.json(conn)
      end
    end

    test "embedded limit and offset on a minimal mutation stay PGRST108" do
      conn = req("PATCH", "/projects?id=lt.3&clients.limit=1", %{"name" => "x"}, [@rollback])
      assert conn.status == 400
      assert %{"code" => "PGRST108"} = PlugCase.json(conn)

      conn = req("DELETE", "/projects?id=gt.4&clients.offset=1", nil, [@rollback])
      assert %{"code" => "PGRST108"} = PlugCase.json(conn)
    end
  end

  describe "the final changes are the write intent" do
    setup do
      on_exit(fn -> Repo.query!("DELETE FROM test.complex_items WHERE id >= 50") end)
      :ok
    end

    @merge {"prefer", "resolution=merge-duplicates, return=representation, tx=rollback"}

    defp post_rep(path, body, opts \\ []), do: call("POST", path, body, opts, [@rep])
    defp settings(id), do: rows("SELECT settings FROM test.complex_items WHERE id = #{id}")
    defp sep(id), do: rows(~s|SELECT "field-with_sep" FROM test.complex_items WHERE id = #{id}|)

    test "the default changeset forces changes: explicit default-equal values are changes" do
      attrs = %{"name" => "", "active" => false, "count" => 0, "note" => nil, "tags" => []}
      changeset = Changesets.Defaults.changeset(%Changesets.Defaults{}, attrs, %{})

      assert changeset.changes == %{name: "", active: false, count: 0, note: nil, tags: []}

      changeset = Changesets.Defaults.changeset(%Changesets.Defaults{}, %{"count" => 0}, %{})
      assert changeset.changes == %{count: 0}
    end

    test "without a custom changeset, explicit 0, null, \"\" and [] are written; absent keys are not" do
      register([Resources.ComplexItems])
      select = "select=id,name,tags,arr_data,field-with_sep"

      body = %{"id" => 50, "name" => "", "tags" => [], "field-with_sep" => 0}
      conn = post_rep("/complex_items?#{select}", body)
      assert conn.status == 201
      assert json(conn) == [Map.put(body, "arr_data", nil)]

      body = %{"name" => nil, "tags" => [], "field-with_sep" => 0}
      conn = patch("/complex_items?id=eq.3&#{select}", body, [], [@rep])
      assert json(conn) == [Map.merge(body, %{"id" => 3, "arr_data" => [1, 2, 3]})]

      body = %{"id" => 3, "name" => "", "tags" => [], "field-with_sep" => 0}
      conn = call("POST", "/complex_items?#{select}", body, [], [@merge])
      assert conn.status == 200
      assert json(conn) == [Map.put(body, "arr_data", [1, 2, 3])]
    end

    test "a custom changeset without force_changes does not write a default-equal value" do
      register([Mutations.Subset])

      conn =
        patch("/complex_items?id=eq.3&select=id,name", %{"name" => ""}, [], [@rep])

      assert json(conn) == []
      assert rows("SELECT name FROM test.complex_items WHERE id = 3") == [["Three"]]
    end

    test "with force_changes, default-equal values are written and validated" do
      register([Changesets.Forced])
      select = "select=id,name,tags,field-with_sep"

      body = %{"id" => 50, "name" => "", "tags" => ["t"], "field-with_sep" => 0}
      conn = post_rep("/complex_items?#{select}", body)
      assert conn.status == 201
      assert json(conn) == [%{body | "name" => nil}]

      conn =
        patch("/complex_items?id=eq.3&#{select}", %{"tags" => [], "field-with_sep" => 0}, [], [
          @rep
        ])

      assert json(conn) == [%{"id" => 3, "name" => "Three", "tags" => [], "field-with_sep" => 0}]

      conn = patch("/complex_items?id=eq.3", %{"field-with_sep" => 100})
      assert conn.status == 400
      assert %{"code" => "23514", "details" => "sep: must be less than 100"} = json(conn)
    end

    test "a cross-field validation sees both forced changes" do
      register([Changesets.Forced])

      conn = patch("/complex_items?id=eq.3", %{"name" => nil, "tags" => []})
      assert conn.status == 400
      assert %{"details" => "name: cannot be cleared with tags"} = json(conn)

      conn = post_rep("/complex_items", %{"id" => 50, "name" => "", "tags" => []})
      assert conn.status == 400
    end

    test "validate_number over a forced 0 is a 400; unforced, the 0 is not written" do
      register([Changesets.Positive])
      forced = [context_builder: fn _conn, _opts -> %{force?: true} end]

      conn = patch("/complex_items?id=eq.3", %{"field-with_sep" => 0}, forced)
      assert conn.status == 400
      assert %{"details" => "sep: must be greater than 0"} = json(conn)

      conn = post_rep("/complex_items", %{"id" => 50, "field-with_sep" => 0}, forced)
      assert conn.status == 400

      conn = patch("/complex_items?id=eq.3&select=id", %{"field-with_sep" => 0}, [], [@rep])
      assert json(conn) == []
      assert sep(3) == [[3]]

      conn =
        post_rep("/complex_items?select=id,field-with_sep", %{"id" => 50, "field-with_sep" => 0})

      assert json(conn) == [%{"id" => 50, "field-with_sep" => 1}]
    end

    test "an upsert whose rows drop a default-equal value only in some rows is a PGRST102" do
      rows = [%{"id" => 1, "name" => ""}, %{"id" => 2, "name" => "x"}]

      register([Mutations.Subset])
      conn = call("POST", "/complex_items?select=id,name", rows, [], [@merge])
      assert conn.status == 400
      assert %{"code" => "PGRST102"} = json(conn)
    end

    test "with force_changes, an upsert mixing \"\" and non-empty rows is uniform" do
      rows = [%{"id" => 1, "name" => ""}, %{"id" => 2, "name" => "x"}]
      register([Changesets.Forced])
      conn = call("POST", "/complex_items?select=id,name", rows, [], [@merge])
      assert conn.status == 200
      assert json(conn) == [%{"id" => 1, "name" => nil}, %{"id" => 2, "name" => "x"}]
    end

    test "columns= limits the changes: an uncast key takes the DB default / is never merged" do
      register([Mutations.Subset])
      body = %{"id" => 50, "name" => "n", "field-with_sep" => 7}
      path = "/complex_items?columns=id,name,field-with_sep&select=id,field-with_sep"
      conn = post_rep(path, body)
      assert json(conn) == [%{"id" => 50, "field-with_sep" => 1}]

      conn = call("POST", path, %{body | "id" => 3}, [], [@merge])
      assert json(conn) == [%{"id" => 3, "field-with_sep" => 3}]
    end

    test "the changeset runs exactly once per row on PATCH" do
      register([WriteResources.Counting])
      opts = [context_builder: fn _conn, _opts -> %{report_to: self()} end]

      patch("/complex_items?id=eq.3", %{"name" => "N"}, opts)
      assert_received {:changeset, :update}
      refute_received {:changeset, _}
    end

    test "an own-field branch never writes an uncast key" do
      register([Changesets.Bypass])
      path = "/complex_items?select=id,name,field-with_sep"

      for body <- [
            %{"id" => 80, "name" => "toolongname"},
            %{"id" => 80, "name" => "toolongname", "field-with_sep" => 7}
          ] do
        conn = post_rep(path, body)
        assert conn.status == 400
        assert %{"code" => "23514"} = json(conn)
      end

      conn = patch("/complex_items?id=eq.1", %{"name" => "toolongname", "field-with_sep" => 7})
      assert conn.status == 400

      conn = post_rep(path, %{"id" => 80, "name" => "abc", "field-with_sep" => 7})
      assert json(conn) == [%{"id" => 80, "name" => "abc", "field-with_sep" => 1}]
    end

    test "validate_required on an uncast supplied key still fails" do
      register([Changesets.Required])
      conn = post_rep("/complex_items", %{"id" => 71, "name" => "r", "tags" => ["t"]})
      assert conn.status == 400
      assert %{"details" => details} = json(conn)
      assert details =~ "tags: can't be blank"
    end

    test "generated changes are written; an uncast supplied key is not" do
      register([Changesets.Copy])
      body = %{"id" => 77, "field-with_sep" => 5}
      conn = post_rep("/complex_items?select=id,name,field-with_sep", body)

      assert conn.status == 201
      assert json(conn) == [%{"id" => 77, "name" => "sep=0", "field-with_sep" => 1}]
    end

    test "a change generated from the struct replaces the uncast supplied value" do
      register([Changesets.Leak])

      conn =
        patch("/complex_items?id=eq.3&select=id,field-with_sep", %{"field-with_sep" => 7}, [], [
          @rep
        ])

      assert json(conn) == [%{"id" => 3, "field-with_sep" => 1}]
    end

    test "a head-matching changeset works" do
      register([Changesets.Match])
      conn = post_rep("/complex_items?select=id,name", %{"id" => 73, "name" => "m"})

      assert conn.status == 201
      assert json(conn) == [%{"id" => 73, "name" => "m"}]
    end

    test "a changeset that rebuilds its struct writes only its changes" do
      register([Changesets.Fresh])
      body = %{"id" => 74, "name" => "f", "field-with_sep" => 0}
      conn = post_rep("/complex_items?select=id,field-with_sep", body)
      assert json(conn) == [%{"id" => 74, "field-with_sep" => 1}]

      path = "/complex_items?id=eq.3&select=id,name,field-with_sep"
      conn = patch(path, %{"name" => "f", "field-with_sep" => 0}, [], [@rep])
      assert json(conn) == [%{"id" => 3, "name" => "f", "field-with_sep" => 3}]

      conn = patch(path, %{"field-with_sep" => 8}, [], [@rep])
      assert json(conn) == [%{"id" => 3, "name" => "Three", "field-with_sep" => 8}]
    end

    test "a struct-branching changeset never writes an uncast key" do
      register([Changesets.Branch])
      path = "/complex_items?id=eq.3&select=id,field-with_sep"

      for body <- [
            %{"name" => "n", "field-with_sep" => 99},
            %{"name" => "n", "tags" => ["x"], "field-with_sep" => 99}
          ] do
        conn = patch(path, body, [], [@rep])
        assert json(conn) == [%{"id" => 3, "field-with_sep" => 3}]
      end

      body = %{"id" => 90, "name" => "n", "tags" => ["x"], "field-with_sep" => 99}
      conn = post_rep("/complex_items?select=id,field-with_sep", body)
      assert conn.status == 201
      assert json(conn) == [%{"id" => 90, "field-with_sep" => 1}]

      body = [
        %{"id" => 3, "name" => "a", "tags" => ["x"], "field-with_sep" => 9},
        %{"id" => 2, "name" => "b", "tags" => nil, "field-with_sep" => 9}
      ]

      conn = call("POST", "/complex_items?select=id,field-with_sep", body, [], [@merge])
      assert conn.status == 200

      assert Enum.sort_by(json(conn), & &1["id"]) == [
               %{"id" => 2, "field-with_sep" => 1},
               %{"id" => 3, "field-with_sep" => 3}
             ]
    end

    test "a new-vs-existing branch writes every key it cast" do
      register([Changesets.NewOrOld])
      body = %{"id" => 91, "name" => "n", "field-with_sep" => 5}
      conn = post_rep("/complex_items?select=id,name,field-with_sep", body)
      assert conn.status == 201
      assert json(conn) == [body]

      path = "/complex_items?id=eq.3&select=id,name,field-with_sep"
      conn = patch(path, %{body | "id" => 3}, [], [@rep])
      assert json(conn) == [%{body | "id" => 3}]
    end

    test "a change generated from the struct is written; an uncast key keeps its value" do
      register([Changesets.Raise])
      path = "/complex_items?id=eq.3&select=id,name,tags,field-with_sep"

      for body <- [%{"field-with_sep" => 0}, %{"name" => "Q", "field-with_sep" => 7}] do
        conn = patch(path, body, [], [@rep])
        assert conn.status == 200
        assert [%{"tags" => ["none"], "field-with_sep" => 3}] = json(conn)
      end
    end

    test "embeds_one writes through cast_embed on insert and update" do
      register([Changesets.Embed])
      body = %{"id" => 70, "name" => "e", "settings" => %{"a" => "x"}}
      conn = post_rep("/complex_items?select=id,name,settings", body)

      assert conn.status == 201
      assert [%{"id" => 70, "settings" => %{"a" => "x"}}] = json(conn)

      conn =
        patch("/complex_items?id=eq.1&select=id,settings", %{"settings" => %{"a" => "y"}}, [], [
          @rep
        ])

      assert json(conn) == [%{"id" => 1, "settings" => %{"a" => "y"}}]

      conn = patch("/complex_items?id=eq.1", %{"settings" => %{"a" => 1}})
      assert conn.status == 400
      assert %{"details" => "settings.a: is invalid"} = json(conn)
    end

    test "an embed with on_replace: :raise is written (the changeset never replaces one)" do
      register([Changesets.EmbedRaise])

      conn =
        post_rep("/complex_items?select=id,settings", %{"id" => 72, "settings" => %{"a" => "x"}})

      assert conn.status == 201
      assert json(conn) == [%{"id" => 72, "settings" => %{"a" => "x"}}]

      conn =
        patch("/complex_items?id=eq.3&select=id,settings", %{"settings" => %{"a" => "y"}}, [], [
          @rep
        ])

      assert json(conn) == [%{"id" => 3, "settings" => %{"a" => "y"}}]
    end

    test "an uncast embed is never written, not even null" do
      register([Changesets.EmbedUncast])
      [[stored]] = settings(3)

      for value <- [nil, %{"a" => "z"}] do
        body = %{"name" => "u", "settings" => value}
        conn = patch("/complex_items?id=eq.3&select=id,name,settings", body, [], [@rep])
        assert json(conn) == [%{"id" => 3, "name" => "u", "settings" => stored}]
      end
    end

    test "documented limitation: clearing an embed to its equal struct default is omitted" do
      register([Changesets.Embed])
      conn = patch("/complex_items?id=eq.3&select=id,settings", %{"settings" => nil}, [], [@rep])
      assert json(conn) == []
    end

    test "documented limitation: clearing embeds_many to [] is omitted; null is invalid" do
      register([Changesets.EmbedMany])
      conn = patch("/complex_items?id=eq.3&select=id,settings", %{"settings" => []}, [], [@rep])
      assert json(conn) == []

      conn = patch("/complex_items?id=eq.3", %{"settings" => nil})
      assert conn.status == 400

      body = %{"settings" => [%{"a" => "1"}]}
      conn = patch("/complex_items?id=eq.3&select=id,settings", body, [], [@rep])
      assert json(conn) == [%{"id" => 3, "settings" => [%{"a" => "1"}]}]
    end
  end
end
