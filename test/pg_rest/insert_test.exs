defmodule PgRest.InsertTest do
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [json: 1, register: 1]

  alias PgRest.{Catalog, Request}
  alias PgRest.Compat.{PublicRepo, Repo, Resources}
  alias PgRest.SQL.Write, as: SQLWrite
  alias PgRest.Test.{TelemetryProbe, WriteResources}
  alias PgRest.Test.WriteResources.More
  alias PgRest.Write
  alias PgRest.Write.Payload

  @rollback {"prefer", "tx=rollback"}
  @rep {"prefer", "return=representation, tx=rollback"}

  defp post(path, body, opts \\ [], headers \\ [@rollback]) do
    repo = Keyword.get(opts, :repo, Repo)

    plug_opts =
      Keyword.merge([repo: repo, tx_end: :commit_allow_override], Keyword.delete(opts, :repo))

    conn =
      Enum.reduce(headers, Plug.Test.conn("POST", path, Jason.encode!(body)), fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)

    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> PgRest.Plug.call(PgRest.Plug.init(plug_opts))
  end

  defp events do
    for {[:pgrest, :query, :stop], _m, meta} <- TelemetryProbe.drain(), do: meta
  end

  defp count(sql), do: Repo.query!(sql).rows |> hd() |> hd()

  describe "bulk and fast path" do
    setup do
      register(Resources.all())
      :ok
    end

    test "10 000 rows go in one INSERT statement with one bound parameter" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      rows = for id <- 1000..10_999, do: %{"id" => id}

      conn = post("/items", rows)
      assert conn.status == 201
      assert conn.resp_body == ""

      inserts = Enum.filter(events(), &String.contains?(&1.sql, "INSERT INTO"))
      assert [%{params_count: 1}] = inserts
    end

    test "the default changeset fast path binds the request bytes and reports :fast" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      rows = for id <- 2000..2999, do: %{"id" => id}
      body = Jason.encode!(rows)

      assert post("/items", rows).status == 201
      assert [%{write_path: :fast}] = Enum.filter(events(), &Map.has_key?(&1, :write_path))

      conn = Plug.Test.conn("POST", "/items", body)
      assert {:ok, request} = Request.from_conn(conn, [])
      config = Resources.Items.__pgrest_config__()

      assert {:ok, %{input: {:raw, ^body, ["id"]}}} =
               Payload.build(config, request, nil, %{}, 10_000)

      {_sql, params} = SQLWrite.insert(Resources.Items, {:raw, body, ["id"]}, repo: Repo)
      assert params == [body]
    end

    test "a bulk payload over max_bulk_rows is a 413 before any query" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      rows = for id <- 5001..5101, do: %{"id" => id}

      conn = post("/items", rows, max_bulk_rows: 100)
      assert conn.status == 413

      assert %{"code" => "54000", "message" => "payload exceeds max_bulk_rows"} = json(conn)
      assert events() == []

      assert post("/items", Enum.take(rows, 100), max_bulk_rows: 100).status == 201
      assert events() != []
    end

    test "a single object returns Location with the primary key" do
      conn =
        post("/compound_pk", %{"k1" => 1, "k2" => "2"}, [], [
          {"prefer", "return=headers-only, tx=rollback"}
        ])

      assert conn.status == 201
      assert Plug.Conn.get_resp_header(conn, "location") == ["/compound_pk?k1=eq.1&k2=eq.2"]
      assert Plug.Conn.get_resp_header(conn, "content-range") == ["*/*"]
    end

    test "Location percent-encodes values as PostgREST does" do
      conn =
        post("/compound_pk", %{"k1" => 1, "k2" => "a b&c"}, [], [
          {"prefer", "return=headers-only, tx=rollback"}
        ])

      assert Plug.Conn.get_resp_header(conn, "location") == [
               "/compound_pk?k1=eq.1&k2=eq.a%20b%26c"
             ]
    end

    test "missing=default fills absent keys, and an explicit null stays null" do
      headers = [{"prefer", "missing=default, return=representation, tx=rollback"}]
      rows = [%{"label" => "a"}, %{"label" => "b", "note" => nil}]

      conn = post("/defaults_demo?columns=label,note&select=label,note", rows, [], headers)

      assert conn.status == 201
      assert json(conn) == [%{"label" => "a", "note" => "x"}, %{"label" => "b", "note" => nil}]
    end

    test "a bulk payload where one row omits a column and another sets it to null" do
      headers = [{"prefer", "missing=default, return=representation, tx=rollback"}]
      rows = [%{"label" => "a"}, %{"note" => nil}]

      conn = post("/defaults_demo?columns=label,note&select=label,note", rows, [], headers)

      assert json(conn) == [%{"label" => "a", "note" => "x"}, %{"label" => nil, "note" => nil}]
    end

    test "without missing=default an absent key is null" do
      conn =
        post("/defaults_demo?columns=label,note&select=label,note", [%{"label" => "a"}], [], [
          @rep
        ])

      assert json(conn) == [%{"label" => "a", "note" => nil}]
    end

    test "a single object with a 406 media type and two rows rolls back" do
      headers = [{"accept", "application/vnd.pgrst.object+json"}, {"prefer", "return=minimal"}]
      before = count("SELECT count(*) FROM test.clients")

      conn =
        post(
          "/clients",
          [%{"id" => 900, "name" => "a"}, %{"id" => 901, "name" => "b"}],
          [],
          headers
        )

      assert conn.status == 406
      assert %{"code" => "PGRST116"} = json(conn)
      assert count("SELECT count(*) FROM test.clients") == before
    end

    test "S-M2: a redact field is not writable" do
      conn = post("/accounts", %{"id" => 900, "email" => "a@x", "hashed_password" => "h"})

      assert conn.status == 401
      assert %{"code" => "42501"} = json(conn)
    end

    test "an unknown payload key is PGRST204" do
      conn = post("/clients", %{"id" => 900, "name" => "a", "helicopter" => 1})

      assert conn.status == 400
      assert %{"code" => "PGRST204"} = json(conn)
    end
  end

  describe "Location with a nullable key" do
    setup do
      register([WriteResources.NullKey])
      :ok
    end

    test "Location writes a null key component as is.null" do
      conn =
        post("/no_pk", %{"a" => "x", "b" => nil}, [], [
          {"prefer", "return=headers-only, tx=rollback"}
        ])

      assert conn.status == 201
      assert Plug.Conn.get_resp_header(conn, "location") == ["/no_pk?a=eq.x&b=is.null"]
    end
  end

  describe "authorization (S-H1)" do
    setup do
      register(Resources.all())
      :ok
    end

    test "create without read: minimal succeeds, representation is denied before SQL" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      opts = [authorization: WriteResources.CreateOnly]
      before = count("SELECT count(*) FROM test.items")

      assert post("/items", %{"id" => 900}, opts).status == 201
      assert events() != []

      conn = post("/items", %{"id" => 901}, opts, [{"prefer", "return=representation"}])

      assert conn.status == 401
      assert %{"code" => "42501"} = json(conn)
      assert events() == []
      assert count("SELECT count(*) FROM test.items") == before
    end
  end

  describe "write check (scope as WITH CHECK)" do
    setup do
      register([WriteResources.ScopedAccounts])
      :ok
    end

    test "a row outside the scope is a 42501 and nothing is persisted" do
      body = %{"id" => 900, "email" => "out@x", "role" => "user", "owner_id" => "owner-2"}

      conn = post("/accounts", body, [], [])

      assert conn.status == 401

      assert %{"code" => "42501", "message" => message} = json(conn)
      assert message == ~s|new row violates row-level security policy for table "accounts"|
      assert count("SELECT count(*) FROM test.accounts WHERE id = 900") == 0
    end

    test "a row inside the scope passes" do
      body = %{"id" => 900, "email" => "in@x", "role" => "user", "owner_id" => "owner-1"}

      assert post("/accounts", body).status == 201
    end

    test "the check of a 10 000 row insert is one statement with one parameter" do
      TelemetryProbe.attach([:pgrest, :query, :stop])

      rows =
        for id <- 1000..10_999 do
          %{"id" => id, "email" => "u#{id}@x", "role" => "user", "owner_id" => "owner-1"}
        end

      assert post("/accounts", rows).status == 201

      assert [%{sql: sql, params_count: 1}] =
               Enum.filter(events(), &String.contains?(&1.sql, "json_to_recordset"))

      assert sql =~ "EXISTS (SELECT 1"
      refute sql =~ "IN (SELECT"
    end

    test "S-H5: details are scrubbed on a scoped resource" do
      dup = %{
        "id" => 900,
        "email" => "alice@example.com",
        "role" => "user",
        "owner_id" => "owner-1"
      }

      conn = post("/accounts", dup)

      assert conn.status == 409
      assert %{"code" => "23505", "details" => nil} = json(conn)

      bad = %{"id" => 901, "email" => "b@x", "role" => "bogus", "owner_id" => "owner-1"}
      conn = post("/accounts", bad)

      assert %{"code" => "23514", "details" => nil} = json(conn)
    end
  end

  describe "S-H5 on the identity scope and S-M2 allowlists" do
    test "an identity resource without restricted columns keeps details" do
      register([WriteResources.PlainAccounts])
      conn = post("/accounts", %{"id" => 900, "email" => "alice@example.com"})

      assert conn.status == 409
      assert %{"details" => "Key (email)=(alice@example.com) already exists."} = json(conn)
    end

    test "writable: [:email] rejects other columns" do
      register([WriteResources.EmailOnly])

      assert post("/accounts", %{"email" => "e@x"}).status == 400
      conn = post("/accounts", %{"email" => "e@x", "role" => "admin"})

      assert conn.status == 401
      assert %{"code" => "42501"} = json(conn)
    end
  end

  describe "changeset path" do
    setup do
      register([WriteResources.Counting, WriteResources.Generating])
      :ok
    end

    test "changeset/3 runs once per row and the write reports :changeset" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      rows = for id <- 1..3, do: %{"id" => 900 + id, "name" => "n#{id}"}

      conn =
        post("/complex_items", rows, context_builder: fn _conn, _opts -> %{report_to: self()} end)

      assert conn.status == 201
      for _ <- 1..3, do: assert_received({:changeset, :create})
      refute_received {:changeset, _}
      assert [%{write_path: :changeset}] = Enum.filter(events(), &Map.has_key?(&1, :write_path))
    end

    test "a supplied value equal to the struct default is not a change without force_changes" do
      body = %{"id" => 900, "name" => "n", "field-with_sep" => 0}
      conn = post("/complex_items?select=id,field-with_sep", body, [], [@rep])

      assert json(conn) == [%{"id" => 900, "field-with_sep" => 1}]
    end

    test "an absent key follows the column default" do
      conn = post("/complex_items?select=id,field-with_sep", %{"id" => 900}, [], [@rep])

      assert json(conn) == [%{"id" => 900, "field-with_sep" => 1}]
    end

    test "a change the callback adds is written" do
      conn = post("/clients?select=id,name", %{"id" => 900}, [], [@rep])

      assert json(conn) == [%{"id" => 900, "name" => "generated"}]
    end

    test "an invalid changeset is a 400 with the errors as a map" do
      conn = post("/complex_items", %{"id" => 900, "name" => String.duplicate("x", 21)})

      assert conn.status == 400
      assert %{"code" => "23514", "details" => details} = json(conn)
      assert details =~ "name: should be at most 20"
      refute conn.resp_body =~ "#Ecto"
    end

    test "an unknown key and a column outside columns= follow the same rules" do
      assert %{"code" => "PGRST204"} =
               json(post("/complex_items", %{"id" => 900, "helicopter" => 1}))

      conn = post("/complex_items?columns=id", %{"id" => 900, "name" => "dropped"}, [], [@rep])
      assert [%{"id" => 900, "name" => nil}] = json(conn)
    end
  end

  describe "default changeset" do
    test "casts exactly the effective writable set" do
      writable = WriteResources.PlainAccounts.__pgrest_effective__().writable_fields
      attrs = %{"id" => 1, "email" => "e", "role" => "user", "owner_id" => "o"}

      changeset =
        WriteResources.PlainAccounts.changeset(%WriteResources.PlainAccounts{}, attrs, %{})

      assert Enum.sort(Map.keys(changeset.changes)) == Enum.sort(writable)
    end
  end

  describe "Catalog.column_defaults/3" do
    test "reads defaults schema-qualified: identity by default as nextval, generated skipped" do
      Catalog.forget(Repo)

      assert %{"code" => code, "note" => "'x'::text", "created_at" => "now()", "id" => id} =
               defaults = Catalog.column_defaults(Repo, "test", "defaults_demo")

      assert code =~ "test.next_code()"
      assert id =~ ~r/^nextval\('test.defaults_demo_id_seq'\)/
      assert Map.keys(defaults) |> Enum.sort() == ["code", "created_at", "id", "note"]
    end

    test "refuses to load inside a transaction" do
      Catalog.forget(Repo)

      assert_raise ArgumentError, ~r/cannot load inside a transaction/, fn ->
        Repo.transaction(fn -> Catalog.column_defaults(Repo, "test", "defaults_demo") end)
      end
    end
  end

  describe "fix round 1" do
    setup do
      register(Resources.all())
      :ok
    end

    test "representation honors order and ignores filters and limit" do
      rows = for id <- 100..102, do: %{"id" => id, "name" => "n"}
      conn = post("/projects?select=id&order=id.desc&id=eq.999&limit=1", rows, [], [@rep])

      assert json(conn) == [%{"id" => 102}, %{"id" => 101}, %{"id" => 100}]
    end

    test "count=exact reports the rows written; planned reports *" do
      rows = [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => "b"}]
      exact = post("/projects", rows, [], [{"prefer", "count=exact, tx=rollback"}])
      planned = post("/projects", rows, [], [{"prefer", "count=planned, tx=rollback"}])

      assert Plug.Conn.get_resp_header(exact, "content-range") == ["*/2"]

      assert Plug.Conn.get_resp_header(exact, "preference-applied") == [
               "count=exact, tx=rollback"
             ]

      assert Plug.Conn.get_resp_header(planned, "content-range") == ["*/*"]
    end

    test "headers-only and count need :read on the root" do
      opts = [authorization: WriteResources.CreateOnly]

      for prefer <- ["return=headers-only", "count=exact"] do
        conn = post("/items", %{"id" => 900}, opts, [{"prefer", prefer <> ", tx=rollback"}])
        assert conn.status == 401
        assert %{"code" => "42501"} = json(conn)
      end

      assert post("/items", %{"id" => 900}, opts).status == 201
    end

    test "a representation embedding a resource denied :read is denied before SQL" do
      TelemetryProbe.attach([:pgrest, :query, :stop])
      opts = [authorization: More.DenyProjects]

      conn = post("/clients?select=id,projects(id)", %{"id" => 900, "name" => "a"}, opts, [@rep])

      assert conn.status == 401
      assert events() == []
      assert post("/clients?select=id", %{"id" => 900, "name" => "a"}, opts, [@rep]).status == 201
    end

    test "missing=default fills an identity column from its sequence" do
      headers = [{"prefer", "missing=default, return=representation, tx=rollback"}]
      conn = post("/defaults_demo?columns=id,label&select=id", %{"label" => "x"}, [], headers)

      assert [%{"id" => id}] = json(conn)
      assert is_integer(id)
    end

    test "a uuid field dumps JSON-safe through a custom changeset" do
      uuid = Ecto.UUID.generate()
      config = More.Uuided.__pgrest_config__()
      conn = Plug.Test.conn("POST", "/clients", Jason.encode!(%{"id" => 1, "name" => uuid}))
      assert {:ok, request} = Request.from_conn(conn, [])

      assert {:ok, %{input: {:raw, json, _keys}}} = Payload.build(config, request, nil, %{}, 10)
      assert [%{"id" => 1, "name" => ^uuid}] = Jason.decode!(json)
    end

    test "a scoped resource whose primary key field differs from its source column" do
      stop_supervised!(PgRest.Registry)
      register([More.RenamedKey])

      outside = %{"id" => 900, "email" => "x@y", "owner_id" => "owner-2"}
      conn = post("/accounts", outside, [], [])
      assert conn.status == 401
      assert %{"code" => "42501"} = json(conn)
      assert count("SELECT count(*) FROM test.accounts WHERE id = 900") == 0

      inside = %{"id" => 901, "email" => "y@y", "owner_id" => "owner-1"}
      assert post("/accounts?select=id", inside, [], [@rep]).status == 201
    end

    test "the write check fails closed for a scope without a key" do
      keyless = %{module: More.RenamedKey, primary_key: [], unique_key: nil}

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, %{status: 500, code: "PGRSTX00"}} =
                   Write.ensure_checkable(keyless, true)
        end)

      assert log =~ "RenamedKey"
      assert :ok = Write.ensure_checkable(keyless, false)
    end
  end

  describe "fix round 2" do
    defmodule CountingAuth do
      @moduledoc false
      def authorize(_conn, _resource, operation, context) do
        send(context.report_to, {:authorize, operation})
        :ok
      end
    end

    setup do
      register(Resources.all())
      :ok
    end

    test "a representation asks the :read hook once per resource" do
      opts = [
        authorization: CountingAuth,
        context_builder: fn _conn, _opts -> %{report_to: self()} end
      ]

      assert post("/clients?select=id", %{"id" => 900, "name" => "a"}, opts, [@rep]).status == 201
      assert_received {:authorize, :create}
      assert_received {:authorize, :read}
      refute_received {:authorize, _}
    end

    test "bytea binaries are hex text, whatever the bytes" do
      config = More.Bytes.__pgrest_config__()

      for value <- [<<255, 0>>, "\\x41"] do
        body = Jason.encode!(%{"id" => 1, "data" => Base.encode64(value)})
        conn = Plug.Test.conn("POST", "/clients", body)
        assert {:ok, request} = Request.from_conn(conn, [])
        assert {:ok, %{input: {:raw, json, _}}} = Payload.build(config, request, nil, %{}, 10)
        assert [%{"data" => "\\x" <> hex}] = Jason.decode!(json)
        assert Base.decode16!(hex, case: :lower) == value
      end
    end

    test "arrays of binaries are hex text per element" do
      config = More.ByteLists.__pgrest_config__()
      values = [<<255, 0>>, "\\x41"]
      body = Jason.encode!(%{"id" => 1, "data" => Enum.map(values, &Base.encode64/1)})
      assert {:ok, request} = Request.from_conn(Plug.Test.conn("POST", "/clients", body), [])
      assert {:ok, %{input: {:raw, json, _}}} = Payload.build(config, request, nil, %{}, 10)
      assert [%{"data" => hexes}] = Jason.decode!(json)
      assert Enum.map(hexes, fn "\\x" <> hex -> Base.decode16!(hex, case: :lower) end) == values
    end

    test "a context without :authorization still plans a minimal write" do
      config = Resources.Clients.__pgrest_config__()
      conn = Plug.Test.conn("POST", "/clients", "{}")
      assert {:ok, request} = Request.from_conn(conn, [])

      assert {:ok, _plan} =
               Write.plan(request, config, %{repo: Repo, graph: PgRest.Registry.graph()}, false)
    end
  end

  describe "S-L4 search_path" do
    test "missing=default fills code through a repo whose search_path is public only" do
      config = Application.fetch_env!(:pgrest, Repo)
      start_supervised!({PublicRepo, Keyword.merge(config, parameters: [search_path: "public"])})
      register(Resources.all())
      headers = [{"prefer", "missing=default, return=representation, tx=rollback"}]

      conn = post("/defaults_demo?select=code", %{"label" => "x"}, [repo: PublicRepo], headers)

      assert conn.status == 201
      assert [%{"code" => "C" <> _}] = json(conn)
    end
  end
end
