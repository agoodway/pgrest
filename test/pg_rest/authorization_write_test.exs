defmodule PgRest.AuthorizationWriteTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import PgRest.PlugCase
  alias Ecto.Adapters.SQL.Sandbox
  alias PgRest.Authorization.Apply
  alias PgRest.Compat.{Repo, Resources}

  defmodule VirtualClient do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, writable: [:id, :password]
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
      field(:password, :string, virtual: true)
      field(:ignored, :string, virtual: true)
    end

    @impl true
    def changeset(row, attrs, _ctx) do
      row
      |> Ecto.Changeset.cast(attrs, [:id, :password])
      |> Ecto.Changeset.put_change(:name, "hashed:" <> Map.get(attrs, "password", ""))
    end
  end

  defmodule DefaultVirtual do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, writable: [:id, :name, :password]
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
      field(:password, :string, virtual: true)
    end
  end

  defmodule CommitRepo do
    @moduledoc false
    use Ecto.Repo, otp_app: :pgrest, adapter: Ecto.Adapters.Postgres
  end

  defmodule Policy do
    @moduledoc false
    @behaviour PgRest.Authorization
    import Ecto.Query

    @impl true
    def authorize_query(_conn, resource, op, query, ctx) do
      if pid = ctx[:trace], do: send(pid, {resource, op})

      grant(op in Map.get(ctx, :deny, []), resource, op, query, ctx)
    end

    defp grant(true, _resource, _op, _query, _ctx), do: {:error, :denied}

    defp grant(false, resource, op, query, ctx),
      do:
        {:ok, query(resource, op, query, ctx),
         columns: columns(op, ctx), count: true, aggregates: true, limit: ctx[:limit]}

    defp query(Resources.Projects, :read, query, _ctx), do: where(query, [p], p.client_id == 1)
    defp query(Resources.Projects, _op, query, %{write_all?: true}), do: query
    defp query(Resources.Projects, _op, query, _ctx), do: where(query, [p], p.client_id == 1)
    defp query(_resource, _op, query, _ctx), do: query

    defp columns(:read, ctx), do: Map.get(ctx, :read_columns, :all)
    defp columns(_op, ctx), do: Map.get(ctx, :write_columns, :all)
  end

  defmodule OrProjects do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, custom_params: ["or_id"]
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      field(:client_id, :integer)
    end

    @impl true
    def scope(query, %{scope_tenant: tenant}), do: where(query, [p], p.client_id == ^tenant)
    def scope(query, _context), do: query

    @impl true
    def handle_param("or_id", id, query, _context),
      do: or_where(query, [p], p.id == ^String.to_integer(id))
  end

  defmodule OrPolicy do
    @moduledoc false
    @behaviour PgRest.Authorization
    @impl true
    def authorize_query(_conn, _resource, _op, query, _ctx),
      do: {:ok, where(query, [p], p.client_id == 1), count: true}
  end

  for method <- ~w(GET PATCH DELETE), hook? <- [true, false] do
    test "#{method} OR custom parameter cannot widen #{if hook?, do: "hook", else: "scope"} tenancy" do
      start_supervised!({PgRest.Registry, name: __MODULE__.OrRegistry, modules: [OrProjects]})

      opts =
        if unquote(hook?),
          do: [authorization: OrPolicy],
          else: [context_builder: fn _, _ -> %{scope_tenant: 1} end]

      opts = opts ++ [registry: __MODULE__.OrRegistry, tx_end: :commit]
      assert request("GET", "/projects", nil, [], opts).status == 200

      assert {:error, :verified} =
               Repo.transaction(fn ->
                 Repo.query!(
                   "INSERT INTO test.projects(id,name,client_id) VALUES (9999,'other',2)"
                 )

                 conn =
                   request(
                     unquote(method),
                     "/projects?id=eq.9999&or_id=9999",
                     if(unquote(method) == "PATCH", do: %{"name" => "blocked"}),
                     [{"prefer", "return=representation"}],
                     opts
                   )

                 assert conn.status == 200, conn.resp_body
                 assert json(conn) == []

                 assert Repo.query!("SELECT name,client_id FROM test.projects WHERE id=9999").rows ==
                          [["other", 2]]

                 Repo.rollback(:verified)
               end)
    end
  end

  setup do
    register(Resources.all())
    :ok
  end

  setup context do
    if context[:commit] do
      start_supervised!({CommitRepo, Keyword.put(Repo.config(), :pool, Sandbox)})
      owner = Sandbox.start_owner!(CommitRepo, shared: true)
      on_exit(fn -> Sandbox.stop_owner(owner) end)
    end

    :ok
  end

  defp commit_call(method, path, body, ctx, preferences) do
    request(method, path, body, [{"prefer", preferences}],
      repo: CommitRepo,
      authorization: Policy,
      context_builder: fn _, _ -> ctx end,
      tx_end: :commit
    )
  end

  @tag :commit
  test "Location cannot expose a newly inserted row outside the read predicate" do
    conn =
      commit_call(
        "POST",
        "/projects",
        %{"id" => 9999, "client_id" => 2, "name" => "blocked"},
        %{write_all?: true},
        "return=headers-only"
      )

    assert conn.status == 401
    assert json(conn)["code"] == "42501"
    assert header(conn, "location") == nil
    assert CommitRepo.query!("SELECT id FROM test.projects WHERE id=9999").rows == []
  end

  defp call(method, path, body, ctx \\ %{}, preferences \\ "return=representation") do
    request(method, path, body, [{"prefer", preferences <> ", tx=rollback"}],
      authorization: Policy,
      context_builder: fn _, _ -> ctx end,
      tx_end: :commit_allow_override
    )
  end

  for method <- ~w(PATCH DELETE) do
    test "#{method} cannot touch another tenant" do
      conn = call(unquote(method), "/projects?id=eq.3", %{"name" => "blocked"})
      assert conn.status == 200
      assert json(conn) == []
    end
  end

  for method <- ~w(PUT POST) do
    @tag :commit
    test "#{method} cannot take ownership of another tenant's row" do
      path = if unquote(method) == "PUT", do: "/projects?id=eq.3", else: "/projects"

      conn =
        commit_call(
          unquote(method),
          path,
          %{"id" => 3, "client_id" => 1, "name" => "blocked"},
          %{},
          "resolution=merge-duplicates"
        )

      assert conn.status == 401
      assert json(conn)["code"] == "42501"

      assert CommitRepo.query!("SELECT client_id FROM test.projects WHERE id=3").rows == [
               [2]
             ]
    end
  end

  for method <- ~w(PATCH PUT POST) do
    @tag :commit
    test "#{method} ownership change fails the post-write check" do
      path = if unquote(method) == "POST", do: "/projects", else: "/projects?id=eq.1"

      conn =
        commit_call(
          unquote(method),
          path,
          %{"id" => 1, "client_id" => 2, "name" => "blocked"},
          %{},
          "resolution=merge-duplicates"
        )

      assert conn.status == 401
      assert json(conn)["code"] == "42501"

      assert CommitRepo.query!("SELECT client_id FROM test.projects WHERE id=1").rows == [
               [1]
             ]
    end
  end

  test "representation cannot expose a new row outside a distinct read policy" do
    conn =
      call("PATCH", "/projects?id=eq.1", %{"client_id" => 2}, %{write_all?: true})

    assert conn.status == 401
    assert json(conn)["code"] == "42501"
    assert Repo.query!("SELECT client_id FROM test.projects WHERE id=1").rows == [[1]]

    assert call(
             "PATCH",
             "/projects?id=eq.1",
             %{"client_id" => 2},
             %{write_all?: true},
             "return=minimal"
           ).status == 204
  end

  @tag :commit
  test "minimal counts cannot expose a newly inserted row outside the read predicate" do
    for count <- ["exact", "estimated"] do
      conn =
        commit_call(
          "POST",
          "/projects",
          %{"id" => 9999, "client_id" => 2, "name" => "blocked"},
          %{write_all?: true},
          "return=minimal,count=#{count}"
        )

      assert conn.status == 401, conn.resp_body
      assert json(conn)["code"] == "42501"
      assert CommitRepo.query!("SELECT id FROM test.projects WHERE id=9999").rows == []
    end
  end

  for returning <- ["minimal", "headers-only", "representation"] do
    @tag :commit
    test "#{returning} insert and upsert responses cap counts without capping written rows" do
      for count <- ["exact", "estimated"], resolution <- ["", ",resolution=merge-duplicates"] do
        CommitRepo.query!("DELETE FROM test.clients WHERE id IN (9998,9999)")

        conn =
          commit_call(
            "POST",
            "/clients",
            [%{"id" => 9998, "name" => "a"}, %{"id" => 9999, "name" => "b"}],
            %{limit: 1},
            "return=#{unquote(returning)},count=#{count}#{resolution}"
          )

        assert conn.status == 201, conn.resp_body
        assert header(conn, "content-range") == "*/1"
        assert header(conn, "location") == nil
        if unquote(returning) == "representation", do: assert(length(json(conn)) == 1)

        assert CommitRepo.query!("SELECT count(*) FROM test.clients WHERE id IN (9998,9999)").rows ==
                 [[2]]
      end
    end
  end

  @tag :commit
  test "a response cap cannot make a bulk write singular" do
    conn =
      request(
        "POST",
        "/clients",
        [%{"id" => 9998, "name" => "a"}, %{"id" => 9999, "name" => "b"}],
        [{"prefer", "return=representation"}, {"accept", "application/vnd.pgrst.object+json"}],
        repo: CommitRepo,
        authorization: Policy,
        context_builder: fn _, _ -> %{limit: 1} end,
        tx_end: :commit
      )

    assert conn.status == 406, conn.resp_body
    assert json(conn)["code"] == "PGRST116"
    assert CommitRepo.query!("SELECT id FROM test.clients WHERE id IN (9998,9999)").rows == []
  end

  test "writable hidden column can change but cannot be returned or filtered" do
    ctx = %{read_columns: ["id"], write_columns: ["id", "name"]}
    conn = call("PATCH", "/clients?id=eq.1", %{"name" => "changed"}, ctx)
    assert conn.status == 200
    assert json(conn) == [%{"id" => 1}]
    assert call("PATCH", "/clients?name=eq.secret", %{"name" => "changed"}, ctx).status == 401

    assert call("PATCH", "/clients?id=eq.1&select=name", %{"name" => "changed"}, ctx).status ==
             401

    assert call("POST", "/clients?columns=name", %{"name" => "x"}, %{write_columns: ["id"]}).status ==
             401
  end

  test "read-denied insert minimal succeeds, representation denies" do
    assert call(
             "POST",
             "/clients",
             %{"id" => 9999, "name" => "x"},
             %{deny: [:read]},
             "return=minimal"
           ).status == 201

    assert call("POST", "/clients", %{"id" => 9999, "name" => "x"}, %{deny: [:read]}).status ==
             401
  end

  test "read-denied mutation probes and write-denied requests deny" do
    for {method, path, preferences} <- [
          {"PATCH", "/clients?id=eq.1", "return=representation"},
          {"PATCH", "/clients?id=eq.1", "return=minimal,count=exact"},
          {"DELETE", "/clients?id=eq.1", "return=minimal"},
          {"PUT", "/clients?id=eq.1", "return=minimal"}
        ] do
      assert call(method, path, %{"id" => 1, "name" => "x"}, %{deny: [:read]}, preferences).status ==
               401
    end

    assert call("PATCH", "/clients?id=eq.1", %{"name" => "x"}, %{deny: [:update]}).status == 401
  end

  test "read and write policies run once each" do
    assert call("PATCH", "/clients?id=eq.1", %{"name" => "x"}, %{trace: self()}).status == 200
    assert_received {Resources.Clients, :read}
    assert_received {Resources.Clients, :update}
    refute_received {Resources.Clients, _}
  end

  test "explicit virtual writable input reaches changeset but is never a database column" do
    resource = __MODULE__.VirtualClient
    start_supervised!({PgRest.Registry, name: __MODULE__.Virtual, modules: [resource]})
    opts = [registry: __MODULE__.Virtual, tx_end: :commit_allow_override]

    conn =
      request(
        "POST",
        "/clients",
        %{"id" => 9999, "password" => "value"},
        [{"prefer", "return=representation,tx=rollback"}],
        opts
      )

    assert conn.status == 201
    assert json(conn) == [%{"id" => 9999, "name" => "hashed:value"}]

    hooked =
      request(
        "POST",
        "/clients",
        %{"id" => 9999, "password" => "value"},
        [{"prefer", "return=representation,tx=rollback"}],
        opts ++
          [
            authorization: Policy,
            context_builder: fn _, _ ->
              %{read_columns: ["id"], write_columns: ["id", "password"]}
            end
          ]
      )

    assert hooked.status == 201
    assert json(hooked) == [%{"id" => 9999}]

    conn = request("POST", "/clients", %{"ignored" => "x"}, [], opts)
    assert json(conn)["code"] == "PGRST204"
  end

  test "hidden on_conflict names remain 42703" do
    for returning <- ["representation", "minimal"] do
      conn =
        call(
          "POST",
          "/clients?on_conflict=name",
          %{"name" => "x"},
          %{read_columns: ["id"]},
          "return=#{returning},resolution=merge-duplicates"
        )

      assert json(conn)["code"] == "42703"
    end
  end

  test "insert and upsert filters and selections cannot name hidden read columns" do
    ctx = %{read_columns: ["id"]}

    for path <- ["/clients?name=eq.hidden", "/clients?select=name"] do
      assert call("POST", path, %{"id" => 9999, "name" => "x"}, ctx, "return=minimal").status ==
               401
    end
  end

  test "read permission limits bound mutation counts" do
    assert request("GET", "/clients").status == 200

    assert {:error, :verified} =
             Repo.transaction(fn ->
               conn =
                 request(
                   "PATCH",
                   "/clients?id=gt.0",
                   %{"name" => "cap-changed"},
                   [{"prefer", "return=representation,count=exact"}],
                   authorization: Policy,
                   context_builder: fn _, _ -> %{limit: 1} end
                 )

               assert conn.status == 200
               assert length(json(conn)) == 1

               assert Repo.query!("SELECT count(*) FROM test.clients WHERE name='cap-changed'").rows ==
                        [[1]]

               Repo.rollback(:verified)
             end)
  end

  test "default changeset drops explicitly writable virtual fields before SQL" do
    start_supervised!(
      {PgRest.Registry, name: __MODULE__.Default, modules: [__MODULE__.DefaultVirtual]}
    )

    conn =
      request(
        "POST",
        "/clients",
        %{"id" => 9999, "name" => "virtual", "password" => "unused"},
        [{"prefer", "tx=rollback"}],
        registry: __MODULE__.Default,
        tx_end: :commit_allow_override
      )

    assert conn.status == 201, conn.resp_body
  end

  test "hook narrowing scrubs duplicate-key details from writes" do
    conn = call("POST", "/projects", %{"id" => 1, "client_id" => 1, "name" => "duplicate"})
    assert conn.status == 409
    assert json(conn)["code"] == "23505"
    assert json(conn)["details"] == nil
  end

  test "narrowed representation embeds scrub mutation errors even with an identity target" do
    conn = call("PATCH", "/clients?id=eq.1&select=id,projects(id)", %{"name" => nil})
    assert conn.status == 400
    assert json(conn)["code"] == "23502"
    assert json(conn)["details"] == nil
  end

  test "a new inserted row must satisfy the create policy" do
    conn = call("POST", "/projects", %{"id" => 9999, "client_id" => 2, "name" => "blocked"})
    assert conn.status == 401
    assert json(conn)["code"] == "42501"
    assert Repo.query!("SELECT id FROM test.projects WHERE id=9999").rows == []
  end

  test "implicit conflict keys do not turn payload denial into a column oracle" do
    conn =
      call(
        "POST",
        "/clients",
        %{"id" => 1, "name" => "x"},
        %{write_columns: ["name"]},
        "resolution=merge-duplicates"
      )

    assert json(conn)["code"] == "42501"
  end

  test "predicate-only write policy preserves the simple scoped locking source" do
    base = Ecto.Queryable.to_query(Resources.Projects)

    assert {:ok, policy} =
             Apply.source(
               Plug.Test.conn(:patch, "/projects"),
               Policy,
               Resources.Projects,
               :update,
               base,
               %{}
             )

    assert policy.query.joins == []
  end
end
