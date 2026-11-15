defmodule PgRest.Planner.Tree do
  @moduledoc """
  The plan tree: embed resolution through the schema graph, authorization of every
  resource it touches, and the build of `PgRest.Plan.Read` nodes with their embeds.

  `resolve/5` produces raw nodes (`%{module, items, children, depth}`, a child being
  `%{embed, rel, out, node}`) without touching the database, so `authorize/4` can run on
  them before any catalog query. `authorize/4` computes the scoped query and policy once
  per node path (its effective schema decides where the catalog is read),
  `build/6` validates columns against the per-resource infos and builds the plan, and
  `put_sources/2` attaches the queries.

  ## Differences from PostgREST

  Output keys longer than 63 bytes or starting with ..., pgrst_ or _postgrest_
  are rejected to avoid alias collisions; duplicate embed output keys are rejected.

  Read errors may name the generated root alias pgrst_t0 instead of the table.
  Aggregates under to-one spreads with after_load/2 return PGRST127 because
  those columns are merged after SQL execution.
  """

  alias PgRest.AST.{Aggregate, Condition, Field, Logic, OrderTerm, SelectField}
  alias PgRest.AST.Embed, as: EmbedAST
  alias PgRest.{Authorization, Error, Plan, Request, SchemaGraph}
  alias PgRest.Authorization.Apply
  alias PgRest.Planner.{Columns, Params, Result}
  alias PgRest.Request.Range
  alias PgRest.SchemaGraph.Relationship
  alias PgRest.SQL.ScopedSource

  # --- embed resolution ----------------------------------------------------------

  @doc "Resolves every embed of the select tree through the graph."
  @spec resolve(SchemaGraph.t(), module(), list(), pos_integer(), [String.t()]) ::
          {:ok, map()} | {:error, Error.t()}
  def resolve(graph, module, items, depth, path) do
    {fields, embeds} = Enum.split_with(items, &(not match?(%EmbedAST{}, &1)))

    with {:ok, children} <-
           Result.map_ok(embeds, &resolve_embed(graph, module, &1, depth, path)) do
      {:ok, %{module: module, items: fields, children: children, depth: depth}}
    end
  end

  defp resolve_embed(graph, module, embed, depth, path) do
    name = embed.alias || embed.name

    with :ok <- reserved_key(name),
         {:ok, rel} <- SchemaGraph.resolve(graph, module, embed.name, embed.hint),
         {:ok, node} <- resolve(graph, rel.target, embed.select, depth + 1, path ++ [name]) do
      {:ok, %{embed: embed, rel: rel, out: name, node: node}}
    end
  end

  # Output keys may not collide with internal names. `...` prefixes the merge keys of
  # spreads and `pgrst_` / `_postgrest_` the generated aliases: a request key equal to
  # one would shadow it (Postgres resolves a bare name to a column before a row alias).
  # Keys also stay within Postgres's 63-byte identifier limit: longer ones would be
  # truncated (upstream does this silently), which could merge two keys. All are known
  # differences.
  defp reserved_key(name) when byte_size(name) > 63,
    do: {:error, Error.parse_error("output names may not exceed 63 bytes")}

  defp reserved_key(name) do
    case prefix(name) do
      nil -> :ok
      prefix -> {:error, Error.parse_error("output names may not start with #{inspect(prefix)}")}
    end
  end

  @reserved_prefixes ["...", "pgrst_", "_postgrest_"]

  defp prefix(name) do
    lowered = String.downcase(name)
    Enum.find(@reserved_prefixes, &String.starts_with?(lowered, &1))
  end

  @doc """
  Checks the aggregates of the raw tree. With aggregates disabled (`allowed?` false) any
  aggregate at any depth is `PGRST123`. Otherwise an aggregate a to-many spread would have to
  compute (its own, or one hoisted from a to-one spread below it) is `PGRST127`, as in
  PostgREST, and so is one in a to-one spread over an `after_load/2` subtree (a merge, which
  cannot hoist it), where PgRest fails closed. The legacy bare `count` is a plain field here:
  it is no aggregate to upstream.
  """
  @spec check_aggregates(map(), boolean()) :: :ok | {:error, Error.t()}
  def check_aggregates(raw, false) do
    if any_aggregate?(raw), do: {:error, Error.aggregates_not_allowed()}, else: :ok
  end

  def check_aggregates(raw, true) do
    case unhoistable_spread(raw) do
      nil -> :ok
      kind -> {:error, Error.spread_aggregate_not_implemented(kind)}
    end
  end

  defp any_aggregate?(%{items: items, children: children}),
    do: own_aggregate?(items) or Enum.any?(children, &any_aggregate?(&1.node))

  # The first spread at any depth that would have to compute an aggregate it cannot: a to-many
  # spread (`:to_many`), or a to-one spread planned as a merge because a resource of its subtree
  # has `after_load/2` (`:after_load`), whose columns reach the parent only after the query.
  defp unhoistable_spread(%{children: children}) do
    Enum.find_value(children, fn %{embed: embed, rel: rel, node: node} ->
      spread_kind(embed, rel, node) || unhoistable_spread(node)
    end)
  end

  defp spread_kind(%EmbedAST{spread: true}, rel, node) do
    cond do
      not spread_aggregate?(node) -> nil
      not Relationship.to_one?(rel) -> :to_many
      after_load?(node) -> :after_load
      true -> nil
    end
  end

  defp spread_kind(_embed, _rel, _node), do: nil

  # As `PgRest.Plan.Read.after_load?/1`, which decides the merge, over the raw tree.
  defp after_load?(%{module: module, children: children}),
    do: resource_after_load?(module) or Enum.any?(children, &after_load?(&1.node))

  defp resource_after_load?(nil), do: false
  defp resource_after_load?(module), do: module.__pgrest_config__().after_load

  # A node's own aggregates and those hoisted from the to-one spreads below it.
  defp spread_aggregate?(%{items: items, children: children}) do
    own_aggregate?(items) or
      Enum.any?(children, fn %{embed: embed, rel: rel, node: node} ->
        embed.spread and Relationship.to_one?(rel) and spread_aggregate?(node)
      end)
  end

  defp own_aggregate?(items), do: Enum.any?(items, &match?(%Aggregate{}, &1))

  @doc "Every embedded parameter must name an embed in the select (`PGRST108`)."
  @spec check_paths(map(), map()) :: :ok | {:error, Error.t()}
  def check_paths(raw, groups) do
    groups
    |> Map.keys()
    |> Enum.sort()
    |> Enum.find_value(:ok, fn path ->
      case walk(raw, path) do
        {:missing, name} -> {:error, Error.not_embedded(name)}
        :ok -> nil
      end
    end)
  end

  defp walk(_raw, []), do: :ok

  defp walk(raw, [name | rest]) do
    case Enum.find(raw.children, &(&1.out == name)) do
      nil -> {:missing, name}
      child -> walk(child.node, rest)
    end
  end

  # --- authorization -------------------------------------------------------------

  @doc "Authorizes each node path and operation and computes its effective source once."
  @spec authorize(map(), Request.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def authorize(raw, request, context, opts) do
    entries = authorized_modules(raw, [], Keyword.get(opts, :custom_params, []))

    with {:ok, {sources, _bases}} <-
           Result.reduce_ok(entries, {%{}, %{}}, &authorize_entry(&1, &2, request, context, opts)),
         do: {:ok, sources}
  end

  defp authorize_entry({key, module, path, params}, {sources, bases}, request, context, opts) do
    ctx = Map.merge(context, %{path: path, root?: path == []})

    source_opts = [
      authorize?: path != [] or Keyword.get(opts, :authorize?, true),
      rows?: path != [] or not Keyword.get(opts, :skip_root_rows?, false)
    ]

    cache_key = {module, path == []}

    base =
      reusable_base(Authorization.query_hook?(Map.get(context, :authorization)), bases, cache_key)

    with {:ok, source} <-
           cached_source(key, module, request, ctx, params, base, source_opts, opts) do
      {:ok,
       {Map.put(sources, key, Map.put(source, :resource, module)),
        Map.put(bases, cache_key, source.query)}}
    end
  end

  defp reusable_base(true, _bases, _key), do: nil
  defp reusable_base(false, bases, key), do: Map.get(bases, key)

  defp cached_source(key, module, request, context, params, base, source_opts, opts) do
    case Map.get(Keyword.get(opts, :policies, %{}), key) do
      nil ->
        node_source(module, request, context, params, base, source_opts)

      policy ->
        with %Ecto.Query{} = query <-
               ScopedSource.with_params(policy.query, module, context, params),
             do: {:ok, %{policy | query: query}}
    end
  end

  defp node_source(module, request, context, params, cached, opts) do
    with %Ecto.Query{} = base <- cached || ScopedSource.base_query(module, context, params),
         {:ok, _policy} = ok <-
           Apply.source(
             request.conn,
             Map.get(context, :authorization),
             module,
             :read,
             base,
             context,
             opts
           ) do
      ok
    else
      {:error, :denied} -> {:error, Error.table_denied(module, context)}
      {:error, %Error{}} = error -> error
    end
  end

  defp authorized_modules(%{module: module, children: children}, path, params) do
    [{{path, :read}, module, path, params} | Enum.flat_map(children, &child_modules(&1, path))]
  end

  defp child_modules(%{rel: rel, node: node, out: out}, parent) do
    path = parent ++ [out]

    junction =
      case rel.junction do
        nil ->
          []

        %{module: module} ->
          [{Plan.Read.junction_key(path), module, Plan.Read.junction_path(path, module), []}]
      end

    junction ++ authorized_modules(node, path, [])
  end

  @doc "Every resource module of the raw tree."
  @spec modules(map()) :: [module()]
  def modules(%{module: module, children: children}),
    do: [module | Enum.flat_map(children, &modules(&1.node))]

  # --- building ------------------------------------------------------------------

  @doc "Builds the `Plan.Read` for a raw node, children first."
  @spec build(map(), Request.t(), map(), map(), map(), [String.t()]) ::
          {:ok, Plan.Read.t()} | {:error, Error.t()}
  def build(raw, request, groups, infos, context, path) do
    info = Map.get_lazy(infos, {path, :read}, fn -> Map.fetch!(infos, raw.module) end)
    policy = Map.get_lazy(info, :policy, fn -> Apply.unrestricted(nil) end)
    group = Map.get(groups, path, Params.empty_group())
    root? = path == []
    alias_name = node_alias(raw, info, root?)
    names = MapSet.new(raw.children, & &1.out)

    with {:ok, children} <-
           Result.map_ok(raw.children, fn child ->
             build_embed(child, request, groups, infos, context, path, {info, alias_name, raw})
           end),
         {:ok, select} <- build_select(raw, info, alias_name, root?),
         :ok <- unique_keys(select, children),
         {:ok, where} <- build_where(group.where, info, alias_name, names),
         {:ok, order} <- build_order(group.order, info, alias_name, children),
         {:ok, window} <- window(root?, request, group.ranges),
         :ok <- policy_flags(select, children, request, info) do
      {:ok,
       %Plan.Read{
         resource: raw.module,
         alias: alias_name,
         select: select,
         where: where_tree(where),
         order: order,
         limit: window.limit,
         offset: window.offset,
         max_limit: Map.get(context, :max_limit),
         embeds: children,
         count: if(root?, do: request.prefer.count),
         custom_params: Enum.reverse(group.custom),
         column_types: info.types,
         categories: info.categories,
         aggregates?: aggregates?(select, children)
       }
       |> put_policy(policy)}
    end
  end

  defp policy_flags(select, children, request, info) do
    policy = Map.get_lazy(info, :policy, fn -> Apply.unrestricted(nil) end)
    aggregate? = Enum.any?(select, &Plan.Read.aggregate_entry?/1) or aggregates?(select, children)

    with :ok <- policy_flag(aggregate?, policy.aggregates?, info),
         do: policy_flag(request.prefer.count != nil, policy.count?, info)
  end

  defp policy_flag(false, _allowed?, _info), do: :ok
  defp policy_flag(true, true, _info), do: :ok

  defp policy_flag(true, false, info),
    do: {:error, Error.table_denied(%{table: info.table}, Map.get(info, :role, :anon))}

  # The table alias error messages name: the table, `<table>_<depth>` for an embed, or the
  # root's own `alias` when the raw node carries one (an RPC names its call `pgrst_call`).
  defp node_alias(%{alias: name}, _info, true), do: name
  defp node_alias(_raw, info, true), do: info.table
  defp node_alias(raw, info, false), do: "#{info.table}_#{raw.depth - 1}"

  # An embed's output key must be unique within its node: another output under the same
  # key (a column alias, a spread column, a second embed) would replace the embedded
  # sub-row in JSON, hiding it from `after_load/2` processing and from clients. Upstream
  # emits both; PgRest rejects the request (a documented difference). Plain columns and
  # spread columns may repeat each other, as in upstream (`*,id`, `name,...rel(name)`).
  defp unique_keys(select, children) do
    keys = Enum.map(select, & &1.key) ++ Enum.flat_map(children, &embed_keys/1)

    names =
      for %Plan.Embed{spread: false, merge: false} = embed <- children,
          not empty_plan?(embed.plan),
          do: embed.output_name

    case Enum.find(names, fn name -> Enum.count(keys, &(&1 == name)) > 1 end) do
      nil -> :ok
      key -> {:error, Error.parse_error("duplicate output key #{inspect(key)}")}
    end
  end

  # The keys an embed puts into its parent's rows: its own name, or a spread's columns.
  defp embed_keys(%Plan.Embed{spread: spread?, merge: merge?, plan: plan} = embed) do
    cond do
      spread? or merge? -> plan_keys(plan)
      empty_plan?(plan) -> []
      true -> [embed.output_name]
    end
  end

  defp plan_keys(%Plan.Read{select: select, embeds: embeds}),
    do: Enum.map(select, & &1.key) ++ Enum.flat_map(embeds, &embed_keys/1)

  defp empty_plan?(%Plan.Read{select: [], embeds: embeds}),
    do: Enum.all?(embeds, &empty_plan?(&1.plan))

  defp empty_plan?(_plan), do: false

  defp build_embed(child, request, groups, infos, context, path, {info, _parent_alias, raw}) do
    with {:ok, plan} <- build(child.node, request, groups, infos, context, path ++ [child.out]),
         :ok <- junction_flags(plan, request, infos, path ++ [child.out]) do
      {:ok, embed(child, plan, info.table, raw.depth)}
    end
  end

  defp junction_flags(plan, request, infos, path) do
    case Map.get(infos, Plan.Read.junction_key(path)) do
      nil -> :ok
      info -> policy_flags(plan.select, plan.embeds, request, info)
    end
  end

  defp embed(child, plan, parent_table, depth) do
    rel = child.rel
    merge? = child.embed.spread and Plan.Read.after_load?(plan)

    %Plan.Embed{
      relationship: rel,
      output_name: child.out,
      join: child.embed.join,
      spread: child.embed.spread and not merge?,
      merge: merge?,
      plan: plan,
      agg_alias: "#{parent_table}_#{child.out}_#{depth}"
    }
  end

  # The equalities between a node and its parent over exposed (Ecto field) names.
  defp join_conditions(%{junction: nil} = rel, {parent_alias, alias_name, _}) do
    pairs(
      {alias_name, rel.target, rel.target_columns},
      {parent_alias, rel.source, rel.source_columns}
    )
  end

  defp join_conditions(%{junction: junction} = rel, {parent_alias, alias_name, junction_alias}) do
    jmodule = junction.module

    pairs(
      {junction_alias, jmodule, junction.target_columns},
      {alias_name, rel.target, rel.target_columns}
    ) ++
      pairs(
        {junction_alias, jmodule, junction.source_columns},
        {parent_alias, rel.source, rel.source_columns}
      )
  end

  defp pairs({left_alias, left_module, left_columns}, {right_alias, right_module, right_columns}) do
    left_columns
    |> Enum.zip(right_columns)
    |> Enum.map(fn {left, right} ->
      {left_alias, Columns.exposed_name(left_module, left), right_alias,
       Columns.exposed_name(right_module, right)}
    end)
  end

  defp window(true, request, _ranges), do: {:ok, request.range}
  defp window(false, _request, ranges), do: Range.from("GET", [], ranges)

  defp where_tree([]), do: nil
  defp where_tree(children), do: %Logic{op: :and, children: children}

  # --- select --------------------------------------------------------------------

  defp build_select(%{items: [], children: []}, info, _alias_name, true), do: star(info)
  defp build_select(%{items: [], children: []}, _info, _alias_name, false), do: {:ok, []}

  defp build_select(%{items: items}, info, alias_name, _root?) do
    with {:ok, entries} <- Result.map_ok(items, &select_entries(&1, info, alias_name)),
         do: {:ok, Enum.concat(entries)}
  end

  defp star(info) do
    {:ok,
     for {source, name} <- info.columns, Columns.readable?(info, name) do
       %{key: source, field: name, json_path: [], cast: nil}
     end}
  end

  # The node selects an aggregate itself, or a to-one spread below it does (its aggregates are
  # hoisted into this node). The legacy bare `count` does not count, as in PostgREST.
  defp aggregates?(select, children) do
    Enum.any?(select, &Plan.Read.aggregate?/1) or
      Enum.any?(children, &(&1.spread and Plan.Embed.to_one?(&1) and &1.plan.aggregates?))
  end

  defp select_entries(%SelectField{field: :star}, info, _alias_name), do: star(info)

  # A bare `count` on a resource without a `count` column is PostgREST's backwards-compatible
  # `count()`: Postgres reads `t.count` as `count(t)`.
  defp select_entries(%SelectField{field: %Field{name: "count", json_path: []}} = item, info, _)
       when not is_map_key(info.by_source, "count") do
    key = item.alias || "count"

    with :ok <- reserved_key(key) do
      aggregate = %Aggregate{fun: :count, alias: key, cast: item.cast}
      {:ok, [%{key: key, aggregate: aggregate, legacy: true}]}
    end
  end

  defp select_entries(%Aggregate{} = aggregate, info, table_alias) do
    key = aggregate.alias || Atom.to_string(aggregate.fun)

    with :ok <- reserved_key(key),
         {:ok, field} <- aggregate_field(aggregate.field, info, table_alias) do
      {:ok, [%{key: key, aggregate: %{aggregate | field: field, alias: key}, legacy: false}]}
    end
  end

  defp select_entries(%SelectField{field: field} = item, info, table_alias) do
    key = item.alias || json_key(field) || field.name

    with :ok <- reserved_key(key),
         {:ok, translated} <- Columns.translate_field(field, info, table_alias) do
      {:ok,
       [
         %{
           key: key,
           field: translated.name,
           json_path: translated.json_path,
           cast: item.cast
         }
       ]}
    end
  end

  defp aggregate_field(nil, _info, _table_alias), do: {:ok, nil}

  defp aggregate_field(field, info, table_alias),
    do: Columns.translate_field(field, info, table_alias)

  # `data->a->>b` is named `b`; `data->0` is named after the last key, else the column.
  defp json_key(%Field{json_path: []}), do: nil

  defp json_key(%Field{json_path: path}) do
    case List.last(path) do
      {_arrow, key} when is_binary(key) ->
        key

      {_arrow, _index} ->
        Enum.find_value(Enum.reverse(path), fn {_arrow, key} -> is_binary(key) && key end)
    end
  end

  # --- filters -------------------------------------------------------------------

  defp build_where(items, info, alias_name, names),
    do: Result.map_ok(items, &where_item(&1, info, alias_name, names))

  defp where_item(%Logic{children: children} = logic, info, alias_name, names) do
    with {:ok, translated} <- build_where(children, info, alias_name, names) do
      {:ok, %{logic | children: translated}}
    end
  end

  # `embed=is.null` (and `not.is.null`) filters the parent by the embed's presence.
  defp where_item(
         %Condition{
           field: %Field{name: name, json_path: []},
           op: :is,
           value: :null,
           negate: negate
         } = condition,
         info,
         alias_name,
         names
       ) do
    if MapSet.member?(names, name),
      do: {:ok, {:null_embed, name, not negate}},
      else: translate_condition(condition, info, alias_name)
  end

  defp where_item(%Condition{} = condition, info, alias_name, _names),
    do: translate_condition(condition, info, alias_name)

  defp translate_condition(%Condition{field: field} = condition, info, alias_name) do
    with {:ok, translated} <- Columns.translate_field(field, info, alias_name) do
      {:ok, %{condition | field: translated}}
    end
  end

  # --- order ---------------------------------------------------------------------

  defp build_order(nil, _info, _alias_name, _children), do: {:ok, []}

  defp build_order(terms, info, alias_name, children),
    do: Result.map_ok(terms, &order_term(&1, info, alias_name, children))

  defp order_term(%OrderTerm{relation: nil, field: field} = term, info, alias_name, _children) do
    with {:ok, translated} <- Columns.translate_field(field, info, alias_name) do
      {:ok, %{term | field: translated}}
    end
  end

  defp order_term(%OrderTerm{relation: relation} = term, info, _alias, children) do
    case Enum.find(children, &(&1.output_name == relation)) do
      nil -> {:error, Error.not_embedded(relation)}
      embed -> related_order(term, embed, info)
    end
  end

  defp related_order(%OrderTerm{field: field} = term, embed, info) do
    cond do
      not Plan.Embed.to_one?(embed) ->
        {:error, Error.related_order_not_possible(info.table, term.relation)}

      Enum.any?(embed.plan.select, &(&1.key == field.name)) ->
        {:ok, term}

      hidden_related?(embed.plan, field.name) ->
        {:error, Error.table_denied(embed.plan.resource, Map.get(info, :role, :anon))}

      true ->
        {:error, Error.unknown_column(embed.agg_alias, field.name)}
    end
  end

  defp hidden_related?(plan, column) do
    config = plan.resource.__pgrest_config__()

    case Map.fetch(config.source_fields, column) do
      {:ok, field} ->
        not MapSet.member?(config.readable, field) or
          not Apply.column_allowed?(plan.allowed_columns, plan.resource, field)

      :error ->
        false
    end
  end

  # --- effective sources ---------------------------------------------------------

  @doc "Attaches the scoped Ecto queries of `sources/3` to the plan and numbers its embeds."
  @spec put_sources(Plan.Read.t(), map()) :: Plan.Read.t()
  def put_sources(tree, sources) do
    plan = attach(tree, [], sources)
    {numbered, _n} = number_embeds(%{plan | alias: "pgrst_t0"}, 0)
    numbered
  end

  # Gives every embed of the statement short generated names, in preorder: the lateral
  # (`pgrst_e<n>`), the merge key, the node's table alias (`pgrst_t<n>`, `pgrst_t0` for
  # the root) and the junction alias (`pgrst_j<n>`). They stay under Postgres's 63-byte
  # identifier limit whatever the table or alias names are (a truncated alias could equal
  # another and tie a child to every parent), and are deterministic, so the SQL text and
  # statement cache are stable. The join conditions are resolved here, once the aliases
  # are final.
  defp number_embeds(%Plan.Read{embeds: embeds} = plan, n) do
    {embeds, n} =
      Enum.map_reduce(embeds, n, fn embed, n ->
        id = n + 1
        child_alias = "pgrst_t#{id}"
        junction_alias = embed.relationship.junction && "pgrst_j#{id}"
        conditions = {plan.alias, child_alias, junction_alias}

        {child, next} = number_embeds(%{embed.plan | alias: child_alias}, id)

        numbered = %{
          embed
          | agg_alias: "pgrst_e#{id}",
            merge_key: "...m#{id}",
            junction_alias: junction_alias,
            join_conditions: join_conditions(embed.relationship, conditions),
            plan: child
        }

        {numbered, next}
      end)

    {%{plan | embeds: embeds}, n}
  end

  defp attach(%Plan.Read{} = plan, path, sources) do
    policy = Map.fetch!(sources, {path, :read})
    embeds = Enum.map(plan.embeds, &attach_embed(&1, path, sources))

    %{plan | source_query: policy.query, embeds: embeds} |> put_policy(policy)
  end

  defp put_policy(plan, policy) do
    %{
      plan
      | allowed_columns: policy.columns,
        hook_limit: policy.limit,
        aggregates_allowed?: policy.aggregates?,
        count_allowed?: policy.count?
    }
  end

  defp attach_embed(%Plan.Embed{} = embed, parent, sources) do
    path = parent ++ [embed.output_name]
    junction = Map.get(sources, Plan.Read.junction_key(path))
    plan = attach(embed.plan, path, sources)
    plan = cap_junction(plan, junction)

    %{
      embed
      | plan: plan,
        junction_source_query: junction && junction.query,
        junction_policy: junction
    }
  end

  defp cap_junction(plan, nil), do: plan

  defp cap_junction(plan, junction),
    do: %{plan | hook_limit: Apply.min_limit(plan.hook_limit, junction.limit)}
end
