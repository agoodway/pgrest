defmodule PgRest.PlugOptionsTest do
  use ExUnit.Case, async: true

  alias PgRest.Compat.Repo

  describe "init/1" do
    test "fills every default" do
      assert %{
               repo: Repo,
               registry: PgRest.Registry,
               context_builder: nil,
               authorization: nil,
               require_filters_for_mutations: true,
               max_limit: nil,
               max_embed_depth: 8,
               max_body_bytes: 8_000_000,
               max_bulk_rows: 10_000,
               count_modes: [:exact, :planned, :estimated],
               tx_end: :commit,
               statement_cache: [promote_after: 3, max: 500],
               statement_timeout: nil,
               aggregates: false,
               plan_enabled: false,
               rls: nil
             } = opts = PgRest.Plug.init(repo: Repo)

      assert opts.anonymous? == (&PgRest.Auth.default_anonymous?/2)
      assert map_size(opts) == 17
    end

    test "keeps valid overrides" do
      opts =
        PgRest.Plug.init(
          repo: Repo,
          max_limit: 5,
          tx_end: :commit_allow_override,
          count_modes: [:exact],
          statement_cache: false,
          statement_timeout: "5s",
          context_builder: fn _conn, _opts -> %{} end
        )

      assert %{max_limit: 5, tx_end: :commit_allow_override, count_modes: [:exact]} = opts
      assert %{statement_cache: false, statement_timeout: "5s"} = opts
    end

    test "rejects what it cannot use" do
      for bad <- [
            [bogus: 1],
            [tx_end: :rollback],
            [count_modes: [:bogus]],
            [max_embed_depth: 0],
            [max_limit: 0],
            [max_body_bytes: -1],
            [max_bulk_rows: "many"],
            [statement_cache: [promote_after: 3, bogus: 1]],
            [statement_cache: [max: 0]],
            [statement_timeout: "soon"],
            [statement_timeout: 5],
            [require_filters_for_mutations: :yes],
            [aggregates: :yes],
            [plan_enabled: nil],
            [plan_enabled: :yes],
            [plan_enabled: fn _conn -> true end],
            [context_builder: fn _conn -> %{} end],
            [registry: nil],
            [registry: "PgRest.Registry"],
            [rls: [jwt: :context]],
            [rls: :on],
            [anonymous?: true],
            [anonymous?: fn _conn -> true end]
          ] do
        assert_raise ArgumentError, fn -> PgRest.Plug.init([repo: Repo] ++ bad) end
      end

      assert_raise ArgumentError, fn -> PgRest.Plug.init([]) end
    end
  end
end

