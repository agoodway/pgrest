defmodule PgRest.SQL.Aggregate do
  @moduledoc """
  The aggregate half of the read compiler: aggregate select items, the to-one spread
  hoisting and the implicit `GROUP BY`, mirroring PostgREST's `pgFmtApplyAggregate`,
  `hoistSpreadAggFunctions` and `groupF`.

    * `select_item/4` renders `[CAST(]<fun>([CAST(]<column>[ AS <input_cast>)])[ AS <cast>)]
      AS "<alias or fun name>"`; `count()` is `count(*)`. Both casts go through
      `PgRest.SQL.Builder.cast/2`, the only way a request type name reaches SQL.
    * A to-one spread does not aggregate in its own lateral, where each parent row sees at
      most one child row. It selects the aggregate's input under the output name
      (`hoisted_input/4`) and the nearest parent that is not a to-one spread applies the
      function to that lateral column (`hoisted_item/2`) and groups by the rest.
    * `group_by/2` groups a node with aggregates by every other item of its select list.

  Aggregates read the node's scoped source like any column, so scope holds under them.
  """

  alias PgRest.AST.Aggregate
  alias PgRest.Plan
  alias PgRest.SQL.Builder

  @functions %{count: "count", sum: "sum", avg: "avg", min: "min", max: "max"}

  @doc """
  The select item of an aggregate over `table_alias`, named by its alias or its function.

  Options: `:column_types` (Ecto field name to type); a JSON path on a column that is not
  `json`/`jsonb` reads it through `to_jsonb`, as for a plain select.
  """
  @spec select_item(Aggregate.t(), String.t(), Builder.t(), keyword()) ::
          {iodata(), Builder.t()}
  def select_item(%Aggregate{} = aggregate, table_alias, builder, opts \\ []) do
    {input, builder} = input(aggregate, table_alias, builder, opts, "*")
    {[apply_function(aggregate, input), " AS ", output(aggregate)], builder}
  end

  @doc """
  What a to-one spread selects for an aggregate its parent computes: the cast input under the
  output name (`1` for `count()`, so the parent counts the joined rows).
  """
  @spec hoisted_input(Aggregate.t(), String.t(), Builder.t(), keyword()) ::
          {iodata(), Builder.t()}
  def hoisted_input(%Aggregate{} = aggregate, table_alias, builder, opts \\ []) do
    {input, builder} = input(aggregate, table_alias, builder, opts, "1")
    {[input, " AS ", output(aggregate)], builder}
  end

  @doc "The parent's select item for an aggregate hoisted from the spread lateral `lateral_alias`."
  @spec hoisted_item(Aggregate.t(), String.t()) :: iodata()
  def hoisted_item(%Aggregate{} = aggregate, lateral_alias) do
    column = [Builder.ident(lateral_alias), ".", output(aggregate)]
    [apply_function(aggregate, column), " AS ", output(aggregate)]
  end

  @doc """
  Whether the node's rows are aggregates rather than its source rows: it has aggregates
  (`aggregates?`) or selects the legacy bare `count`.
  """
  @spec aggregating?(Plan.Read.t()) :: boolean()
  def aggregating?(%Plan.Read{aggregates?: true}), do: true

  def aggregating?(%Plan.Read{select: select}),
    do: Enum.any?(select, &Plan.Read.aggregate_entry?/1)

  @doc """
  The `GROUP BY` of a node that is not a to-one spread, as PostgREST's `groupF`: emitted only
  when the node has aggregates (`aggregates?`). `groupable` is one flag per item of the node's
  select list, in order, as the compiler built it (`PgRest.SQL.Read`, `PgRest.SQL.Read.Embed`):
  false for an aggregate, true for a column, an embed's output or a spread column. `[]` when
  no item is groupable.

  Terms are select-list positions. They name exactly the items the select list computes, so a
  JSON-path key bound once is not bound again, and an output name can never be read as an input
  column of the same name (which `GROUP BY "<alias>"` would).
  """
  @spec group_by(Plan.Read.t(), [boolean()]) :: iodata() | []
  def group_by(%Plan.Read{aggregates?: false}, _groupable), do: []

  def group_by(%Plan.Read{}, groupable) do
    case for({true, i} <- Enum.with_index(groupable, 1), do: Integer.to_string(i)) do
      [] -> []
      positions -> [" GROUP BY ", Enum.intersperse(positions, ", ")]
    end
  end

  # `none` stands in for a `count()` without a field.
  defp input(%Aggregate{field: nil}, _table_alias, builder, _opts, none), do: {none, builder}

  defp input(%Aggregate{field: field} = aggregate, table_alias, builder, opts, _none) do
    types = Keyword.get(opts, :column_types, %{})
    {expr, builder} = Builder.column(table_alias, field, types, builder)
    {Builder.maybe_cast(expr, aggregate.input_cast), builder}
  end

  defp apply_function(%Aggregate{fun: fun, cast: cast}, input),
    do: Builder.maybe_cast([Map.fetch!(@functions, fun), "(", input, ")"], cast)

  defp output(%Aggregate{alias: nil, fun: fun}), do: Builder.ident(Map.fetch!(@functions, fun))
  defp output(%Aggregate{alias: name}), do: Builder.ident(name)
end
