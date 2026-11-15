defmodule PgRest.RlsTest do
  # Starts the shared registries and a repo, changes the logger level, writes :persistent_term.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PgRest.Catalog
  alias PgRest.Compat.{AuthenticatorRepo, JWT, Scenario, SingleAuthenticatorRepo, SupabaseRepo}
  alias PgRest.Test.TelemetryProbe

  @secret JWT.secret()
  @roles ~w(anon authenticated service_role)
  @repo_event [:pg_rest, :compat, :authenticator_repo, :query]

  defmodule RaisingAuthorization do
    @moduledoc false
    @behaviour PgRest.Authorization

    @impl PgRest.Authorization
    def authorize(_conn, _target, _operation, _context), do: deny!()

    @doc false
    def deny! do
      raise Postgrex.Error,
        postgres: %{code: "42501", severity: "ERROR", message: "host denied"}
    end
  end

  defmodule ClaimClients do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
    end

    # Reports the context keys PgRest may set, then narrows nothing.
    @impl PgRest.Resource
    def scope(query, context) do
      if pid = context[:report_to],
        do: send(pid, {:scope, context[:jwt_claims], context[:db_role], context[:authenticated?]})

      query
    end
  end

  defmodule UnreadableFactsRepo do
    @moduledoc false
    def in_transaction?, do: false

    def query!(_sql, _params, _opts) do
      send(Application.fetch_env!(:pgrest, :facts_probe_pid), :facts_attempt)
      raise DBConnection.ConnectionError, "facts unavailable"
    end
  end

  test "unreadable login facts deny before routing without a retry" do
    Application.put_env(:pgrest, :facts_probe_pid, self())
    on_exit(fn -> Application.delete_env(:pgrest, :facts_probe_pid) end)

    capture_log(fn ->
      conn = request("GET", "/rls_notes", plug: [repo: UnreadableFactsRepo])
      assert conn.status == 503
    end)

    assert_received :facts_attempt
    refute_received :facts_attempt
  end

  setup_all do
    Enum.each(Scenario.registries(), &start_supervised!/1)
    :ok
  end

  defp rls(extra \\ []) do
    Keyword.merge(
      [
        roles: @roles,
        jwt: {PgRest.JWT.HS256, secret: @secret},
        pre_request: "public.check_request"
      ],
      extra
    )
  end

  defp plug_opts(extra) do
    Keyword.merge(
      [
        repo: AuthenticatorRepo,
        registry: PgRest.Compat.SupabaseRegistry,
        tx_end: :commit_allow_override,
        rls: rls()
      ],
      extra
    )
  end

  # `as` is a JWT `sub` (signed with role `authenticated`), a claims map, or `nil` (no token).
  defp request(method, path, opts \\ []) do
    body = Keyword.get(opts, :body)

    conn =
      method
      |> Plug.Test.conn(path, body && Jason.encode!(body))
      |> put_headers(Keyword.get(opts, :headers, []))
      |> put_token(Keyword.get(opts, :as))

    conn =
      if body, do: Plug.Conn.put_req_header(conn, "content-type", "application/json"), else: conn

    PgRest.Plug.call(conn, PgRest.Plug.init(plug_opts(Keyword.get(opts, :plug, []))))
  end

  defp put_headers(conn, headers),
    do: Enum.reduce(headers, conn, fn {k, v}, acc -> Plug.Conn.put_req_header(acc, k, v) end)

  defp put_token(conn, nil), do: conn

  defp put_token(conn, sub) when is_binary(sub),
    do: put_token(conn, %{"role" => "authenticated", "sub" => sub})

  defp put_token(conn, %{} = claims),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> JWT.sign(claims))

  defp json(conn), do: Jason.decode!(conn.resp_body)
  defp header(conn, name), do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  # Catalog loads and server facts issue repo queries on first use; warm them so that a
  # request's own statements are all that remain.
  defp warm(repo \\ AuthenticatorRepo) do
    Catalog.facts(repo)
    assert %{status: 200} = request("GET", "/rls_notes", as: "alice", plug: [repo: repo])
    :ok
  end

  describe "policies" do
    test "two JWT users see different rows, anon none" do
      assert json(request("GET", "/rls_notes?select=slug&order=slug", as: "alice")) ==
               [%{"slug" => "a1"}, %{"slug" => "a2"}]

      assert json(request("GET", "/rls_notes?select=slug", as: "bob")) == [%{"slug" => "b1"}]
      assert json(request("GET", "/rls_notes?select=slug")) == []
    end

    test "a 42501 is a 401 for the default role and a 403 for any other" do
      anon = request("GET", "/private_docs")
      assert anon.status == 401
      assert json(anon)["message"] == "permission denied for table private_docs"
      assert header(anon, "www-authenticate") == "Bearer"

      authed = request("GET", "/private_docs", as: "alice")
      assert authed.status == 403
      assert header(authed, "www-authenticate") == nil

      fun = "/rpc/privileged_hello"
      body = %{name: "x"}

      assert %{status: 401} = denied = request("POST", fun, body: body)
      assert json(denied)["message"] == "permission denied for function privileged_hello"
      assert %{status: 200} = ok = request("POST", fun, body: body, as: "alice")
      assert json(ok) == "Privileged hello to x"
    end
  end

  describe "the role allowlist" do
    test "disallowed and nonexistent roles are a 401 22023 before any SQL" do
      warm()
      TelemetryProbe.attach([[:pgrest, :query, :start], @repo_event])

      for role <- ~w(none session_user postgres nope) do
        conn = request("GET", "/rls_notes", as: %{"role" => role})

        assert conn.status == 401
        assert header(conn, "www-authenticate") == "Bearer"

        assert json(conn) == %{
                 "code" => "22023",
                 "message" => ~s|role "#{role}" does not exist|,
                 "details" => nil,
                 "hint" => nil
               }
      end

      assert TelemetryProbe.drain() == []
    end

    test "a key-path role_claim: is accepted only for a role in roles:" do
      claims = %{"user_metadata" => %{"role" => "service_role"}}
      path = ["user_metadata", "role"]

      ok = request("GET", "/rpc/whoami", as: claims, plug: [rls: rls(role_claim: path)])
      assert %{"role" => "service_role"} = json(ok)

      denied =
        request("GET", "/rpc/whoami",
          as: claims,
          plug: [rls: rls(role_claim: path, roles: ["anon", "authenticated"])]
        )

      assert denied.status == 401
      assert json(denied)["code"] == "22023"
    end
  end

  describe "JWT errors" do
    test "carry PostgREST's invalid_token challenge" do
      conn = request("GET", "/rls_notes", headers: [{"authorization", "Bearer a.b"}])

      assert conn.status == 401
      assert json(conn)["code"] == "PGRST301"

      assert header(conn, "www-authenticate") ==
               ~s|Bearer error="invalid_token", error_description="Expected 3 parts in JWT; got 2"|
    end
  end

  describe "privileged login" do
    setup do
      :persistent_term.erase({PgRest.Catalog, SupabaseRepo, :privileged_login, :warned})
      :ok
    end

    test "a superuser repo raises on its first request" do
      message = ~r/repo PgRest.Compat.SupabaseRepo logs in as a superuser or BYPASSRLS role/

      assert_raise ArgumentError, message, fn ->
        request("GET", "/rls_notes", plug: [repo: SupabaseRepo])
      end
    end

    test "allow_privileged_login: true serves and warns once per repo" do
      opts = [repo: SupabaseRepo, rls: rls(allow_privileged_login: true)]

      log =
        capture_log(fn ->
          assert %{status: 200} = request("GET", "/rls_notes", plug: opts)
          assert %{status: 200} = request("GET", "/rls_notes", plug: opts)
        end)

      assert length(String.split(log, "logs in as a superuser or BYPASSRLS role")) == 2
    end
  end

  describe "request transaction" do
    test "one setup statement in PostgREST's order, read-only for a read, then pre_request" do
      warm()
      TelemetryProbe.attach([:pgrest, :query, :start])

      assert %{status: 200} = request("GET", "/rls_notes", as: "alice")

      assert [setup, pre_request, _read] =
               for({_, _, %{sql: sql}} <- TelemetryProbe.drain(), do: sql)

      assert setup ==
               "SELECT set_config('search_path', $1, true), set_config($2, $3, true), " <>
                 "set_config($4, $5, true), set_config('role', $6, true), " <>
                 "set_config('request.jwt.claims', $7, true), " <>
                 "set_config('request.method', $8, true), set_config('request.path', $9, true), " <>
                 "set_config('request.headers', $10, true), " <>
                 "set_config('request.cookies', $11, true), " <>
                 "set_config('transaction_read_only', $12, true)"

      assert pre_request == ~s|SELECT "public"."check_request"()|
    end

    test "the role's ALTER ROLE settings apply before the role, and the plug's after (I4)" do
      timeout = fn opts -> json(request("GET", "/rpc/current_statement_timeout", opts)) end

      assert timeout.([]) == "3s"
      assert timeout.(as: "alice") == "8s"
      assert timeout.(as: %{"role" => "service_role"}) == "0"
      assert timeout.(as: "alice", plug: [statement_timeout: "5s"]) == "5s"
    end

    test "request GUCs: method, mount-relative path, headers without the cookie" do
      conn =
        request("GET", "/rpc/request_info",
          headers: [{"x-custom", "1"}, {"cookie", "session=secret-cookie"}]
        )

      assert %{"method" => "GET", "path" => "/rpc/request_info", "headers" => headers} =
               json(conn)

      assert headers["x-custom"] == "1"
      refute Map.has_key?(headers, "cookie")
    end

    test "pre_request runs in the request transaction (response GUCs, errors)" do
      set = request("GET", "/rls_notes", headers: [{"x-set-guc", "true"}])
      assert header(set, "x-pre-request") == "ran"

      banned = request("GET", "/rls_notes", headers: [{"x-banned", "true"}])
      assert banned.status == 400

      assert json(banned) == %{
               "code" => "P0001",
               "message" => "banned",
               "details" => nil,
               "hint" => "contact support"
             }
    end
  end

  describe "no secrets in logs" do
    test "a token and a cookie reach neither the repo's events nor the log" do
      warm()
      token = JWT.sign(%{"role" => "authenticated", "sub" => "alice"})
      previous = Logger.level()
      Logger.configure(level: :debug)
      on_exit(fn -> Logger.configure(level: previous) end)
      TelemetryProbe.attach(@repo_event)

      log =
        capture_log(fn ->
          conn =
            request("GET", "/rls_notes",
              headers: [{"authorization", "Bearer " <> token}, {"cookie", "sid=cookie-value-42"}]
            )

          assert conn.status == 200
        end)

      # Only the parameterless `begin`/`commit` events Phase 1 keeps reach the repo's handlers;
      # every statement (the setup binding the headers, cookies and claims) skips them.
      events = TelemetryProbe.drain()
      assert Enum.map(events, fn {_, _, meta} -> meta.query end) == ["begin", "commit"]
      refute inspect(events) =~ token
      refute inspect(events) =~ "cookie-value-42"
      refute log =~ token
      refute log =~ "cookie-value-42"
    end
  end

  # PostgREST Review Focus 2: one connection serves every request in turn, so a role or GUC
  # left behind by one would leak into the next.
  describe "one shared connection" do
    setup do
      start_supervised!(SingleAuthenticatorRepo)
      :ok
    end

    test "errors in every phase leave no state behind" do
      opts = [repo: SingleAuthenticatorRepo]

      violation =
        request("POST", "/rls_notes", as: "alice", body: %{owner: "bob", body: "x"}, plug: opts)

      assert violation.status == 403

      assert json(violation)["message"] ==
               ~s|new row violates row-level security policy for table "rls_notes"|

      nope = request("GET", "/rls_notes", as: %{"role" => "nope"}, plug: opts)
      assert nope.status == 401
      assert json(nope)["message"] == ~s|role "nope" does not exist|

      timeout =
        request("GET", "/rpc/sleep_for?s=1",
          as: "alice",
          plug: Keyword.put(opts, :statement_timeout, "100ms")
        )

      assert timeout.status == 500
      assert json(timeout)["code"] == "57014"

      banned = request("GET", "/rls_notes", headers: [{"x-banned", "true"}], plug: opts)
      assert banned.status == 400
      assert %{"code" => "P0001", "hint" => "contact support"} = json(banned)

      # A committed request as alice, then anon: the commit path resets the role and claims too.
      assert %{status: 200} = request("GET", "/rls_notes", as: "alice", plug: opts)

      assert json(request("GET", "/rpc/whoami", plug: opts)) ==
               %{"role" => "anon", "claims" => %{"role" => "anon"}}
    end
  end

  describe "without RLS mode" do
    for path <- ["/rls_notes", "/rpc/whoami"],
        {anonymous?, status} <- [{true, 401}, {false, 403}] do
      test "an escaped host exception on #{path} retains status #{status}" do
        start_supervised!(
          {PgRest.Registry,
           name: __MODULE__.HostErrors,
           modules: [PgRest.Compat.Supabase.RlsNote],
           introspect: [repo: SupabaseRepo, only: ["whoami"]]}
        )

        capture_log(fn ->
          conn =
            request("GET", unquote(path),
              headers: [{"accept", "application/vnd.pgrst.plan"}],
              plug: [
                repo: SupabaseRepo,
                registry: __MODULE__.HostErrors,
                rls: nil,
                authorization: if(unquote(path) == "/rpc/whoami", do: RaisingAuthorization),
                plan_enabled: fn _conn, _ctx -> RaisingAuthorization.deny!() end,
                anonymous?: fn _conn, _context -> unquote(anonymous?) end
              ]
            )

          assert conn.status == unquote(status)
          assert json(conn)["code"] == "42501"
        end)
      end
    end

    test "anonymous? decides between 401 and 403" do
      start_supervised!(
        {PgRest.Registry, name: __MODULE__.Plain, modules: [PgRest.Compat.Supabase.PrivateDoc]}
      )

      opts = [repo: SupabaseRepo, registry: __MODULE__.Plain, rls: nil]

      anon = request("GET", "/private_docs", plug: opts)
      assert anon.status == 401

      authed =
        request("GET", "/private_docs",
          plug: opts ++ [anonymous?: fn _conn, _context -> false end]
        )

      assert authed.status == 403
    end

    test "a builder's own jwt_claims and db_role reach scope/2 untouched (I1)" do
      start_supervised!({PgRest.Registry, name: __MODULE__.Claims, modules: [ClaimClients]})

      builder = fn _conn, _opts ->
        %{report_to: self(), jwt_claims: %{"sub" => "host"}, db_role: "host_role"}
      end

      opts = [
        repo: PgRest.Compat.Repo,
        registry: __MODULE__.Claims,
        rls: nil,
        context_builder: builder
      ]

      assert %{status: 200} = request("GET", "/clients?select=id", plug: opts)
      assert_received {:scope, %{"sub" => "host"}, "host_role", false}
    end
  end

  # Before RLS mode the builder ran only for a request that reached a resource or a function;
  # it still does, except for `jwt: :context`, which needs it to verify the token.
  describe "the context builder (I2)" do
    setup do
      start_supervised!({PgRest.Registry, name: __MODULE__.Signed, modules: [ClaimClients]})
      :ok
    end

    defp signed_in_only(conn, _opts) do
      if conn.assigns[:signed_in], do: %{}, else: raise("the builder ran")
    end

    test "without RLS it runs after parsing and receives the schema graph" do
      test = self()

      plug = [
        repo: PgRest.Compat.Repo,
        registry: __MODULE__.Signed,
        rls: nil,
        context_builder: fn _conn, opts ->
          send(test, {:builder_graph, Map.get(opts, :graph)})
          %{}
        end
      ]

      assert %{status: 400} = request("GET", "/clients?id=%GG", plug: plug)
      refute_received {:builder_graph, _}

      assert %{status: 400} =
               request("GET", "/clients",
                 plug: plug,
                 headers: [{"prefer", "handling=strict, timezone=NoSuchZone"}]
               )

      refute_received {:builder_graph, _}
      assert %{status: 200} = request("GET", "/clients?select=id", plug: plug)
      assert_received {:builder_graph, %PgRest.SchemaGraph{}}
      refute_received {:builder_graph, _}
    end

    defp unrouted(plug, path) do
      [
        request("OPTIONS", path, plug: plug),
        request("GET", "/no_such_table", plug: plug),
        request("TRACE", path, plug: plug)
      ]
      |> Enum.map(& &1.status)
    end

    test "never runs for OPTIONS, an unknown table or a 405, without RLS mode" do
      plug = [
        repo: PgRest.Compat.Repo,
        registry: __MODULE__.Signed,
        rls: nil,
        context_builder: &signed_in_only/2
      ]

      assert unrouted(plug, "/clients") == [200, 404, 405]
    end

    test "never runs for them in RLS mode with a verifier" do
      plug = [context_builder: &signed_in_only/2]
      assert unrouted(plug, "/rls_notes") == [200, 404, 405]
    end
  end

  describe "jwt: :context" do
    test "the builder's verified claims pick the role end to end (M5)" do
      builder = fn _conn, _opts ->
        %{jwt_claims: %{"role" => "authenticated", "sub" => "carol"}}
      end

      opts = [context_builder: builder, rls: rls(jwt: :context)]

      assert json(request("GET", "/rpc/whoami", plug: opts)) ==
               %{
                 "role" => "authenticated",
                 "claims" => %{"role" => "authenticated", "sub" => "carol"}
               }
    end

    test "claims that are not a map are a 500, logged (M8)" do
      opts = [
        context_builder: fn _conn, _opts -> %{jwt_claims: "token"} end,
        rls: rls(jwt: :context)
      ]

      log =
        capture_log(fn ->
          assert %{status: 500} = request("GET", "/rpc/whoami", plug: opts)
        end)

      assert log =~ "jwt_claims"
    end
  end
end