defmodule PgRest.PlugAllowTest do
  # Not async: attaches to global telemetry events and starts the default registry.
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [header: 2, json: 1, request: 3, request: 5]

  alias PgRest.Compat.Resources
  alias PgRest.Test.{PlugResources, SQLResources, TelemetryProbe}

  defmodule Forbidden do
    @moduledoc false
    # Fails the test run if an OPTIONS request reaches the authorization module.
    def authorize(_conn, _target, _operation, _context), do: raise("authorization was called")
  end

  @all "OPTIONS,GET,HEAD,POST,PUT,PATCH,DELETE"

  setup do
    start_supervised!(
      {PgRest.Registry,
       modules: Resources.all(),
       introspect: [repo: PgRest.Compat.Repo, only: ~w(getallprojects noparamsproc)]}
    )

    :ok
  end

  describe "OPTIONS" do
    test "a table answers 200 with every method and no body" do
      conn = request("OPTIONS", "/items", nil)

      assert conn.status == 200
      assert conn.resp_body == ""
      assert header(conn, "allow") == @all
    end

    test "a table without a primary key omits PUT" do
      conn = request("OPTIONS", "/no_pk", nil)

      assert header(conn, "allow") == "OPTIONS,GET,HEAD,POST,PATCH,DELETE"
    end

    test "the root allows OPTIONS, GET and HEAD" do
      conn = request("OPTIONS", "/", nil)

      assert conn.status == 200
      assert header(conn, "allow") == "OPTIONS,GET,HEAD"
    end

    test "a volatile function allows only POST" do
      conn = request("OPTIONS", "/rpc/getallprojects", nil)

      assert conn.status == 200
      assert header(conn, "allow") == "OPTIONS,POST"
    end

    test "an immutable function allows GET, HEAD and POST" do
      conn = request("OPTIONS", "/rpc/noparamsproc", nil)

      assert header(conn, "allow") == "OPTIONS,GET,HEAD,POST"
    end

    test "an unknown table is a PGRST205 404" do
      conn = request("OPTIONS", "/unknown", nil)

      assert conn.status == 404
      assert %{"code" => "PGRST205"} = json(conn)
    end

    test "an unknown function is a PGRST202 404" do
      conn = request("OPTIONS", "/rpc/nonexistent", nil)

      assert conn.status == 404
      assert %{"code" => "PGRST202"} = json(conn)
    end

    test "select and limit are not parsed" do
      assert request("OPTIONS", "/items?select=(&limit=abc", nil).status == 200
    end

    test "a malformed filter or order is a PGRST100 400 on every path, before the lookup" do
      for path <- [
            "/items?x=1",
            "/items?order=x.foo",
            "/unknown?x=1",
            "/?x=1",
            "/rpc/getallprojects?x=1"
          ] do
        conn = request("OPTIONS", path, nil)

        assert conn.status == 400, path
        assert %{"code" => "PGRST100"} = json(conn)
      end
    end

    test "a resource's custom params are not filters" do
      start_supervised!(
        {PgRest.Registry, name: __MODULE__.Custom, modules: [SQLResources.Custom]},
        id: :custom
      )

      conn = request("OPTIONS", "/projects?name_like=a", nil, [], registry: __MODULE__.Custom)

      assert conn.status == 200
    end

    test "an unknown Accept-Profile is a PGRST106 406 on every path" do
      for path <- ["/", "/items", "/rpc/getallprojects"] do
        conn = request("OPTIONS", path, nil, [{"accept-profile", "nope"}], [])

        assert conn.status == 406, path
        assert %{"code" => "PGRST106"} = json(conn)
      end
    end

    test "the resource's allow: narrows Allow; GET and HEAD stay" do
      start_supervised!(
        {PgRest.Registry, name: __MODULE__.Narrow, modules: [PlugResources.NoRead]},
        id: :narrow
      )

      conn = request("OPTIONS", "/items", nil, [], registry: __MODULE__.Narrow)

      assert header(conn, "allow") == "OPTIONS,GET,HEAD,POST"
    end

    test "CORS preflight headers are not treated specially" do
      headers = [{"origin", "https://a.test"}, {"access-control-request-method", "POST"}]
      conn = request("OPTIONS", "/items", nil, headers, [])

      assert header(conn, "allow") == @all
      assert header(conn, "access-control-allow-origin") == nil
    end

    test "opens no transaction and runs no query: a repo that raises on both is not touched" do
      for path <- ["/items", "/", "/rpc/getallprojects"] do
        conn = request("OPTIONS", path, nil, [], repo: PlugResources.DownRepo)

        assert conn.status == 200, path
      end
    end

    test "emits no [:pgrest, :query] event and calls no authorization" do
      TelemetryProbe.attach([[:pgrest, :query, :start], [:pgrest, :request, :stop]])

      for path <- ["/items", "/", "/rpc/getallprojects"] do
        assert request("OPTIONS", path, nil, [], authorization: Forbidden).status == 200
      end

      events = Enum.map(TelemetryProbe.drain(), &elem(&1, 0))
      assert events == List.duplicate([:pgrest, :request, :stop], 3)
    end

    test "the telemetry probe sees the query of a GET (positive control)" do
      TelemetryProbe.attach([:pgrest, :query, :start])

      assert request("GET", "/items?limit=1", nil).status == 200
      assert [{[:pgrest, :query, :start], _measurements, _metadata} | _] = TelemetryProbe.drain()
    end
  end

  describe "unsupported methods" do
    test "are a PGRST117 405, whatever the table" do
      for path <- ["/items", "/unknown", "/"] do
        conn = request("TRACE", path, nil)

        assert conn.status == 405

        assert %{"code" => "PGRST117", "message" => "Unsupported HTTP method: TRACE"} =
                 json(conn)
      end
    end

    test "a write method on the root is a PGRST117 405" do
      for method <- ~w(POST PUT PATCH DELETE) do
        conn = request(method, "/", nil)

        assert conn.status == 405, method
        assert %{"code" => "PGRST117"} = json(conn)
      end
    end

    test "the profile is checked first: a bad Accept-Profile is a PGRST106 406" do
      conn = request("TRACE", "/items", nil, [{"accept-profile", "nope"}], [])

      assert conn.status == 406
      assert %{"code" => "PGRST106"} = json(conn)
    end

    test "an invalid path stays a PGRST125 404" do
      assert %{"code" => "PGRST125"} = "TRACE" |> request("/a/b", nil) |> json()
    end
  end
end
