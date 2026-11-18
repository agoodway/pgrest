defmodule PgRest.Grammar.Filter do
  @moduledoc """
  Parser for PostgREST horizontal filters (`col=op.value`) and logic trees
  (`or=(a.eq.1,and(...))`).

  Operator prefixes, list values and quoted values are NimbleParsec combinators; the
  logic tree is walked in plain Elixir so nesting depth is counted explicitly (the cap
  is 16) and failures carry PostgREST-shaped positions.
  """

  import NimbleParsec

  alias PgRest.AST.{Condition, Logic}
  alias PgRest.Error
  alias PgRest.Grammar.Common

  @max_depth 16

  @quant_ops ~w(eq gte gt lte lt like ilike match imatch)
  @fts_ops ~w(fts plfts phfts wfts)
  @plain_ops ~w(neq cs cd ov sl sr nxr nxl adj in is isdistinct)
  # Compile-time constants only: no atom is ever created from request text.
  @op_names for name <- @quant_ops ++ @fts_ops ++ @plain_ops,
                into: %{},
                do: {name, String.to_atom(name)}
  @op_list @op_names |> Map.keys() |> Enum.sort_by(&(-byte_size(&1)))

  @join {IO, :iodata_to_binary, []}
  @trim {String, :trim, []}

  @op_expecting "operator (eq, gt, ...)"
  @is_keywords ~w(null not_null true false unknown)
  @is_expecting "isVal: (null, not_null, true, false, unknown)"
  @item_expecting Common.name_expecting() <>
                    ", negation operator (not) or logic operator (and, or)"
  @after_field_expecting ~S|letter, digit, "-", "->>", "->" or delimiter (.)|

  # --- combinators ---------------------------------------------------------------

  names = fn names ->
    names |> Enum.sort_by(&(-byte_size(&1))) |> Enum.map(&string/1) |> choice() |> tag(:op)
  end

  any_all =
    ignore(string("("))
    |> choice([string("any") |> replace(:any), string("all") |> replace(:all)])
    |> ignore(string(")"))
    |> unwrap_and_tag(:modifier)

  fts_config =
    ignore(string("("))
    |> parsec({Common, :identifier})
    |> ignore(string(")"))
    |> unwrap_and_tag(:fts_config)

  dot = ignore(string("."))

  op_prefix =
    optional(string("not.") |> replace(true) |> unwrap_and_tag(:negate))
    |> choice([
      names.(@quant_ops) |> optional(any_all) |> concat(dot),
      names.(@fts_ops) |> optional(fts_config) |> concat(dot),
      names.(@plain_ops) |> concat(dot)
    ])

  defparsecp(:op_prefix, op_prefix)

  # `"..."` followed by `,`, `)` or the end of input; otherwise it is not a quoted value.
  quoted_element =
    parsec({Common, :quoted_value})
    |> lookahead(choice([string(","), string(")"), eos()]))

  raw_element = parsec({Common, :raw_value})

  element = choice([quoted_element, raw_element])

  defparsecp(
    :list_value,
    ignore(optional(parsec({Common, :blank})))
    |> ignore(string("("))
    |> ignore(optional(parsec({Common, :blank})))
    |> concat(element)
    |> repeat(ignore(string(",")) |> concat(element))
    |> ignore(optional(parsec({Common, :blank})))
    |> ignore(string(")"))
  )

  ci = fn word ->
    word
    |> String.to_charlist()
    |> Enum.map(fn char -> ascii_char([char, if(char in ?a..?z, do: char - 32, else: char)]) end)
    |> Enum.reduce(empty(), &concat(&2, &1))
  end

  defparsecp(
    :is_value,
    choice([
      ci.("null") |> replace(:null),
      ci.("not_null") |> replace(:not_null),
      ci.("true") |> replace(true),
      ci.("false") |> replace(false),
      ci.("unknown") |> replace(:unknown)
    ])
  )

  pg_array =
    string("{")
    |> optional(utf8_string([not: ?{, not: ?}], min: 1))
    |> string("}")
    |> reduce(@join)

  defparsecp(
    :logic_value,
    choice([quoted_element, pg_array, raw_element])
  )

  array_element =
    ignore(optional(parsec({Common, :blank})))
    |> choice([
      parsec({Common, :quoted_value}),
      [not: ?,, not: ?{, not: ?}, not: ?"] |> utf8_string(min: 1) |> map(@trim)
    ])
    |> ignore(optional(parsec({Common, :blank})))

  defparsecp(
    :array_literal,
    ignore(string("{"))
    |> optional(array_element |> repeat(ignore(string(",")) |> concat(array_element)))
    |> ignore(string("}"))
    |> eos()
  )

  # --- public API ----------------------------------------------------------------

  @doc """
  Parses one filter. `key` is the query-string key (a name with an optional JSON path),
  `value` is the text after `=`, e.g. `not.in.(1,2)`.

  An embed path in the key (`rel.col`) is parsed but dropped; use `parse_filter/2` when
  the path matters.
  """
  @spec parse_condition(String.t(), String.t()) :: {:ok, Condition.t()} | {:error, Error.t()}
  def parse_condition(key, value) do
    with {:ok, {_embed_path, condition}} <- parse_filter(key, value), do: {:ok, condition}
  end

  @doc """
  Parses one filter whose key may carry an embed path (`a.b.col->x`, `"a.b".col`),
  returning `{embed_path, condition}`.
  """
  @spec parse_filter(String.t(), String.t()) ::
          {:ok, {[String.t()], Condition.t()}} | {:error, Error.t()}
  def parse_filter(key, value) do
    with {:ok, {embed_path, field}} <- Common.parse_tree_path(key),
         {:ok, condition} <- filter_value(field, value) do
      {:ok, {embed_path, condition}}
    end
  end

  @doc """
  Parses a logic tree. `key` is `or`, `and`, `not.or` or `not.and`, optionally behind an
  embed path (`client.or`); `value` is the parenthesised body, e.g.
  `(a.eq.1,and(b.gt.2,c.not.is.null))`. The embed path is dropped; use
  `parse_logic_tree/2` when it matters.
  """
  @spec parse_logic(String.t(), String.t()) :: {:ok, Logic.t()} | {:error, Error.t()}
  def parse_logic(key, value) do
    with {:ok, {_embed_path, tree}} <- parse_logic_tree(key, value), do: {:ok, tree}
  end

  @doc """
  Like `parse_logic/2`, returning `{embed_path, tree}` (upstream `pLogicPath`).
  """
  @spec parse_logic_tree(String.t(), String.t()) ::
          {:ok, {[String.t()], Logic.t()}} | {:error, Error.t()}
  def parse_logic_tree(key, value) do
    with {:ok, names} <- Common.parse_names(key, "logic path") do
      {path, [operator]} = Enum.split(names, -1)
      embed_path = Enum.reject(path, &(&1 == "not"))
      input = if "not" in path, do: "not." <> operator <> value, else: operator <> value

      with {:ok, tree} <- logic_tree(input, value) do
        {:ok, {embed_path, tree}}
      end
    end
  end

  @doc """
  Whether `value` starts with an operator prefix, `[not.]op[(modifier)].`, whatever
  follows it. A value that has one but fails `parse_condition/2` is a malformed filter
  (`is.maybe`, `in.abc`); one without is not a filter at all (`hello`).
  """
  @spec operator_prefix?(String.t()) :: boolean()
  def operator_prefix?(value) when is_binary(value),
    do: match?({:ok, _parts, _rest}, value |> op_prefix() |> Common.unwrap(value))

  @doc """
  Splits a PostgreSQL array literal (`{a,"b,c"}`) into its elements, unquoting quoted
  elements and trimming blanks around unquoted ones. Anything else (a range, JSON, text
  after the closing brace) is `:error`.
  """
  @spec parse_array_literal(String.t()) :: {:ok, [String.t()]} | :error
  def parse_array_literal(value) when is_binary(value) do
    case value |> array_literal() |> Common.unwrap(value) do
      {:ok, elements, ""} -> {:ok, elements}
      _ -> :error
    end
  end

  defp logic_tree(input, value) do
    case logic_expr(input, 1) do
      {:ok, tree, _rest} -> {:ok, tree}
      {:fail, rest, expecting} -> {:error, logic_error(value, input, rest, expecting)}
      {:error, %Error{}} = error -> error
    end
  end

  # --- top-level filter ----------------------------------------------------------

  defp filter_value(field, value) do
    case op_expr(value, :top) do
      {:ok, condition, _rest} ->
        {:ok, %{condition | field: field}}

      {:fail, rest, expecting} ->
        {:error, Common.syntax_error("filter", value, value, rest, expecting)}
    end
  end

  # --- operator expression -------------------------------------------------------

  # Parses `[not.]op[(modifier)].value`. In `:top` mode a scalar value is the rest of the
  # text; in `:logic` mode it stops at `,` or `)`. Returns the condition without its
  # field, or `{:fail, rest, expecting}` at the failure point.
  defp op_expr(input, mode) do
    case input |> op_prefix() |> Common.unwrap(input) do
      {:ok, parts, rest} -> op_value(parts, rest, mode)
      {:error, _input} -> prefix_failure(input)
    end
  end

  defp op_value(parts, rest, mode) do
    op = Map.fetch!(@op_names, parts |> Keyword.fetch!(:op) |> hd())
    modifier = Keyword.get(parts, :modifier)

    with {:ok, value, rest} <- value(op, rest, mode) do
      condition = %Condition{
        field: nil,
        op: op,
        negate: Keyword.get(parts, :negate, false),
        modifier: modifier,
        value: quantified(value, modifier),
        fts_config: Keyword.get(parts, :fts_config)
      }

      {:ok, condition, rest}
    end
  end

  defp value(:in, rest, _mode), do: run(list_value(rest), rest, ~s|"("|)

  defp value(:is, rest, _mode) do
    case run(is_value(rest), rest, @is_expecting) do
      {:ok, [value], rest} -> {:ok, value, rest}
      {:fail, _rest, expecting} -> {:fail, after_is_prefix(rest), expecting}
    end
  end

  defp value(_op, rest, :top), do: {:ok, rest, ""}

  defp value(_op, rest, :logic) do
    with {:ok, [value], rest} <- run(logic_value(rest), rest, "value"), do: {:ok, value, rest}
  end

  # parsec's `string` consumes a partial match and `<|>` does not backtrack, so the failure
  # sits after the longest prefix any keyword shares with the input (upstream wraps every
  # alternative in `try`), compared ASCII-case-insensitively byte by byte.
  defp after_is_prefix(input) do
    skip = @is_keywords |> Enum.map(&common_prefix(input, &1, 0)) |> Enum.max()
    binary_part(input, skip, byte_size(input) - skip)
  end

  # Keywords are lowercase ASCII, so an uppercase input byte is 32 below its keyword byte.
  defp common_prefix(<<a, left::binary>>, <<b, right::binary>>, n)
       when a == b or (a in ?A..?Z and a + 32 == b),
       do: common_prefix(left, right, n + 1)

  defp common_prefix(_left, _right, n), do: n

  defp run(result, input, expecting) do
    case Common.unwrap(result, input) do
      {:ok, _acc, _rest} = ok -> ok
      {:error, rest} -> {:fail, rest, expecting}
    end
  end

  # `any`/`all` take a PostgreSQL array literal; split it so each element can be bound.
  # Anything else stays raw so Postgres reports the malformed literal.
  defp quantified(value, nil), do: value

  defp quantified(value, _modifier) do
    case parse_array_literal(value) do
      {:ok, elements} -> elements
      :error -> value
    end
  end

  defp prefix_failure(input) do
    {after_not, expecting} =
      case input do
        "not." <> rest -> {rest, @op_expecting}
        _ -> {input, ~s|"not" or #{@op_expecting}|}
      end

    case Enum.find(@op_list, &String.starts_with?(after_not, &1)) do
      nil -> {:fail, after_not, expecting}
      name -> {:fail, after_name(name, String.replace_prefix(after_not, name, "")), @op_expecting}
    end
  end

  # Operators that take a `(modifier)` consume the `(` before failing.
  defp after_name(name, "(" <> rest) when name in @quant_ops or name in @fts_ops, do: rest
  defp after_name(_name, rest), do: rest

  # --- logic trees ---------------------------------------------------------------

  # Input starts at `[not.](and|or)(`. Returns `{:ok, tree, rest}`, `{:fail, rest,
  # expecting}` for a syntax error, or `{:error, error}` for a hard rejection.
  defp logic_expr(input, depth) do
    {negate, rest} = take_not(input)

    with {:ok, op, rest} <- logic_op(rest),
         :ok <- check_depth(depth),
         {:ok, rest} <- open_paren(rest),
         {:ok, children, rest} <- logic_items(rest, depth, []) do
      {:ok, %Logic{op: op, negate: negate, children: children}, rest}
    end
  end

  defp take_not("not." <> rest), do: {true, rest}
  defp take_not(rest), do: {false, rest}

  defp logic_op("and" <> rest), do: {:ok, :and, rest}
  defp logic_op("or" <> rest), do: {:ok, :or, rest}
  defp logic_op(rest), do: {:fail, rest, "logic operator (and, or)"}

  defp check_depth(depth) when depth > @max_depth,
    do: {:error, Error.parse_error("logic tree depth exceeds #{@max_depth}")}

  defp check_depth(_depth), do: :ok

  defp open_paren(rest) do
    case Common.skip_blanks(rest) do
      "(" <> after_paren -> {:ok, Common.skip_blanks(after_paren)}
      other -> {:fail, other, ~s|"("|}
    end
  end

  defp logic_items(input, depth, acc) do
    with {:ok, item, rest} <- logic_item(input, depth) do
      case Common.skip_blanks(rest) do
        "," <> more -> logic_items(Common.skip_blanks(more), depth, [item | acc])
        ")" <> more -> {:ok, Enum.reverse([item | acc]), more}
        other -> {:fail, other, ~s|"," or ")"|}
      end
    end
  end

  # PostgREST tries a filter first and falls back to a nested and/or. A nested and/or
  # that consumed input before failing owns the error; otherwise the failure that got
  # furthest wins and a tie reports the merged item expectations.
  defp logic_item(input, depth) do
    with {:fail, filter_rest, filter_expecting} <- logic_filter(input) do
      case logic_expr(input, depth + 1) do
        {:fail, ^input, _expecting} when byte_size(filter_rest) < byte_size(input) ->
          {:fail, filter_rest, filter_expecting}

        {:fail, ^input, _expecting} ->
          {:fail, input, @item_expecting}

        result ->
          result
      end
    end
  end

  defp logic_filter(input) do
    with {:ok, field, after_field} <- Common.parse_field(input, @item_expecting),
         {:ok, after_dot} <- dot(after_field),
         {:ok, condition, rest} <- op_expr(after_dot, :logic),
         :ok <- Common.validate_field(field) do
      {:ok, %{condition | field: field}, rest}
    else
      {:error, %Error{}} = error -> error
      {:fail, _rest, _expecting} = failure -> failure
    end
  end

  defp dot("." <> rest), do: {:ok, rest}
  defp dot(rest), do: {:fail, rest, @after_field_expecting}

  defp logic_error(value, input, rest, expecting),
    do: Common.syntax_error("logic tree", value, input, rest, expecting)
end
