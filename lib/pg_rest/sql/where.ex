defmodule PgRest.SQL.Where do
  @moduledoc """
  Compiles filter and logic-tree AST nodes (`PgRest.AST.Condition`, `PgRest.AST.Logic`)
  to a SQL boolean expression.

  Every request value is a bind parameter bound as text and cast in SQL to the column's
  catalog type (`$n::text::<type>`), so enum, `citext`, `int4` declared `:decimal` and
  `timestamptz` declared `:utc_datetime` columns compare in their real type and keep their
  indexes. Malformed values surface as Postgres's own `22P02`. Lists (`in`, `any`, `all`)
  bind as `text[]` and cast as `<type>[]`; array literals are never built from request
  text. JSON-path keys are always bind parameters, never spliced into the SQL text.

  Type text from the catalog is trusted. Its typmod is dropped before it is used as a
  cast target (`numeric(10,2)` becomes `numeric`, `character varying(3)` becomes
  `character varying`, `character(3)` becomes `bpchar`, `bit(3)` becomes `varbit`), because
  an explicit cast to a typmod type rounds or truncates the request value (`price=eq.9.994`
  must not match `9.99`); PostgREST compares untruncated. Pattern operators and JSON-path
  keys bind a bare `$n`, so Postgres infers their type like PostgREST's unknown literals.
  String (`"S"`) and enum (`"E"`) columns bind a bare `$n` too (no `::text::<type>` cast)
  for every operator that takes its type from the column (comparisons, `in`, `any`/`all`,
  `isdistinct` and the raw operators such as `cs`), so Postgres infers `varchar`, `citext`
  or the enum type from the column itself. A `->>` / `->` JSON-path target is not a column
  of that category: it is cast by its result type (`text` / `jsonb`).

  The bare bind is encoded by Postgrex for the inferred type. The `name` type (category
  `"S"`) therefore accepts at most 63 bytes: a longer filter value raises
  `DBConnection.EncodeError` instead of comparing as a longer, non-matching string, which
  is a known divergence from PostgREST.

  `in.()` and `in.("")` are the empty list, as upstream.

  ## Known divergences

  The `any`/`all` quantifier array `{a,b}` is split by the grammar, not by Postgres, so
  a literal `NULL` stays the text `"NULL"` and backslashes are not array escapes, unlike
  PostgREST, which hands the literal to Postgres.

  ## Options

    * `:categories` - `%{field_name => pg_type.typcategory}` from
      `PgRest.Catalog.column_categories/3`; `"S"` (string) and `"E"` (enum) columns
      compare against a bare `$n`. Defaults to none.
    * `:columns` - `%{field_name => source_column}` for resources whose Ecto field names
      differ from the database column (`source:`). Defaults to the identity.
  """

  alias PgRest.AST.{Condition, Field, Logic}
  alias PgRest.SQL.Builder

  @comparison %{
    eq: "=",
    neq: "<>",
    gt: ">",
    gte: ">=",
    lt: "<",
    lte: "<=",
    like: "LIKE",
    ilike: "ILIKE",
    match: "~",
    imatch: "~*"
  }
  @pattern_ops [:like, :ilike, :match, :imatch]
  @quantifiable Map.keys(@comparison) -- [:neq]
  @raw_ops %{
    cs: "@>",
    cd: "<@",
    ov: "&&",
    sl: "<<",
    sr: ">>",
    nxr: "&<",
    nxl: "&>",
    adj: "-|-"
  }
  @fts_funs %{
    fts: "to_tsquery",
    plfts: "plainto_tsquery",
    phfts: "phraseto_tsquery",
    wfts: "websearch_to_tsquery"
  }
  @is_values %{
    null: "NULL",
    not_null: "NOT NULL",
    true: "TRUE",
    false: "FALSE",
    unknown: "UNKNOWN"
  }

  @quoted ~r/"(?:[^"]|"")*"/
  @char_typmod ~r/\bcharacter\(\s*\d+\s*\)/
  @bit_typmod ~r/\bbit\(\s*\d+\s*\)/
  @typmod ~r/\(\s*\d+(\s*,\s*-?\d+)?\s*\)/

  @doc """
  Compiles `node` against the table aliased `table_alias`.

  `column_types` maps field names to catalog types (a missing type binds as plain text).
  """
  @spec compile(
          Logic.t() | Condition.t(),
          String.t(),
          %{optional(String.t()) => String.t()},
          Builder.t(),
          keyword()
        ) :: {iodata(), Builder.t()}
  def compile(node, table_alias, column_types, %Builder{} = builder, opts \\ []) do
    ctx = %{
      alias: table_alias,
      types: column_types,
      columns: Keyword.get(opts, :columns, %{}),
      categories: Keyword.get(opts, :categories, %{})
    }

    node(node, ctx, builder)
  end

  # --- tree ----------------------------------------------------------------------

  defp node(%Logic{op: op, negate: negate, children: children}, ctx, builder) do
    {parts, builder} =
      Enum.map_reduce(children, builder, fn child, acc -> node(child, ctx, acc) end)

    {negated(negate, ["(", Enum.intersperse(parts, glue(op)), ")"]), builder}
  end

  defp node(%Condition{negate: negate} = condition, ctx, builder) do
    {left, type, builder} = left_operand(condition.field, ctx, builder)
    {expr, builder} = operator(condition, left, type, builder)
    {negated(negate, expr), builder}
  end

  defp glue(:and), do: " AND "
  defp glue(:or), do: " OR "

  defp negated(true, expr), do: ["NOT (", expr, ")"]
  defp negated(false, expr), do: expr

  # --- left-hand side ------------------------------------------------------------

  # Returns the column expression, the type values compare as, and the builder.
  defp left_operand(%Field{name: name, json_path: path}, ctx, builder) do
    source = Map.get(ctx.columns, name, name)
    column = [Builder.ident(ctx.alias), ".", Builder.ident(source)]

    column =
      if path != [] and not json_type?(ctx, name), do: ["to_jsonb(", column, ")"], else: column

    json_path(path, column, value_type(ctx, name, path), builder)
  end

  # As PostgREST, a path on a column that is not json or jsonb goes through `to_jsonb`.
  defp json_type?(ctx, name), do: Map.get(ctx.types, name) in ["json", "jsonb"]

  # String and enum columns bind a bare `$n` (no cast), as PostgREST does: Postgres infers the
  # column type, so errors read the same (`invalid input value for enum status_enum`).
  defp value_type(ctx, name, []) do
    case Map.get(ctx.categories, name) do
      category when category in ["S", "E"] -> :bare
      _other -> ctx.types |> Map.get(name) |> comparison_type()
    end
  end

  defp value_type(ctx, name, _path), do: ctx.types |> Map.get(name) |> comparison_type()

  defp json_path([], column, type, builder), do: {column, type, builder}

  defp json_path(steps, column, _type, builder) do
    {expr, builder} = Builder.json_path(column, steps, builder)
    {expr, result_type(steps), builder}
  end

  # `->>` yields text, `->` yields jsonb.
  defp result_type(steps) do
    case List.last(steps) do
      {:double_arrow, _key} -> "text"
      {:arrow, _key} -> "jsonb"
    end
  end

  # Every request value is bound as text; `text` itself needs no further cast.
  defp bind(builder, value, :bare), do: bare(builder, value)
  defp bind(builder, value, "text"), do: Builder.param(builder, value, nil, :text)
  defp bind(builder, value, type), do: Builder.param(builder, value, type, :text)

  # A bare `$n` (native, untyped): Postgres infers the type, as for an unknown literal.
  defp bare(builder, value), do: Builder.param(builder, value, nil, :native)

  # Rewrites a catalog type so a cast keeps the value intact: an explicit typmod rounds or
  # truncates (`numeric(10,2)`, `character varying(3)`), `character(n)` and `bit(n)` without
  # a length would mean `character(1)` and `bit(1)`. Quoted identifiers are left untouched.
  defp comparison_type(nil), do: nil

  defp comparison_type(type) do
    @quoted
    |> Regex.split(type, include_captures: true)
    |> Enum.map_join(&unquoted_type/1)
  end

  defp unquoted_type("\"" <> _ = quoted), do: quoted

  defp unquoted_type(segment) do
    segment
    |> String.replace(@char_typmod, "bpchar")
    |> String.replace(@bit_typmod, "varbit")
    |> String.replace(@typmod, "")
  end

  # --- operators -----------------------------------------------------------------

  defp operator(%Condition{op: :is, value: value}, left, _type, builder),
    do: {[left, " IS ", Map.fetch!(@is_values, value)], builder}

  # PostgREST: `in.()` and `in.("")` both parse to `[""]` and mean the empty list.
  defp operator(%Condition{op: :in, value: [""]}, left, _type, builder),
    do: {[left, " = ANY('{}')"], builder}

  defp operator(%Condition{op: :in, value: values}, left, type, builder) do
    {list, builder} = bind(builder, values, type)
    {[left, " = ANY(", list, ")"], builder}
  end

  defp operator(%Condition{op: :isdistinct, value: value}, left, type, builder) do
    {param, builder} = bind(builder, value, type)
    {[left, " IS DISTINCT FROM ", param], builder}
  end

  defp operator(%Condition{op: op, modifier: modifier, value: values}, left, type, builder)
       when modifier in [:any, :all] and op in @quantifiable do
    values = Enum.map(values, &pattern_value(op, &1))
    {list, builder} = bind_compared(builder, values, op, type)
    {[left, " ", Map.fetch!(@comparison, op), " ", quantifier(modifier), "(", list, ")"], builder}
  end

  defp operator(%Condition{op: op, value: value}, left, type, builder)
       when is_map_key(@comparison, op) do
    {param, builder} = bind_compared(builder, pattern_value(op, value), op, type)
    {[left, " ", Map.fetch!(@comparison, op), " ", param], builder}
  end

  defp operator(%Condition{op: op, value: value}, left, type, builder)
       when is_map_key(@raw_ops, op) do
    {param, builder} = bind(builder, value, type)
    {[left, " ", Map.fetch!(@raw_ops, op), " ", param], builder}
  end

  defp operator(%Condition{op: op} = condition, left, type, builder)
       when is_map_key(@fts_funs, op),
       do: fts(condition, left, type, builder)

  defp quantifier(:any), do: "ANY"
  defp quantifier(:all), do: "ALL"

  # Pattern operators bind a bare `$n`, like PostgREST's unknown literal: `integer LIKE x`
  # fails as `integer ~~ unknown`, and `citext` keeps its case-insensitive operators.
  defp bind_compared(builder, value, op, _type) when op in @pattern_ops, do: bare(builder, value)
  defp bind_compared(builder, value, _op, type), do: bind(builder, value, type)

  defp pattern_value(op, value) when op in [:like, :ilike], do: String.replace(value, "*", "%")
  defp pattern_value(_op, value), do: value

  # --- full-text search ----------------------------------------------------------

  defp fts(%Condition{op: op, value: query, fts_config: config}, left, type, builder) do
    fun = Map.fetch!(@fts_funs, op)
    {document, builder} = fts_document(left, type, config, builder)
    {query_args, builder} = fts_query_args(config, query, builder)
    {[document, " @@ ", fun, "(", query_args, ")"], builder}
  end

  # The config stays a bind parameter, never spliced (S-H2).
  defp fts_query_args(nil, query, builder), do: bind(builder, query, "text")

  defp fts_query_args(config, query, builder) do
    {config, builder} = bind(builder, config, "regconfig")
    {query, builder} = bind(builder, query, "text")
    {[config, ", ", query], builder}
  end

  defp fts_document(left, type, _config, builder) when type in [nil, "tsvector"],
    do: {left, builder}

  defp fts_document(left, _type, nil, builder), do: {["to_tsvector(", left, ")"], builder}

  defp fts_document(left, _type, config, builder) do
    {param, builder} = bind(builder, config, "regconfig")
    {["to_tsvector(", param, ", ", left, ")"], builder}
  end
end
