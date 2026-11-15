defmodule PgRest.Registry do
  @moduledoc """
  GenServer that discovers PgRest resources and database functions at startup and publishes
  them as an immutable `PgRest.Registry.Snapshot`.

  The snapshot lives in `:persistent_term` under `{PgRest.Registry, name}`, so requests read it
  without going through the process. Each registry is named (`PgRest.Registry` by default);
  `PgRest.Plug`'s `:registry` option picks the one a plug serves, so several registries (for
  different apps or databases) run side by side. The registry owns no ETS table: the caches
  every plug shares belong to `PgRest.Cache`.

  ## Functions

  Functions reach the snapshot from modules (`functions:`, see `PgRest.Function`) and from
  `pg_proc` (`introspect:`, see `PgRest.Function.Introspect`). A declared function replaces an
  introspected one with the same schema, name and parameter names.

  Introspection is never schema-wide by default. In `mode: :app` (calls run as the repo role,
  no grant is consulted) it needs `only:` or `except:`, or an `authorization:` module that
  exports `authorize/4`. In `mode: :rls` every function of the schemas is kept, as in
  PostgREST's schema cache (or only those `as_role:` may `EXECUTE`). That is safe because the
  `EXECUTE` grant is checked after the request's role switch, on every call; a function no API
  role may run is a `42501`, as in PostgREST, not a `PGRST202`. The plug's `rls:` must list every
  `as_role:` role. When the database cannot be reached the registry publishes nothing
  (requests get PostgREST's 503 `PGRST002`) and retries every second.
  """

  use GenServer

  alias PgRest.{Catalog, Error, Function, Options, SchemaGraph}
  alias PgRest.Function.Introspect
  alias PgRest.Registry.Snapshot

  require Logger

  @options [:name, :otp_app, :modules, :schemas, :functions, :introspect, :function_opts]
  @introspect_options [:repo, :schemas, :mode, :only, :except, :as_role, :authorization]
  @retry_ms 1_000

  @doc """
  Starts a registry.

  ## Options

    * `:name` - the registry's name (default `PgRest.Registry`)
    * `:otp_app` - application to scan for PgRest resources (auto-discovery)
    * `:modules` - explicit list of modules to register (skips discovery)
    * `:schemas` - the exposed schemas, in order; the first is the default schema of requests
      without an `Accept-Profile`/`Content-Profile` header. Defaults to the one schema the
      resources use (`"public"` when there are none). Required when the resources span
      several schemas, and every resource's schema must be listed.
    * `:functions` - modules that `use PgRest.Function` (default `[]`)
    * `:introspect` - load functions from `pg_proc`:
      * `:repo` (required) - the repo to read the catalog through
      * `:schemas` - the schemas to read (default: the registry's `:schemas`)
      * `:mode` - `:app` (default) or `:rls`
      * `:only` / `:except` - function names to keep / drop
      * `:as_role` - a role or roles; only functions one of them may `EXECUTE` are kept.
        Defaults to `nil` (no EXECUTE catalog filter), including in `mode: :rls`. In
        `mode: :rls` they must be within the plug's `rls: [roles: ...]` and include its
        `default_role`.
      * `:authorization` - the `PgRest.Authorization` module the serving plug uses; in
        `mode: :app`, one exporting `authorize/4` stands in for `only:`/`except:`
    * `:function_opts` - `%{{schema, name} => [result_scope: :stored_rows | :none]}` for
      introspected functions (every overload of the name; default `%{}`)

  Resources are keyed by `{schema, table}`, so the same table name may be registered in two
  schemas. Builds the relationship graph and validates resources and functions before the
  process starts, so a bad resource (or two resources for the same `schema.table`), a bad
  option or a function that fails a static check raises `ArgumentError` from `start_link/1`.
  Registry start never calls a resource's `scope/2`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    Options.validate_keys!(opts, @options, "PgRest.Registry")

    name = Keyword.get(opts, :name, __MODULE__)

    unless is_atom(name),
      do: raise(ArgumentError, "PgRest.Registry :name must be an atom, got #{inspect(name)}")

    configs = opts |> resources() |> tap(&validate!/1)
    schemas = schemas!(Keyword.get(opts, :schemas), configs)

    spec = %{
      name: name,
      schemas: schemas,
      configs: configs,
      declared: declared!(Keyword.get(opts, :functions, []), schemas),
      introspect: introspect!(Keyword.get(opts, :introspect), schemas),
      function_opts: function_opts!(Keyword.get(opts, :function_opts, %{}))
    }

    GenServer.start_link(__MODULE__, {spec, first_load(spec)}, name: name)
  end

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  The published snapshot of the registry `name`, or PostgREST's 503 `PGRST002` while there is
  none (the registry is not running, or has not loaded its functions yet).
  """
  @spec snapshot(atom()) :: {:ok, Snapshot.t()} | {:error, Error.t()}
  def snapshot(name \\ __MODULE__) do
    case :persistent_term.get({__MODULE__, name}, nil) do
      %Snapshot{} = snap -> {:ok, snap}
      nil -> {:error, Error.schema_cache_not_ready()}
    end
  end

  @doc """
  Rebuilds and republishes the snapshot of the registry `name`: re-introspects its functions
  and forgets the introspection repo's `PgRest.Catalog` cache. On failure the previous
  snapshot stays published.
  """
  @spec reload(atom()) :: :ok | {:error, term()}
  def reload(name \\ __MODULE__) do
    GenServer.call(name, :reload, 30_000)
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Looks up a resource of the default registry by table name (in its default schema) or by
  module.
  """
  @spec get_resource(String.t() | module()) :: {:ok, map()} | {:error, :not_found}
  def get_resource(table_or_module) do
    with {:ok, snap} <- snapshot(),
         {:ok, config} <- find(snap, table_or_module) do
      {:ok, config}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "All resource configs of the default registry."
  @spec list_resources() :: [map()]
  def list_resources do
    case snapshot() do
      {:ok, snap} -> Map.values(snap.resources)
      {:error, _} -> []
    end
  end

  @doc """
  The relationship graph of the default registry (all schemas). Raises when it is not running.
  """
  @spec graph() :: SchemaGraph.t()
  def graph do
    case snapshot() do
      {:ok, snap} -> snap.graph
      {:error, error} -> raise error
    end
  end

  defp find(snap, table) when is_binary(table),
    do: Map.fetch(snap.resources, {snap.default_schema, table})

  defp find(snap, module) when is_atom(module), do: Map.fetch(snap.by_module, module)

  @impl GenServer
  def init({spec, snapshot}) do
    # Trapped so `terminate/2` unpublishes the snapshot when the supervisor stops us.
    Process.flag(:trap_exit, true)

    case snapshot do
      %Snapshot{} -> publish(snapshot)
      nil -> Process.send_after(self(), :load, @retry_ms)
    end

    # `outage?`: the last load could not reach the database (and said so once).
    {:ok, %{spec: spec, outage?: snapshot == nil}}
  end

  @impl GenServer
  def handle_call(:reload, _from, %{spec: spec} = state) do
    forget_catalog(spec)

    reply =
      case load(spec) do
        {:ok, snapshot} -> publish(snapshot)
        {:error, exception} -> {:error, exception}
      end

    {:reply, reply, state}
  rescue
    exception in ArgumentError -> {:reply, {:error, exception}, state}
  end

  @impl GenServer
  def handle_info(:load, %{spec: spec, outage?: outage?} = state) do
    case load!(spec) do
      {:ok, snapshot} ->
        publish(snapshot)
        {:noreply, %{state | outage?: false}}

      {:error, exception} ->
        unless outage?, do: warn_retry(spec, exception)
        Process.send_after(self(), :load, @retry_ms)
        {:noreply, %{state | outage?: true}}
    end
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl GenServer
  def terminate(_reason, %{spec: %{name: name}}) do
    :persistent_term.erase({__MODULE__, name})
    :ok
  end

  defp publish(%Snapshot{name: name} = snapshot),
    do: :persistent_term.put({__MODULE__, name}, snapshot)

  defp forget_catalog(%{introspect: %{repo: repo}}), do: Catalog.forget(repo)
  defp forget_catalog(_spec), do: :ok

  # The first load runs in the caller of `start_link/1`, so a static check raises there. An
  # unreachable database is retried by the process.
  defp first_load(spec) do
    case load!(spec) do
      {:ok, snapshot} ->
        snapshot

      {:error, exception} ->
        warn_retry(spec, exception)
        nil
    end
  end

  # `load/1`, where only an unreachable database is an `{:error, _}` (retried). Any other
  # database error is a configuration problem (an unknown `as_role:` role, say) and raises,
  # at start and on a retry alike.
  defp load!(spec) do
    with {:error, exception} <- load(spec) do
      unless Introspect.transient?(exception) do
        raise ArgumentError,
              "PgRest.Registry #{inspect(spec.name)} could not introspect functions: " <>
                Exception.message(exception)
      end

      {:error, exception}
    end
  end

  defp warn_retry(%{name: name}, exception) do
    Logger.warning(
      "PgRest.Registry #{inspect(name)} could not introspect functions " <>
        "(#{Exception.message(exception)}); retrying every #{@retry_ms} ms"
    )
  end

  defp load(%{name: name, schemas: schemas, configs: configs} = spec) do
    with {:ok, introspected} <- introspect(spec) do
      warn_unmatched(spec, introspected)
      functions = merge(introspected, spec.declared)
      check_functions!(functions, configs)
      warn_unscoped(functions)

      {:ok,
       Snapshot.build(name, schemas, configs,
         functions: functions,
         introspection: introspection(spec.introspect)
       )}
    end
  end

  # An `only:` name or `function_opts:` key that matches no introspected function is most
  # likely a typo; say so (a mistyped `result_scope: :none` silently keeps the default).
  defp warn_unmatched(%{introspect: nil}, _introspected), do: :ok

  defp warn_unmatched(%{name: name, introspect: introspect} = spec, introspected) do
    found = MapSet.new(introspected, &{&1.schema, &1.name})
    names = MapSet.new(found, fn {_schema, name} -> name end)

    unmatched =
      for(only <- introspect.only || [], not MapSet.member?(names, only), do: "only: #{only}") ++
        for {schema, fname} = key <- Map.keys(spec.function_opts),
            not MapSet.member?(found, key),
            do: "function_opts: #{schema}.#{fname}"

    if unmatched != [] do
      Logger.warning(
        "PgRest.Registry #{inspect(name)}: these entries match no introspected function: " <>
          Enum.join(unmatched, ", ")
      )
    end

    :ok
  end

  defp introspect(%{introspect: nil}), do: {:ok, []}

  defp introspect(%{introspect: introspect, configs: configs, function_opts: function_opts}) do
    filter = Map.take(introspect, [:only, :except, :as_role])

    with {:ok, functions} <- Introspect.load(introspect.repo, introspect.schemas, configs, filter) do
      {:ok, Enum.map(functions, &apply_function_opts(&1, function_opts))}
    end
  end

  defp apply_function_opts(%Function{schema: schema, name: name} = function, function_opts) do
    case Map.fetch(function_opts, {schema, name}) do
      {:ok, opts} -> %{function | result_scope: opts[:result_scope]}
      :error -> function
    end
  end

  defp introspection(nil), do: nil

  defp introspection(introspect),
    do: Map.take(introspect, [:mode, :as_role, :authorization, :filtered?])

  # A declared function replaces the introspected overload with the same parameter names.
  defp merge(introspected, declared) do
    keys = MapSet.new(declared, &overload_key/1)
    Enum.reject(introspected, &MapSet.member?(keys, overload_key(&1))) ++ declared
  end

  defp overload_key(%Function{schema: schema, name: name, params: params}),
    do: {schema, name, Enum.map(params, & &1.name)}

  # Static result-scope checks: they read only compile-time facts (`custom_scope?`), never
  # call `scope/2`. Whether a scope narrows anything is decided per request.
  defp check_functions!(functions, configs) do
    by_module = Map.new(configs, &{&1.module, &1})

    for %Function{returns: %{resource: resource}} = function <- functions, resource do
      Function.result_scope!(function.result_scope, Function.label(function))

      config =
        Map.get(by_module, resource) ||
          raise ArgumentError,
                "function #{Function.label(function)} returns #{inspect(resource)}, which " <>
                  "this registry does not register"

      check_volatile!(function, config)
    end

    :ok
  end

  defp check_volatile!(
         %Function{result_scope: :stored_rows, volatility: :volatile} = function,
         %{custom_scope?: true, module: module}
       ) do
    raise ArgumentError,
          "function #{Function.label(function)} is VOLATILE and returns rows of " <>
            "#{inspect(module)}, which defines scope/2; stored-row matching cannot see rows " <>
            "the function itself writes. Declare `result_scope: :none` (in `use " <>
            "PgRest.Function` or the registry's `function_opts:`)."
  end

  defp check_volatile!(_function, _config), do: :ok

  defp warn_unscoped(functions) do
    case for(%Function{result_scope: :none, returns: %{resource: r}} = f <- functions, r, do: f) do
      [] ->
        :ok

      unscoped ->
        labels = unscoped |> Enum.map(&Function.label/1) |> Enum.uniq() |> Enum.join(", ")

        Logger.warning(
          "PgRest: functions #{labels} return resource rows without result scoping; they " <>
            "trust the function for row visibility; result resource grants still apply"
        )
    end
  end

  defp declared!(modules, schemas) when is_list(modules) do
    functions = Enum.map(modules, &declared_function!/1)

    for %Function{schema: schema} = function <- functions, schema not in schemas do
      raise ArgumentError,
            "function #{Function.label(function)} is in schema #{inspect(schema)}, which is " <>
              "not in :schemas #{inspect(schemas)}"
    end

    for {{schema, name, _params}, [_, _ | _]} <- Enum.group_by(functions, &overload_key/1) do
      raise ArgumentError, "several modules declare the same overload of #{schema}.#{name}"
    end

    functions
  end

  defp declared!(other, _schemas),
    do: raise(ArgumentError, "invalid PgRest.Registry :functions: #{inspect(other)}")

  defp declared_function!(module) do
    unless Options.exports?(module, :__pgrest_function__, 0),
      do: raise(ArgumentError, "#{inspect(module)} is not a PgRest.Function")

    module.__pgrest_function__()
  end

  defp introspect!(nil, _schemas), do: nil

  defp introspect!(opts, registry_schemas) when is_list(opts) do
    Options.validate_keys!(opts, @introspect_options, "PgRest.Registry :introspect")

    introspect = %{
      repo: introspect_repo!(opts[:repo]),
      schemas:
        introspect_schemas!(Keyword.get(opts, :schemas, registry_schemas), registry_schemas),
      mode: introspect_mode!(Keyword.get(opts, :mode, :app)),
      only: names!(:only, Keyword.get(opts, :only)),
      except: names!(:except, Keyword.get(opts, :except, [])),
      as_role: as_role!(Keyword.get(opts, :as_role)),
      authorization: authorization!(Keyword.get(opts, :authorization))
    }

    filtered? = introspect.only != nil or introspect.except != []
    exposure!(introspect, filtered?)
    Map.put(introspect, :filtered?, filtered?)
  end

  defp introspect!(other, _schemas),
    do: raise(ArgumentError, "invalid PgRest.Registry :introspect: #{inspect(other)}")

  defp introspect_repo!(repo) when is_atom(repo) and not is_nil(repo), do: repo

  defp introspect_repo!(repo),
    do: raise(ArgumentError, "PgRest.Registry :introspect needs :repo, got #{inspect(repo)}")

  defp introspect_schemas!([_ | _] = schemas, registry_schemas) do
    unless Enum.all?(schemas, &(&1 in registry_schemas)) do
      raise ArgumentError,
            "PgRest.Registry :introspect schemas #{inspect(schemas)} must be among :schemas " <>
              inspect(registry_schemas)
    end

    schemas
  end

  defp introspect_schemas!(schemas, _registry_schemas),
    do: raise(ArgumentError, "invalid PgRest.Registry :introspect schemas: #{inspect(schemas)}")

  defp introspect_mode!(mode) when mode in [:app, :rls], do: mode

  defp introspect_mode!(mode),
    do: raise(ArgumentError, "invalid PgRest.Registry :introspect mode: #{inspect(mode)}")

  defp names!(:only, nil), do: nil

  defp names!(key, names) do
    unless Options.strings?(names),
      do: raise(ArgumentError, "PgRest.Registry :introspect #{key}: must be a list of names")

    names
  end

  defp as_role!(nil), do: nil
  defp as_role!(role) when is_binary(role), do: [role]

  defp as_role!(roles) do
    unless Options.strings?(roles) and roles != [],
      do: raise(ArgumentError, "invalid PgRest.Registry :introspect as_role: #{inspect(roles)}")

    roles
  end

  defp authorization!(module) when is_atom(module), do: module

  defp authorization!(other),
    do:
      raise(ArgumentError, "invalid PgRest.Registry :introspect authorization: #{inspect(other)}")

  # S-C1: introspection never exposes a whole schema by default.
  defp exposure!(%{mode: :rls}, _filtered?), do: :ok
  defp exposure!(%{mode: :app}, true), do: :ok

  defp exposure!(%{mode: :app, authorization: auth, schemas: schemas}, false) do
    unless Options.exports?(auth, :authorize, 4) do
      raise ArgumentError,
            "PgRest.Registry :introspect in mode: :app would expose every function of " <>
              "#{inspect(schemas)}; pass only: or except:, or authorization: a module that " <>
              "exports authorize/4"
    end

    :ok
  end

  defp function_opts!(function_opts) when is_map(function_opts) do
    for {key, opts} <- function_opts do
      label =
        case key do
          {schema, name} when is_binary(schema) and is_binary(name) ->
            "#{schema}.#{name}"

          other ->
            raise ArgumentError, "invalid PgRest.Registry :function_opts key: #{inspect(other)}"
        end

      unless Keyword.keyword?(opts) and Keyword.keys(opts) -- [:result_scope] == [],
        do:
          raise(
            ArgumentError,
            "invalid PgRest.Registry :function_opts for #{label}: #{inspect(opts)}"
          )

      Function.result_scope!(Keyword.get(opts, :result_scope, :stored_rows), label)
    end

    Map.new(function_opts, fn {key, opts} ->
      {key, Keyword.put_new(opts, :result_scope, :stored_rows)}
    end)
  end

  defp function_opts!(other),
    do: raise(ArgumentError, "invalid PgRest.Registry :function_opts: #{inspect(other)}")

  defp resources(opts) do
    case Keyword.get(opts, :modules) do
      nil -> opts |> Keyword.fetch!(:otp_app) |> discover_resources()
      modules when is_list(modules) -> filter_resources(modules)
    end
  end

  defp schemas!(nil, configs) do
    case configs |> Enum.map(& &1.schema) |> Enum.uniq() |> Enum.sort() do
      [] ->
        ["public"]

      [schema] ->
        [schema]

      several ->
        raise ArgumentError, "resources span schemas #{inspect(several)}; pass :schemas"
    end
  end

  defp schemas!([_ | _] = schemas, configs) do
    unless Options.strings?(schemas) and Enum.uniq(schemas) == schemas,
      do: raise(ArgumentError, "invalid PgRest.Registry :schemas: #{inspect(schemas)}")

    for %{schema: schema, module: module} <- configs, schema not in schemas do
      raise ArgumentError,
            "#{inspect(module)} is in schema #{inspect(schema)}, which is not in :schemas " <>
              inspect(schemas)
    end

    schemas
  end

  defp schemas!(schemas, _configs),
    do: raise(ArgumentError, "invalid PgRest.Registry :schemas: #{inspect(schemas)}")

  # A custom `scope/2` narrows rows by an arbitrary predicate, so scoped mutations
  # re-select their rows by key; a table without a key has nothing to select by.
  defp validate!(configs) do
    for %{custom_scope?: true, primary_key: [], unique_key: nil, module: module} <- configs do
      raise ArgumentError,
            "#{inspect(module)} defines scope/2 but has no primary key and no :unique_key option; " <>
              "scoped mutations need a key. Add `unique_key: [...]` to `use PgRest.Resource`."
    end

    for {{schema, table}, [_, _ | _] = same} <-
          Enum.group_by(configs, &{&1.schema, &1.table}, & &1.module) do
      raise ArgumentError,
            "#{inspect(same)} are all #{inspect(schema)}.#{inspect(table)}; requests address " <>
              "resources by schema and table, so register only one of them"
    end

    :ok
  end

  defp discover_resources(otp_app) do
    {:ok, modules} = :application.get_key(otp_app, :modules)
    filter_resources(modules)
  end

  defp filter_resources(modules) do
    modules
    |> Enum.filter(fn mod ->
      Code.ensure_loaded(mod)
      function_exported?(mod, :__pgrest_resource__, 0) and mod.__pgrest_resource__()
    end)
    |> Enum.map(fn mod -> mod.__pgrest_config__() end)
  end
end
