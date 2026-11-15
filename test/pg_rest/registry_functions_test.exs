defmodule PgRest.RegistryFunctionsTest do
  # Not async: captures registry logs and clears the compat repo's catalog cache.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import PgRest.PlugCase, only: [request: 5, json: 1]

  alias PgRest.{Catalog, Function, Registry}
  alias PgRest.Compat.Functions.GetStatus
  alias PgRest.Compat.{Repo, SupabaseRepo}
  alias PgRest.Compat.Resources.Projects
  alias PgRest.Compat.Supabase.Resources, as: SupabaseResources
  alias PgRest.Compat.Supabase.User, as: SupabaseUser
  alias PgRest.Registry.Snapshot
  alias PgRest.Test.Policies.AllowAll, as: Authz
  alias PgRest.Test.Policies.Neither, as: NotAResource
  alias PgRest.Test.SQLResources.Keyless
  alias PgRest.Test.SQLResources.Where, as: ScopedProject

  defmodule QueryOnly do
    @moduledoc false
    def authorize_query(_conn, _resource, _op, _query, _ctx), do: :ok
  end

  defmodule DownRepo do
    @moduledoc false
    def in_transaction?, do: false
    def transaction(fun, _opts), do: {:ok, fun.()}

    def query!(_sql, _params, _opts),
      do: raise(DBConnection.ConnectionError, "connection not available")
  end

  defmodule FlakyRepo do
    @moduledoc false
    # Unreachable while `:pgrest_flaky_repo_down?` is set, the compat repo otherwise.
    def in_transaction?, do: Repo.in_transaction?()
    def transaction(fun, opts), do: Repo.transaction(fun, opts)

    def query!(sql, params, opts) do
      if Application.get_env(:pgrest, :pgrest_flaky_repo_down?, false),
        do: raise(DBConnection.ConnectionError, "connection not available"),
        else: Repo.query!(sql, params, opts)
    end
  end

  @name __MODULE__.Reg

  defp start(opts) do
    start_supervised!({Registry, Keyword.put_new(opts, :name, @name)})
    {:ok, snap} = Registry.snapshot(Keyword.get(opts, :name, @name))
    snap
  end

  defp start_link_error(opts) do
    Registry.start_link(Keyword.put_new(opts, :name, @name))
  end

  defp introspect(opts), do: Keyword.merge([repo: Repo], opts)

  describe "introspection exposure (S-C1)" do
    test "mode :app needs only:, except: or an authorize/4 module" do
      message = ~r/only:.*except:.*authorize\/4/

      assert_raise ArgumentError, message, fn ->
        start_link_error(modules: [Projects], introspect: introspect([]))
      end

      assert_raise ArgumentError, message, fn ->
        start_link_error(modules: [Projects], introspect: introspect(authorization: QueryOnly))
      end

      snap = start(modules: [Projects], introspect: introspect(authorization: Authz))
      assert [%Function{}] = Snapshot.functions(snap, "test", "add_them")

      assert snap.introspection == %{
               mode: :app,
               as_role: nil,
               authorization: Authz,
               filtered?: false
             }
    end

    test "only: and except:" do
      snap = start(modules: [Projects], introspect: introspect(only: ["add_them"]))
      assert Map.keys(snap.functions) == [{"test", "add_them"}]
      stop_supervised!(@name)

      snap = start(modules: [Projects], introspect: introspect(except: ["add_them"]))
      assert snap.functions[{"test", "add_them"}] == nil
      assert [_] = Snapshot.functions(snap, "test", "getallprojects")
      refute Map.has_key?(snap.functions, {"test", "similarity"})
      refute Map.has_key?(snap.functions, {"test", "touch_updated_at"})
    end

    test "mode :rls without as_role: keeps every function, as PostgREST's schema cache" do
      snap = start(modules: [Projects], introspect: introspect(mode: :rls))
      assert %{mode: :rls, as_role: nil, filtered?: false} = snap.introspection
      assert [_] = Snapshot.functions(snap, "test", "getallprojects")
      stop_supervised!(@name)

      snap = start(modules: [Projects], introspect: introspect(mode: :rls, as_role: "postgres"))
      assert %{mode: :rls, as_role: ["postgres"], filtered?: false} = snap.introspection
    end

    test "as_role: filters by EXECUTE" do
      supabase = SupabaseResources.all()
      base = [repo: SupabaseRepo, schemas: ["public"], only: ["privileged_hello"]]

      log =
        capture_log(fn ->
          snap =
            start(
              modules: supabase,
              schemas: ["public", "personal"],
              introspect: base ++ [as_role: "anon"]
            )

          assert snap.functions == %{}
        end)

      # The as_role filter, not a typo, dropped the only: name; the warning says so.
      assert log =~ "only: privileged_hello"
      stop_supervised!(@name)

      snap =
        start(
          modules: supabase,
          schemas: ["public", "personal"],
          introspect: base ++ [as_role: ["anon", "authenticated"]]
        )

      assert [_] = Snapshot.functions(snap, "public", "privileged_hello")
    end

    test "an rls: plug fails closed unless as_role: is within roles: and holds default_role (C7)" do
      rls = [roles: ["anon", "authenticated"], jwt: :context, allow_privileged_login: true]

      for as_role <- [["anon", "postgres"], ["authenticated"]] do
        start(modules: [Projects], introspect: introspect(mode: :rls, as_role: as_role))

        log =
          capture_log(fn ->
            conn = request("GET", "/projects", nil, [], registry: @name, rls: rls)
            assert conn.status == 500
          end)

        assert log =~ "as_role"
        stop_supervised!(@name)
      end

      start(modules: [Projects], introspect: introspect(mode: :rls, as_role: ["anon"]))

      refute capture_log(fn ->
               request("GET", "/projects", nil, [], registry: @name, rls: rls)
             end) =~
               "as_role"
    end

    test "a plug without rls: serving a mode :rls registry with no only:/except: fails closed" do
      start(modules: [Projects], introspect: introspect(mode: :rls, as_role: ["postgres"]))

      log =
        capture_log(fn ->
          for _ <- 1..2 do
            conn = request("GET", "/projects", nil, [], registry: @name)
            assert conn.status == 500
            assert %{"code" => "PGRSTX00"} = json(conn)
          end
        end)

      # Every request fails; the cause is logged once per snapshot generation.
      assert [_] = Regex.scan(~r/mode: :rls/, log)

      for _ <- 1..2 do
        assert :ok = Registry.reload(@name)

        assert capture_log(fn -> request("GET", "/projects", nil, [], registry: @name) end) =~
                 "mode: :rls"
      end

      # Two reloads while misconfigured still leave one flag key for the registry.
      assert [{_key, generation}] =
               for(
                 {{PgRest.Plug, :introspection_mismatch, @name}, _} = entry <-
                   :persistent_term.get(),
                 do: entry
               )

      assert {:ok, %Snapshot{generation: ^generation}} = Registry.snapshot(@name)
    end

    test "the plug's :authorization must be the registry's" do
      start(modules: [Projects], introspect: introspect(authorization: Authz))

      log =
        capture_log(fn ->
          assert request("GET", "/projects", nil, [], registry: @name).status == 500
        end)

      assert log =~ inspect(Authz)

      conn = request("GET", "/projects?id=eq.1", nil, [], registry: @name, authorization: Authz)
      assert conn.status == 200
    end
  end

  describe "declared functions" do
    test "a module replaces the introspected overload with the same param names" do
      snap =
        start(
          modules: SupabaseResources.all(),
          schemas: ["public", "personal"],
          functions: [GetStatus],
          introspect: [repo: SupabaseRepo, only: ["get_status", "void_func"]]
        )

      assert [%Function{module: GetStatus}] = Snapshot.functions(snap, "public", "get_status")
      assert [%Function{module: nil}] = Snapshot.functions(snap, "personal", "get_status")
      assert [%Function{module: nil}] = Snapshot.functions(snap, "public", "void_func")
    end

    test "declared functions work without introspection" do
      snap = start(modules: [SupabaseUser], functions: [GetStatus])
      assert [%Function{module: GetStatus}] = Snapshot.functions(snap, "public", "get_status")
      assert snap.introspection == nil
    end

    test "a module that is not a function raises" do
      assert_raise ArgumentError, ~r/not a PgRest.Function/, fn ->
        start_link_error(modules: [Projects], functions: [Projects])
      end
    end
  end

  describe "static result-scope checks" do
    test "a volatile function returning a custom-scoped resource needs result_scope: :none" do
      opts = [modules: [ScopedProject], introspect: introspect(only: ["make_project"])]

      assert_raise ArgumentError, ~r/test\.make_project.*result_scope: :none/s, fn ->
        start_link_error(opts)
      end

      function_opts = %{{"test", "make_project"} => [result_scope: :none]}

      log =
        capture_log(fn ->
          snap = start(Keyword.put(opts, :function_opts, function_opts))

          assert [%Function{result_scope: :none}] =
                   Snapshot.functions(snap, "test", "make_project")
        end)

      assert [_] = Regex.scan(~r/without result scoping/, log)

      assert log =~
               "PgRest: functions test.make_project return resource rows without result scoping"
    end

    test "a custom-scoped resource without a key fails on the existing resource check (G14)" do
      assert_raise ArgumentError, ~r/no primary key and no :unique_key/, fn ->
        start_link_error(modules: [Keyless], introspect: introspect(only: ["add_them"]))
      end
    end

    test "an unknown result_scope raises" do
      assert_raise ArgumentError, ~r/invalid result_scope :bogus/, fn ->
        start_link_error(
          modules: [Projects],
          introspect: introspect(only: ["add_them"]),
          function_opts: %{{"test", "add_them"} => [result_scope: :bogus]}
        )
      end
    end

    test "registry start never calls scope/2" do
      # `ScopedProject.scope/2` raises (`KeyError` on `ctx.client_id`) for any context without
      # a client, and registry start has no request context: a call would fail the start.
      snap = start(modules: [ScopedProject], introspect: introspect(only: ["scoped_projects"]))

      assert [%Function{volatility: :stable, returns: %{resource: ScopedProject}}] =
               Snapshot.functions(snap, "test", "scoped_projects")
    end

    test "a declared resource return that is not a resource raises" do
      assert_raise ArgumentError, ~r/is not a PgRest.Resource/, fn ->
        PgRest.Function.build(__MODULE__,
          schema: "test",
          name: "f",
          returns: {:setof, NotAResource}
        )
      end
    end

    test "a function over a plain resource needs no option and logs nothing" do
      log =
        capture_log(fn ->
          start(modules: [Projects], introspect: introspect(only: ["getallprojects"]))
        end)

      refute log =~ "result scoping"
    end
  end

  describe "loading" do
    test "reload/1 re-introspects and forgets the repo's catalog cache" do
      start(modules: [Projects], introspect: introspect(only: ["add_them"]))
      _facts = Catalog.facts(Repo)
      assert :persistent_term.get({Catalog, Repo, :facts, :server}, nil)

      assert :ok = Registry.reload(@name)
      assert :persistent_term.get({Catalog, Repo, :facts, :server}, nil) == nil

      assert {:ok, %Snapshot{functions: %{{"test", "add_them"} => [_]}}} =
               Registry.snapshot(@name)
    end

    test "an unreachable database leaves PGRST002 and retries with a warning" do
      log =
        capture_log(fn ->
          start_supervised!(
            {Registry,
             name: @name, modules: [Projects], introspect: [repo: DownRepo, only: ["x"]]}
          )

          assert {:error, %PgRest.Error{code: "PGRST002"}} = Registry.snapshot(@name)
          # start_link's attempt warned; a retry in the same outage stays quiet.
          send(Process.whereis(@name), :load)
          :sys.get_state(@name)
        end)

      assert [_] =
               Regex.scan(~r/could not introspect functions \(connection not available\)/, log)
    end

    test "a retry that reaches the database publishes the snapshot" do
      Application.put_env(:pgrest, :pgrest_flaky_repo_down?, true)
      on_exit(fn -> Application.delete_env(:pgrest, :pgrest_flaky_repo_down?) end)

      capture_log(fn ->
        start_supervised!(
          {Registry,
           name: @name, modules: [Projects], introspect: [repo: FlakyRepo, only: ["add_them"]]}
        )
      end)

      assert {:error, %PgRest.Error{code: "PGRST002"}} = Registry.snapshot(@name)

      Application.put_env(:pgrest, :pgrest_flaky_repo_down?, false)
      send(Process.whereis(@name), :load)
      :sys.get_state(@name)

      assert {:ok, %Snapshot{functions: %{{"test", "add_them"} => [_]}}} =
               Registry.snapshot(@name)
    end

    test "only: names and function_opts: keys that match no function are warned about" do
      log =
        capture_log(fn ->
          start(
            modules: [Projects],
            introspect: introspect(only: ["add_them", "add_thme"]),
            function_opts: %{{"test", "nope"} => [result_scope: :none]}
          )
        end)

      assert log =~ "match no introspected function: only: add_thme, function_opts: test.nope"
    end
  end
end
