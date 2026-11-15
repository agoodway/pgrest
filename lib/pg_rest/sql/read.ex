defmodule PgRest.SQL.Read do
  @moduledoc """
  Compiles a `PgRest.Plan.Read` tree to one SQL statement, mirroring PostgREST's
  `QueryBuilder.readPlanToQuery`.

  Every node reads `FROM (<scoped source>) AS <alias>`, the source being the resource's
  effective Ecto query (scope applied) spliced through `PgRest.SQL.ScopedSource`, so scope
  holds at every embed depth and on many-to-many junctions. Embeds are lateral joins,
  compiled by `PgRest.SQL.Read.Embed`.

  `LIMIT` and `OFFSET` are bind parameters (`$n::text::bigint`) at every node; with
  `max_limit` set the node's limit is `LEAST(<request limit>, <max_limit>)`.
  Select casts go through `PgRest.SQL.Builder.cast/2` and JSON-path keys are bound.

  `statement/3` wraps the root in PostgREST's `pgrst_source` shape and builds the JSON
  in Postgres as text. Permission-capped totals are exact for every count mode;
  otherwise a table's planned/estimated totals are filled in by the executor.
  """

  alias PgRest.AST.{Condition, Field, Logic}
  alias PgRest.Authorization.Apply
  alias PgRest.{Plan, ResponseGucs}
  alias PgRest.SQL.{Aggregate, Builder, Call, Format, ScopedSource, Where}
  alias PgRest.SQL.Read.Embed

  @type opts :: [
          source: {iodata(), Builder.t()},
          ctes: iodata(),
          extra: iodata(),
          inserted: iodata(),
          written: iodata(),
          matched: iodata()
        ]

  @doc """
  The full statement: `{sql, params}` returning `total`, `page_total` and `body` (text in the
  media type of `plan.output.media`: JSON, or CSV; a single-object type unwraps one row),
  then `response_headers` and `response_status` (`PgRest.ResponseGucs`, read after the main
  CTE in the same statement). A write's statement has its own columns between them.

  ## Options

    * `:source` - `{mutation_sql, builder}`: the `pgrst_source` CTE is that statement
      (a write's `RETURNING`, exposing columns under their Ecto field names) and the root
      reads `FROM pgrst_source`
    * `:ctes` - with `:source`, CTEs written before `pgrst_source`, each ending in `, `
    * `:extra` - with `:source`, one more select expression, returned as `pgrst_keys`
    * `:inserted` - with `:source`, one more select expression, returned as `pgrst_inserted`
    * `:written` - with `:source`, the number of rows the mutation wrote (before any
      embed filtering of the representation), returned as `pgrst_written`
    * `:matched` - with `:source`, the number of payload elements a `PUT` matched, returned as
      `pgrst_matched`
  """
  @spec statement(Plan.Read.t(), map(), opts()) :: {String.t(), [term()]}
  def statement(%Plan.Read{} = plan, context, opts \\ []) do
    case Keyword.get(opts, :source) do
      nil -> own_source(plan, context)
      {sql, builder} -> mutation_source(plan, sql, builder, opts)
    end
  end

  defp own_source(plan, context) do
    builder = Builder.new(repo: context.repo)
    {call_cte, builder} = call_cte(plan, builder)
    o = %{count?: false, cte?: false, call_cte?: true}
    {root, builder} = node(plan, nil, builder, o)
    {count_cte, total, builder} = count_parts(plan, builder, o)
    {header, builder} = csv_header(plan, builder)

    Builder.to_sql(builder, [
      "WITH ",
      call_cte,
      "pgrst_source AS (",
      root,
      ")",
      count_cte,
      " SELECT ",
      totals(total, plan, header),
      ", ",
      ResponseGucs.columns(),
      " FROM (SELECT * FROM pgrst_source) _postgrest_t"
    ])
  end

  # An RPC's call runs once, in its own CTE, which the root and the exact count both read.
  defp call_cte(%Plan.Read{source: {:call, call}}, builder) do
    {sql, builder} = Call.source(call, call.scope, builder)
    {["pgrst_rpc AS ", sql, ", "], builder}
  end

  defp call_cte(_plan, builder), do: {[], builder}

  defp mutation_source(plan, source_sql, builder, opts) do
    {root, builder} = node(plan, nil, builder, %{count?: false, cte?: true})
    total = if plan.count == :exact, do: "pg_catalog.count(_postgrest_t.*)", else: "NULL"
    {header, builder} = static_header(plan, Embed.spread_columns(plan), builder)

    Builder.to_sql(builder, [
      "WITH ",
      Keyword.get(opts, :ctes, []),
      "pgrst_source AS (",
      source_sql,
      ") SELECT ",
      totals(total, plan, header),
      ", ",
      Keyword.get(opts, :extra, "NULL"),
      " AS pgrst_keys, ",
      Keyword.get(opts, :inserted, "NULL"),
      " AS pgrst_inserted, ",
      Keyword.get(opts, :written, "NULL"),
      " AS pgrst_written, ",
      Keyword.get(opts, :matched, "NULL"),
      " AS pgrst_matched, ",
      ResponseGucs.columns(),
      " FROM (",
      root,
      ") _postgrest_t"
    ])
  end

  defp totals(total, plan, header) do
    [
      total,
      "::bigint AS total, pg_catalog.count(_postgrest_t.*) AS page_total, ",
      Format.body(plan.output.media, shape(plan), header),
      " AS body"
    ]
  end

  # The CSV header of a read. A table's is the first row of `pgrst_source`, so empty when there is
  # no row. A call's is its body's columns, present even when the filters and the window leave
  # no row; a scalar's is `pgrst_scalar`. (A write's, in `mutation_source/4`, is the same.)
  # Deliberately not PostgREST's header: see "Differences from PostgREST" in `PgRest.SQL.Format`.
  defp csv_header(
         %Plan.Read{source: {:call, %{function: %{returns: %{kind: :composite}}}}} = plan,
         builder
       ),
       do: static_header(plan, Embed.spread_columns(plan), builder)

  defp csv_header(%Plan.Read{source: {:call, _call}} = plan, builder),
    do: static_header(plan, ["pgrst_scalar"], builder)

  defp csv_header(_plan, builder), do: {:first_row, builder}

  # The names are request text (aliases): bound as one text parameter, only when CSV needs them.
  defp static_header(%Plan.Read{output: %{media: %{kind: :csv}}}, names, builder) do
    {placeholder, builder} = Builder.param(builder, Enum.join(names, ","), nil, :text)
    {{:expr, placeholder}, builder}
  end

  defp static_header(_plan, _names, builder), do: {:first_row, builder}

  # The body by result shape (`PgRest.SQL.Format`): rows are an array, a single row (the object
  # media type, or a function returning one composite) the first row or `null`, and a scalar
  # function's `pgrst_scalar` column the value or the array of values.
  defp shape(%Plan.Read{source: {:call, %{function: %{returns: returns}}}} = plan) do
    case returns do
      %{kind: :composite, set?: true} -> rows_shape(plan)
      %{kind: :composite} -> :single_composite
      %{kind: :scalar, set?: true} -> :scalar_set
      _scalar_or_void -> :scalar
    end
  end

  defp shape(plan), do: rows_shape(plan)

  defp rows_shape(%Plan.Read{output: %{media: %{kind: :object}}}), do: :single_composite
  defp rows_shape(_plan), do: :rows

  # Without limits or aggregates the total is the page total; otherwise the filters run once
  # more without order, limit, offset and grouping: as in PostgREST, an aggregating read
  # counts the rows it aggregates, not the groups. An RPC's `estimated` count is exact, as in
  # PostgREST: the count reads the `pgrst_rpc` CTE, so the function still runs once.
  defp count_parts(%Plan.Read{hook_limit: cap, count: mode} = plan, builder, o)
       when not is_nil(cap) and mode in [:planned, :estimated],
       do: count_parts(%{plan | count: :exact}, builder, o)

  defp count_parts(%Plan.Read{source: {:call, _}, count: :estimated} = plan, builder, o),
    do: count_parts(%{plan | count: :exact}, builder, o)

  defp count_parts(%Plan.Read{count: :exact} = plan, builder, o) do
    if plan.hook_limit == nil and plan.limit == nil and plan.offset == 0 and plan.max_limit == nil and
         not Aggregate.aggregating?(plan) do
      {[], "pg_catalog.count(_postgrest_t.*)", builder}
    else
      {sql, builder} = node(plan, nil, builder, %{o | count?: true})

      {[", pgrst_source_count AS (", sql, ")"],
       "(SELECT pg_catalog.count(*) FROM pgrst_source_count)", builder}
    end
  end

  defp count_parts(_plan, builder, _o), do: {[], "NULL", builder}

  # --- node ----------------------------------------------------------------------

  # `embed` is nil for the root. `o` carries `count?` (a count query: only `SELECT 1`, the
  # filters and the joins that change the row count), `cte?` (the root reads
  # `pgrst_source`) and `call_cte?` (an RPC root reads its call from the `pgrst_rpc` CTE;
  # without it the call is inlined, as in a standalone count or `EXPLAIN`).
  @doc false
  @spec node(Plan.Read.t(), Plan.Embed.t() | nil, Builder.t(), map()) ::
          {iodata(), Builder.t()}
  def node(plan, embed, builder, o) do
    if capped_aggregate?(plan, embed, o),
      do: capped_aggregate(plan, embed, builder, o),
      else: plain_node(plan, embed, builder, o)
  end

  defp capped_aggregate?(%{hook_limit: nil}, _embed, _opts), do: false
  defp capped_aggregate?(_plan, _embed, %{count?: true}), do: false

  defp capped_aggregate?(plan, embed, _opts),
    do: Aggregate.aggregating?(plan) and not to_one_spread?(embed)

  defp plain_node(plan, embed, builder, o, input_selects \\ nil) do
    # A to-one spread leaves its aggregates to the nearest parent that is no to-one spread,
    # which computes them and groups (`PgRest.SQL.Aggregate`).
    o = Map.put(o, :host?, not to_one_spread?(embed) and is_nil(input_selects))
    {from, builder} = from_clause(plan, embed, builder, o)

    {joins, join_selects, builder} = Embed.joins(plan, builder, o)

    {own, builder} = own_selects(plan, embed, builder, o)
    items = own ++ join_selects ++ (input_selects || [])
    {filters, builder} = filter_parts(plan, builder)
    {order, builder} = node_order(plan, embed, builder, o, input_selects)
    {limit, builder} = limit_clause(plan, builder, o)

    where = filters ++ join_conditions(embed)

    sql = [
      "SELECT ",
      Enum.intersperse(Enum.map(items, &elem(&1, 0)), ", "),
      " FROM ",
      from,
      joins,
      if(where == [], do: [], else: [" WHERE ", Enum.intersperse(where, " AND ")]),
      group_by(plan, items, o),
      order,
      limit
    ]

    {sql, builder}
  end

  # The same node compiler selects correlated, filtered and capped input rows first.
  # Aggregation stays outside that row window, within the existing lateral for an embed.
  defp capped_aggregate(plan, embed, builder, o) do
    names = Enum.sort(Map.keys(plan.column_types))
    aliases = names |> Enum.with_index(1) |> Map.new(fn {name, n} -> {name, "pgrst_i#{n}"} end)
    fields = for name <- names, do: %{key: aliases[name], field: name, json_path: [], cast: nil}
    input = %{plan | select: fields, aggregates?: false, limit: nil, offset: 0, max_limit: nil}
    {projected_orders, builder} = capped_orders(plan, builder)

    input_selects = Enum.map(projected_orders, &{&1, true})
    {rows, builder} = plain_node(input, embed, builder, o, input_selects)

    outer = %{
      plan
      | select: Enum.map(plan.select, &input_field(&1, aliases)),
        column_types: Map.new(plan.column_types, fn {name, type} -> {aliases[name], type} end),
        order:
          plan.order
          |> Enum.with_index(1)
          |> Enum.map(fn {term, i} -> input_order(term, aliases, i) end)
    }

    {own, builder} = own_selects(outer, embed, builder, Map.put(o, :host?, true))
    {order, builder} = order_clause(outer, embed, builder, o)
    {window, builder} = limit_clause(%{plan | hook_limit: nil}, builder, o)
    items = own ++ capped_embed_items(plan)

    {[
       "SELECT ",
       Enum.map_intersperse(items, ", ", &elem(&1, 0)),
       " FROM (",
       rows,
       ") AS ",
       Builder.ident(plan.alias),
       capped_group_by(plan, items),
       order,
       window
     ], builder}
  end

  defp input_order(%{relation: nil, field: field} = term, aliases, _i),
    do: %{term | field: %{field | name: Map.fetch!(aliases, field.name)}}

  defp input_order(term, _aliases, i),
    do: %{term | relation: nil, field: %{term.field | name: capped_order_name(i), json_path: []}}

  defp capped_order_name(i), do: "pgrst_order#{i}"

  defp capped_orders(plan, builder) do
    plan.order
    |> Enum.with_index(1)
    |> Enum.reject(fn {term, _i} -> term.relation == nil end)
    |> Enum.map_reduce(builder, fn {term, i}, b ->
      {expression, b} = order_target(term, plan, b)
      {[expression, " AS ", Builder.ident(capped_order_name(i))], b}
    end)
  end

  defp capped_group_by(plan, items) do
    grouping = group_by(plan, items, %{host?: true, count?: false})

    related =
      for {term, i} <- Enum.with_index(plan.order, 1),
          term.relation != nil,
          do: [Builder.ident(plan.alias), ".", Builder.ident(capped_order_name(i))]

    append_order_groups(grouping, related, plan.aggregates?)
  end

  defp append_order_groups(grouping, [], _aggregate?), do: grouping
  defp append_order_groups(grouping, _related, false), do: grouping
  defp append_order_groups([], related, true), do: [" GROUP BY ", Enum.intersperse(related, ", ")]

  defp append_order_groups(grouping, related, true),
    do: [grouping, ", ", Enum.intersperse(related, ", ")]

  defp input_field(%{aggregate: %{field: nil}} = entry, _aliases), do: entry

  defp input_field(%{aggregate: %{field: field} = aggregate} = entry, aliases),
    do: %{
      entry
      | aggregate: %{aggregate | field: %{field | name: Map.fetch!(aliases, field.name)}}
    }

  defp input_field(entry, aliases), do: %{entry | field: Map.fetch!(aliases, entry.field)}

  defp capped_embed_items(plan) do
    plan.embeds
    |> Enum.flat_map(&Embed.projected_items/1)
    |> Enum.map(&capped_item(&1, plan.alias))
  end

  defp capped_item({name, nil}, alias_name),
    do: {[Builder.ident(alias_name), ".", Builder.ident(name), " AS ", Builder.ident(name)], true}

  defp capped_item({_name, aggregate}, alias_name),
    do: {Aggregate.hoisted_item(aggregate, alias_name), false}

  defp from_clause(plan, embed, builder, o) do
    {source, builder} = source_sql(plan, builder, o)
    base = [source, " AS ", Builder.ident(plan.alias)]

    case embed && embed.relationship.junction do
      nil ->
        {base, builder}

      junction ->
        {sql, builder} =
          ScopedSource.compile(embed.junction_source_query, junction.module, builder)

        {[base, ", ", sql, " AS ", Builder.ident(embed.junction_alias)], builder}
    end
  end

  defp to_one_spread?(%Plan.Embed{spread: true} = embed), do: Plan.Embed.to_one?(embed)
  defp to_one_spread?(_embed), do: false

  # `items` are the node's `{select_sql, group?}` pairs: the GROUP BY reads the select list.
  defp group_by(_plan, _items, %{count?: true}), do: []

  defp group_by(plan, items, %{host?: true}),
    do: Aggregate.group_by(plan, Enum.map(items, &elem(&1, 1)))

  defp group_by(_plan, _items, _o), do: []

  defp source_sql(_plan, builder, %{cte?: true}), do: {"pgrst_source", builder}

  defp source_sql(%Plan.Read{source: {:call, _call}}, builder, %{call_cte?: true}),
    do: {"pgrst_rpc", builder}

  defp source_sql(%Plan.Read{source: {:call, call}}, builder, _o),
    do: Call.source(call, call.scope, builder)

  defp source_sql(plan, builder, _o),
    do: ScopedSource.compile(plan.source_query, plan.resource, builder)

  # The equalities that tie a node to its parent, resolved by the planner.
  defp join_conditions(nil), do: []

  defp join_conditions(%Plan.Embed{join_conditions: conditions}) do
    for {left_alias, left, right_alias, right} <- conditions do
      [
        Builder.ident(left_alias),
        ".",
        Builder.ident(left),
        " = ",
        Builder.ident(right_alias),
        ".",
        Builder.ident(right)
      ]
    end
  end

  # --- select list ---------------------------------------------------------------

  # Each item is `{sql, group?}`; `group?` is false for an aggregate (`group_by/3`).
  defp own_selects(_plan, _embed, builder, %{count?: true}), do: {[{"1", false}], builder}

  defp own_selects(plan, embed, builder, o) do
    {entries, builder} =
      Enum.map_reduce(plan.select, builder, &select_item(&1, plan, &2, o))

    {extras, builder} = Embed.order_selects(plan, embed, builder)
    {entries ++ Enum.map(extras, &{&1, true}), builder}
  end

  defp select_item(%{aggregate: aggregate} = entry, plan, builder, o) do
    opts = [column_types: plan.column_types]

    {sql, builder} =
      if Plan.Read.aggregate?(entry) and not o.host?,
        do: Aggregate.hoisted_input(aggregate, plan.alias, builder, opts),
        else: Aggregate.select_item(aggregate, plan.alias, builder, opts)

    {{sql, false}, builder}
  end

  defp select_item(entry, plan, builder, _o) do
    {expr, builder} = plan_field(plan, entry.field, entry.json_path, builder)
    {{[Builder.maybe_cast(expr, entry.cast), " AS ", Builder.ident(entry.key)], true}, builder}
  end

  defp plan_field(plan, name, json_path, builder) do
    field = %Field{name: name, json_path: json_path}
    Builder.column(plan.alias, field, plan.column_types, builder)
  end

  # --- filters -------------------------------------------------------------------

  defp filter_parts(%Plan.Read{where: nil}, builder), do: {[], builder}

  defp filter_parts(%Plan.Read{where: tree} = plan, builder) do
    {sql, builder} = where_sql(tree, plan, builder)
    {[sql], builder}
  end

  defp where_sql(%Logic{op: op, negate: negate, children: children}, plan, builder) do
    {parts, builder} = Enum.map_reduce(children, builder, &where_sql(&1, plan, &2))
    glue = if op == :and, do: " AND ", else: " OR "
    group = ["(", Enum.intersperse(parts, glue), ")"]
    {if(negate, do: ["NOT ", group], else: group), builder}
  end

  defp where_sql({:null_embed, name, null?}, plan, builder),
    do: {Embed.null_filter(plan, name, null?), builder}

  defp where_sql(%Condition{} = condition, plan, builder) do
    Where.compile(condition, plan.alias, plan.column_types, builder, categories: plan.categories)
  end

  # --- order, limit --------------------------------------------------------------

  defp node_order(_plan, _embed, builder, %{count?: true}, _inputs), do: {[], builder}
  defp node_order(%Plan.Read{order: []}, _embed, builder, _opts, _inputs), do: {[], builder}
  defp node_order(plan, embed, builder, opts, nil), do: order_clause(plan, embed, builder, opts)
  defp node_order(plan, _embed, builder, _opts, _inputs), do: plain_order(plan, builder)

  defp order_clause(_plan, _embed, builder, %{count?: true}), do: {[], builder}
  defp order_clause(%Plan.Read{order: []}, _embed, builder, _o), do: {[], builder}

  defp order_clause(plan, embed, builder, _o) do
    if Embed.order_in_aggregate?(embed), do: {[], builder}, else: plain_order(plan, builder)
  end

  defp plain_order(plan, builder) do
    {terms, builder} =
      Enum.map_reduce(plan.order, builder, fn term, b ->
        {expr, b} = order_target(term, plan, b)
        {[expr, modifiers(term)], b}
      end)

    {[" ORDER BY ", Enum.intersperse(terms, ", ")], builder}
  end

  @doc false
  @spec order_target(PgRest.AST.OrderTerm.t(), Plan.Read.t(), Builder.t()) ::
          {iodata(), Builder.t()}
  def order_target(%{relation: nil, field: field}, plan, builder),
    do: plan_field(plan, field.name, field.json_path, builder)

  def order_target(%{relation: relation, field: field}, plan, builder) do
    embed = Enum.find(plan.embeds, &(&1.output_name == relation))
    column = [Builder.ident(embed.agg_alias), ".", Builder.ident(field.name)]
    Builder.json_path(column, field.json_path, builder)
  end

  @doc false
  @spec modifiers(PgRest.AST.OrderTerm.t()) :: iodata()
  def modifiers(term) do
    [
      if(term.dir == :desc, do: " DESC", else: " ASC"),
      case term.nulls do
        :first -> " NULLS FIRST"
        :last -> " NULLS LAST"
        nil -> []
      end
    ]
  end

  defp limit_clause(%{hook_limit: nil}, builder, %{count?: true}), do: {[], builder}
  defp limit_clause(plan, builder, %{count?: true}), do: Builder.limit(builder, plan.hook_limit)

  defp limit_clause(plan, builder, _o) do
    {limit, builder} =
      limit_sql(plan.limit, Apply.min_limit(plan.max_limit, remaining_cap(plan)), builder)

    {offset, builder} =
      if plan.offset > 0 do
        {param, builder} = Builder.bigint(builder, plan.offset)
        {[" OFFSET ", param], builder}
      else
        {[], builder}
      end

    {[limit, offset], builder}
  end

  defp remaining_cap(%{hook_limit: nil}), do: nil
  defp remaining_cap(plan), do: max(plan.hook_limit - plan.offset, 0)

  defp limit_sql(nil, nil, builder), do: {[], builder}

  defp limit_sql(limit, nil, builder), do: Builder.limit(builder, limit)
  defp limit_sql(nil, max, builder), do: Builder.limit(builder, max)

  defp limit_sql(limit, max, builder) do
    {requested, builder} = Builder.bigint(builder, limit)
    {maximum, builder} = Builder.bigint(builder, max)
    {[" LIMIT LEAST(", requested, ", ", maximum, ")"], builder}
  end
end
