defmodule PgRest.Planner do
  @moduledoc """
  Plans a read: validates the request against the registered resources and resolves it
  into a `PgRest.Plan.Read` tree, before any SQL runs.

  `plan_read/3` splits the query string into the select tree, root filters and logic
  trees, ordering, limits, embedded parameters (`<embed>.<column>=`, `<embed>.order=`,
  `<embed>.limit=`, `<embed>.or=`), embed null filters (`<embed>=is.null`) and declared
  custom params. Every column the request names is checked against the resource: an
  unknown one is PostgREST's `42703`, one outside the resource's `readable:` set a
  `42501`. Embeds are resolved through `PgRest.SchemaGraph`. When an `:authorization`
  module is configured it is asked about every resource path in the tree (root,
  embeds at every depth and many-to-many junctions) and the first denial fails the plan,
  before the catalog or the database is touched.

  Request column names are database column names; the plan holds Ecto field names,
  which is how the scoped sources expose their columns.

  The work is split by responsibility: `PgRest.Planner.Params` (query-string grouping),
  `PgRest.Planner.Columns` (per-resource column data and validation) and
  `PgRest.Planner.Tree` (resolution, authorization, the plan build and sources).

  ## Context

    * `:repo` - the Ecto repo (required)
    * `:graph` (required) - the `PgRest.SchemaGraph` of the request's schema
      (`PgRest.Registry.Snapshot.graph/2`); a missing graph raises `ArgumentError`
    * `:authorization` - a module implementing `PgRest.Authorization` (default: none)
    * `:max_limit` - clamps every node's row count (default: none)
    * `:max_embed_depth` - deepest embed nesting allowed (default `8`)
    * `:count_modes` - allowed `Prefer: count=` modes (default all three)
    * `:aggregates` - whether `select=` may use aggregate functions (default `false`: any
      aggregate is `PGRST123`)

  Catalog lookups happen here, so call this before opening a transaction.
  """

  alias PgRest.AST.Embed
  alias PgRest.{Auth, Error, Function, Options, Plan, Request, SchemaGraph}
  alias PgRest.Authorization.Apply
  alias PgRest.Planner.{Columns, Params, Tree}
  alias PgRest.RPC.Args
  alias PgRest.SQL.ScopedSource

  require Logger

  @doc """
  Plans a read of `resource` for `request`.

  Options: `authorize?` (default `true`) runs `PgRest.Authorization.check/5` for `:read` on
  every resource of the tree. Only `PgRest.Write` turns it off, for the target plan of a write
  that has already authorized what it needs. It is an option, never a context key, so nothing
  in the request context can switch authorization off. `root_alias` names the root in error
  messages instead of its table (`plan_call/3` uses `pgrst_call`).
  """
  @spec plan_read(Request.t(), module(), map(), keyword()) ::
          {:ok, Plan.Read.t()} | {:error, Error.t()}
  def plan_read(%Request{} = request, resource, context, opts \\ []) do
    plan_resource(request, resource, context, Keyword.put(opts, :skip_root_rows?, false))
  end

  defp plan_resource(request, resource, context, opts) do
    declared = resource.__pgrest_config__().custom_params

    with {:ok, items, groups} <- parse_request(request, declared, context),
         {:ok, raw} <- Tree.resolve(graph(context), resource, items, 1, []),
         :ok <- Tree.check_paths(raw, groups),
         :ok <- Tree.check_aggregates(raw, aggregates?(context)),
         {:ok, sources} <-
           Tree.authorize(
             raw,
             request,
             context,
             Keyword.put(opts, :custom_params, root_custom(groups))
           ),
         infos = infos(sources, context),
         {:ok, tree} <- Tree.build(root_alias(raw, opts), request, groups, infos, context, []) do
      {:ok, Tree.put_sources(tree, sources)}
    end
  end

  @doc """
  Plans an RPC: the read of the result of calling `function`, whose root reads the call
  (`source: {:call, PgRest.Plan.Call.t()}`) instead of a resource.

  The request's filter parameters (`PgRest.RPC.Args.split/2`) shape the result under the read
  rules:

    * a composite of a registered resource is planned by `plan_read/4` for that resource, so
      embeds, filters, order, limits and the `:read` authorization of the resource and every
      embed apply as for a table read. With `result_scope: :stored_rows` and a scope that is not
      the identity for this request, the call carries the scope its rows are checked against;
      a scoped resource without a key fails closed (`42501`);
    * any other composite validates columns against the function's result columns, and an
      embed is `PGRST200` (it has no relationships);
    * a scalar or void result has no columns, so any column a select, filter or order names is
      `42703`.

  Unknown columns are named under `pgrst_call` (the function's name for a scalar), as in
  PostgREST. Authorizing `:execute` on the function is the caller's job, before this.
  """
  @spec plan_call(Request.t(), Function.t(), map()) :: {:ok, Plan.Read.t()} | {:error, Error.t()}
  def plan_call(%Request{} = request, %Function{} = function, context) do
    invocation = Args.invocation(request)
    {_keys, filters} = Args.split(request, invocation)
    filtered = %{request | params: filters}

    call = %Plan.Call{
      function: function,
      args: Args.call_args(request, function),
      read_only?: invocation == :read or function.volatility in [:stable, :immutable]
    }

    with {:ok, plan, scope} <- plan_result(filtered, function, context) do
      {:ok, %{plan | source: {:call, %{call | scope: scope}}}}
    end
  end

  defp plan_result(request, %Function{returns: %{kind: :composite, resource: resource}} = f, ctx)
       when not is_nil(resource) do
    with {:ok, plan} <-
           plan_resource(request, resource, ctx,
             root_alias: "pgrst_call",
             skip_root_rows?: f.result_scope == :none
           ),
         {:ok, scope} <- result_scope(f, plan, ctx),
         do: {:ok, plan, scope}
  end

  defp plan_result(request, %Function{returns: %{kind: :composite, columns: columns}} = f, ctx) do
    with {:ok, plan} <- plan_columns(request, f, columns, "pgrst_call", ctx),
         do: {:ok, plan, nil}
  end

  defp plan_result(request, %Function{} = function, context) do
    with {:ok, plan} <- plan_columns(request, function, [], function.name, context) do
      scalar = %{key: "pgrst_scalar", field: "pgrst_scalar", json_path: [], cast: nil}
      {:ok, %{plan | select: [scalar]}, nil}
    end
  end

  # The result rows need checking against the stored rows only when the request's effective
  # source is not the identity.
  defp result_scope(%Function{result_scope: :none}, _plan, _context), do: {:ok, nil}

  defp result_scope(
         %Function{} = function,
         %Plan.Read{resource: resource, source_query: query},
         context
       ) do
    config = resource.__pgrest_config__()

    cond do
      ScopedSource.identity_scope?(resource, query) ->
        {:ok, nil}

      ScopedSource.key_fields(config) == [] ->
        Logger.error(
          "PgRest: function #{Function.label(function)} returns #{inspect(resource)}, whose " <>
            "scope applies but which has no primary key or unique_key: to match result rows by"
        )

        {:error, Error.table_denied(config, context)}

      true ->
        {:ok, {resource, query}}
    end
  end

  # A result that is no resource: its columns (`{name, type}`) are all readable, and nothing
  # embeds from it.
  defp plan_columns(request, function, columns, alias_name, context) do
    info = columns_info(columns, function.returns.categories, alias_name)

    with {:ok, items, groups} <- parse_request(request, [], context),
         :ok <- reject_embeds(items, function, graph(context)),
         {:ok, raw} <- Tree.resolve(graph(context), nil, items, 1, []),
         :ok <- Tree.check_paths(raw, groups),
         :ok <- Tree.check_aggregates(raw, aggregates?(context)),
         raw = Map.put(raw, :alias, alias_name),
         {:ok, tree} <- Tree.build(raw, request, groups, %{nil => info}, context, []) do
      {:ok, %{tree | alias: "pgrst_t0"}}
    end
  end

  defp columns_info(columns, categories, table) do
    names = Enum.map(columns, &elem(&1, 0))

    %{
      config: %{readable: MapSet.new(names)},
      table: table,
      columns: Enum.map(names, &{&1, &1}),
      by_source: Map.new(names, &{&1, &1}),
      types: Map.new(columns),
      categories: categories
    }
  end

  defp reject_embeds(items, %Function{schema: schema, returns: returns}, graph) do
    case Enum.find(items, &match?(%Embed{}, &1)) do
      nil ->
        :ok

      %Embed{name: name, hint: hint} ->
        {:error, SchemaGraph.no_relationship_from(graph, schema, returns.type, name, hint)}
    end
  end

  defp root_alias(raw, opts) do
    case Keyword.get(opts, :root_alias) do
      nil -> raw
      name -> Map.put(raw, :alias, name)
    end
  end

  defp aggregates?(context),
    do: Map.get_lazy(context, :aggregates, fn -> Options.default(:aggregates) end)

  defp max_depth(context),
    do: Map.get_lazy(context, :max_embed_depth, fn -> Options.default(:max_embed_depth) end)

  # Fails closed: without the request schema's graph there is no safe embed resolution.
  defp graph(%{graph: %SchemaGraph{} = graph}), do: graph

  defp graph(_context) do
    raise ArgumentError,
          "PgRest.Planner needs the request's schema graph in context.graph " <>
            "(PgRest.Plug sets it from the registry snapshot)"
  end

  defp root_custom(groups), do: groups |> Params.root() |> Map.fetch!(:custom) |> Enum.reverse()

  # The catalog is read in each resource's effective schema (the scope's prefix first). Each info
  # carries the request's role, for the status of a column outside `readable:`.
  defp infos(sources, context) do
    role = Auth.role(context)

    Map.new(sources, fn {key, policy} ->
      module = policy.resource
      schema = ScopedSource.effective_schema(module, policy.query)
      info = Columns.info(module, context.repo, schema)

      readable =
        for {_source, field} <- info.columns,
            Apply.column_allowed?(policy.columns, module, field),
            MapSet.member?(info.config.readable, field),
            do: field

      info = %{info | config: %{info.config | readable: MapSet.new(readable)}}
      {key, info |> Map.put(:role, role) |> Map.put(:policy, policy)}
    end)
  end

  # The select tree and the grouped query parameters of a request, with its embed depth and
  # count mode checked.
  defp parse_request(request, declared, context) do
    params = Params.string_pairs(request.params)

    with {:ok, items} <- Params.parse_select(params),
         :ok <- check_depth(items, max_depth(context)),
         :ok <- check_count(request.prefer.count, context),
         {:ok, groups} <- Params.group(params, declared),
         do: {:ok, items, groups}
  end

  defp check_depth(items, max) do
    if embed_depth(items) > max,
      do: {:error, Error.parse_error("embedding depth exceeds #{max}")},
      else: :ok
  end

  defp embed_depth(items), do: items |> Enum.map(&item_depth/1) |> Enum.max(fn -> 0 end)

  defp item_depth(%Embed{select: select}), do: 1 + embed_depth(select)
  defp item_depth(_item), do: 0

  defp check_count(nil, _context), do: :ok

  defp check_count(mode, context) do
    if mode in Map.get_lazy(context, :count_modes, fn -> Options.default(:count_modes) end),
      do: :ok,
      else: {:error, Error.parse_error("count=#{mode} is not allowed")}
  end
end
