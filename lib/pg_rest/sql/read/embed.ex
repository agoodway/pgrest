defmodule PgRest.SQL.Read.Embed do
  @moduledoc """
  The embed half of the read compiler: lateral joins, the select items they add, spreads
  and `embed=is.null` filters. Called from `PgRest.SQL.Read`, which compiles the child
  nodes.

    * to-one: `LEFT JOIN LATERAL (<child>)`, rendered with `row_to_json(...)::jsonb`
    * to-many: `json_agg(<agg>)::jsonb` inside the lateral, `COALESCE(<agg>.<agg>, '[]')`
      in the outer select list
    * `!inner`: `INNER JOIN LATERAL ... ON <agg>.<agg> IS NOT NULL` (to-one: `ON TRUE`)
    * a spread merges a to-one embed's columns into the parent; a to-many spread yields
      one array per column, ordered by the child's order terms (the child keeps its
      limit and offset, as upstream does)
    * `embed=is.null` compares the lateral with `IS [NOT] DISTINCT FROM NULL`
  """

  alias PgRest.AST.{Condition, Logic}
  alias PgRest.Plan
  alias PgRest.SQL.{Aggregate, Builder, Read}

  @doc """
  The `{joins, select_items, builder}` of the plan's embeds. Each select item is
  `{sql, group?}`: `group?` is false for an aggregate the parent computes, so the parent's
  `GROUP BY` (`PgRest.SQL.Aggregate.group_by/2`) reads the same list. In a count query only the
  embeds that can change the parent row count are joined.
  """
  @spec joins(Plan.Read.t(), Builder.t(), map()) ::
          {[iodata()], [{iodata(), boolean()}], Builder.t()}
  def joins(plan, builder, o) do
    plan.embeds
    |> Enum.filter(&joined?(&1, plan, o))
    |> Enum.reduce({[], [], builder}, fn embed, {joins, selects, b} ->
      {join, select, b} = join(embed, plan, b, o)
      {joins ++ [join], selects ++ select, b}
    end)
  end

  defp joined?(_embed, _plan, %{count?: false}), do: true

  defp joined?(embed, plan, %{count?: true}),
    do: embed.join == :inner or null_filtered?(embed, plan)

  defp null_filtered?(embed, plan), do: embed.output_name in null_embeds(plan.where)

  defp null_embeds(nil), do: []
  defp null_embeds(%Logic{children: children}), do: Enum.flat_map(children, &null_embeds/1)
  defp null_embeds({:null_embed, name, _null?}), do: [name]
  defp null_embeds(%Condition{}), do: []

  defp join(embed, parent, builder, o) do
    {child, builder} = Read.node(embed.plan, embed, builder, Map.put(o, :cte?, false))
    agg = Builder.ident(embed.agg_alias)
    inner? = embed.join == :inner
    one? = Plan.Embed.to_one?(embed)

    {lateral, on} =
      lateral(embed, child, agg, one?, {inner? or null_filtered?(embed, parent), o.count?})

    on = if inner? and not one?, do: [agg, ".", agg, " IS NOT NULL"], else: on
    keyword = if inner?, do: "INNER", else: "LEFT"
    sql = [" ", keyword, " JOIN LATERAL (", lateral, ") AS ", agg, " ON ", on]
    {sql, selects(embed, agg, one?, o), builder}
  end

  defp lateral(_embed, child, _agg, true, _flags), do: {child, "TRUE"}

  defp lateral(%{spread: false}, child, agg, false, _flags),
    do: {["SELECT ", aggregate(agg), " FROM (", child, ") AS ", agg], "TRUE"}

  # A count query selects only `1`, so a spread there keeps just the aggregate that
  # `!inner` and null filters read.
  defp lateral(%{spread: true} = embed, child, agg, false, {needs_agg?, count?}) do
    arrays =
      for column <- spread_columns(embed.plan), not count? do
        [
          "COALESCE(json_agg(",
          agg,
          ".",
          Builder.ident(column),
          spread_order(embed, agg),
          "), '[]')::jsonb AS ",
          Builder.ident(column)
        ]
      end

    # The aggregate itself is only read by `!inner` and null filters.
    items = if needs_agg? or count?, do: [aggregate(agg) | arrays], else: arrays
    {["SELECT ", Enum.intersperse(items, ", "), " FROM (", child, ") AS ", agg], "TRUE"}
  end

  defp aggregate(agg), do: ["json_agg(", agg, ".*)::jsonb AS ", agg]

  defp selects(_embed, _agg, _one?, %{count?: true}), do: []
  defp selects(%{spread: true} = embed, agg, _one?, o), do: spread_selects(embed, agg, o.host?)

  defp selects(embed, agg, one?, _o) do
    name = Builder.ident(select_name(embed))

    cond do
      not selected?(embed) -> []
      one? -> [{["row_to_json(", agg, ".*)::jsonb AS ", name], true}]
      true -> [{["COALESCE(", agg, ".", agg, ", '[]') AS ", name], true}]
    end
  end

  defp select_name(%Plan.Embed{merge: true} = embed), do: embed.merge_key
  defp select_name(embed), do: embed.output_name

  # A parent that hosts the spread's hoisted aggregates computes them over the lateral's
  # columns; a to-one spread in between passes them up unchanged.
  defp spread_selects(embed, agg, host?) do
    for {column, aggregate} <- spread_items(embed.plan) do
      if host? and aggregate do
        {Aggregate.hoisted_item(aggregate, embed.agg_alias), false}
      else
        {[agg, ".", Builder.ident(column), " AS ", Builder.ident(column)], true}
      end
    end
  end

  # Whether an embed is in its parent's output: one with nothing selected (`rel()`) only filters
  # its parent.
  defp selected?(%Plan.Embed{plan: %{select: [], embeds: embeds}}),
    do: Enum.any?(embeds, &selected?/1)

  defp selected?(_embed), do: true

  @doc "Output names and hoisted aggregates selected by a lateral, excluding empty embeds."
  @spec projected_items(Plan.Embed.t()) :: [{String.t(), PgRest.AST.Aggregate.t() | nil}]
  def projected_items(%Plan.Embed{spread: true, plan: plan}), do: spread_items(plan)
  def projected_items(embed), do: if(selected?(embed), do: [{select_name(embed), nil}], else: [])

  @doc "The column names a spread (or merge) embed's plan exposes to its parent."
  @spec spread_columns(Plan.Read.t()) :: [String.t()]
  def spread_columns(plan), do: Enum.map(spread_items(plan), &elem(&1, 0))

  @doc """
  The columns a spread (or merge) embed's plan exposes to its parent, each with the aggregate
  the parent applies to it: a (non-legacy) aggregate of the plan or of a spread below it, which
  a to-one spread leaves to its parent (`PgRest.SQL.Aggregate`), else `nil`.
  """
  @spec spread_items(Plan.Read.t()) :: [{String.t(), PgRest.AST.Aggregate.t() | nil}]
  def spread_items(%Plan.Read{select: select, embeds: embeds}) do
    Enum.map(select, &spread_item/1) ++
      Enum.flat_map(embeds, fn
        %{spread: true} = embed -> spread_items(embed.plan)
        %{merge: true} = embed -> spread_items(embed.plan)
        embed -> if selected?(embed), do: [{embed.output_name, nil}], else: []
      end)
  end

  defp spread_item(%{key: key} = entry),
    do: {key, if(Plan.Read.aggregate?(entry), do: entry.aggregate)}

  # --- to-many spread ordering ---------------------------------------------------

  @doc """
  Extra select items of a to-many spread child: its order columns under unique names, so
  the aggregate can order by them. The child's order leaves its own query.
  """
  @spec order_selects(Plan.Read.t(), Plan.Embed.t() | nil, Builder.t()) ::
          {[iodata()], Builder.t()}
  def order_selects(%Plan.Read{order: order} = plan, %Plan.Embed{spread: true} = embed, builder)
      when order != [] do
    if Plan.Embed.to_one?(embed) do
      {[], builder}
    else
      order
      |> Enum.with_index(1)
      |> Enum.map_reduce(builder, fn {term, i}, b ->
        {expr, b} = Read.order_target(term, plan, b)
        {[expr, " AS ", Builder.ident(order_name(embed, i))], b}
      end)
    end
  end

  def order_selects(_plan, _embed, builder), do: {[], builder}

  @doc "Whether the child's `ORDER BY` moves into its aggregate (a to-many spread)."
  @spec order_in_aggregate?(Plan.Embed.t() | nil) :: boolean()
  def order_in_aggregate?(%Plan.Embed{spread: true} = embed), do: not Plan.Embed.to_one?(embed)
  def order_in_aggregate?(_embed), do: false

  defp order_name(embed, i), do: "#{embed.agg_alias}_o#{i}"

  defp spread_order(%Plan.Embed{plan: %{order: []}}, _agg), do: []

  defp spread_order(%Plan.Embed{plan: %{order: order}} = embed, agg) do
    terms =
      order
      |> Enum.with_index(1)
      |> Enum.map(fn {term, i} ->
        [agg, ".", Builder.ident(order_name(embed, i)), Read.modifiers(term)]
      end)

    [" ORDER BY ", Enum.intersperse(terms, ", ")]
  end

  # --- null filters --------------------------------------------------------------

  @doc "SQL of an `embed=is.null` leaf of the node's filters."
  @spec null_filter(Plan.Read.t(), String.t(), boolean()) :: iodata()
  def null_filter(plan, name, null?) do
    embed = Enum.find(plan.embeds, &(&1.output_name == name))
    agg = Builder.ident(embed.agg_alias)
    # `agg.*` is the whole-row reference; a bare `agg` would bind to a same-named column
    # of the parent first.
    subject = if Plan.Embed.to_one?(embed), do: [agg, ".*"], else: [agg, ".", agg]
    [subject, " IS ", if(null?, do: "NOT ", else: ""), "DISTINCT FROM NULL"]
  end
end
