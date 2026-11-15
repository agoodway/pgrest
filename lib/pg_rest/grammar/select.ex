defmodule PgRest.Grammar.Select do
  @moduledoc """
  Parser for the PostgREST `select=` parameter: columns with aliases, `::` casts and
  JSON paths, aggregates, and embedded resources (`alias:rel!hint!inner(...)`, spreads
  `...rel(...)`, empty embeds `rel()`).

  It is a recursive-descent walk over the binary that reuses `PgRest.Grammar.Common`
  for names and JSON paths. Whitespace is ignored around tokens but is significant
  inside a cast type name (`timestamp with time zone`). A failure carries the
  PostgREST-shaped position and expectation.

  ## Differences from PostgREST

  Trailing select junk is rejected with PGRST100 rather than silently ignored.
  """

  alias PgRest.AST.{Aggregate, Embed, Field, SelectField}
  alias PgRest.Error
  alias PgRest.Grammar.Common

  @type item :: Embed.item()

  @aggregates %{
    "sum" => :sum,
    "avg" => :avg,
    "count" => :count,
    "max" => :max,
    "min" => :min
  }

  @field_expecting ~S|letter, digit, "-", "->>", "->", "::", ".", ")", "," or end of input|
  @alias_expecting ~S|":" or | <> Common.name_expecting()
  @end_expecting ~S{"," or end of input}
  @after_cast_expecting ~S{letter, digit, ".", "::", ")", "," or end of input}
  @item_expecting ~S{"...", field name (* or [a..z0..9_$]), "*" or "count()"}
  @empty_embed_expecting ~S{"...", field name (* or [a..z0..9_$]), "*", "count()" or ")"}
  @agg_expecting ~S{"sum", "avg", "count", "max" or "min"}

  @doc """
  Parses a `select=` value into select fields, aggregates and embeds.
  """
  @spec parse(String.t()) :: {:ok, [item()]} | {:error, Error.t()}
  def parse(input) when is_binary(input) do
    with :ok <- Common.reject_nul(input) do
      case forest(input) do
        {:ok, items, ""} -> {:ok, items}
        {:ok, _items, rest} -> {:error, failure(input, rest, @end_expecting, quote: :string)}
        {:fail, rest, expecting} -> {:error, failure(input, rest, expecting)}
      end
    end
  end

  defp failure(input, rest, expecting, opts \\ []),
    do: Common.syntax_error("select parameter", input, input, rest, expecting, opts)

  # --- forest: item (, item)* ------------------------------------------------------

  defp forest(rest) do
    case Common.skip_blanks(rest) do
      <<?), _::binary>> = closing -> {:ok, [], closing}
      "" -> {:ok, [], ""}
      other -> items(other, [])
    end
  end

  defp items(rest, acc) do
    with {:ok, item, rest} <- item(rest) do
      case rest do
        <<?,, after_comma::binary>> -> items(after_comma, [item | acc])
        _ -> {:ok, Enum.reverse([item | acc]), rest}
      end
    end
  end

  defp item(rest) do
    with :no_match <- spread(rest),
         :no_match <- relation(rest) do
      field_select(rest)
    end
  end

  # --- embeds ----------------------------------------------------------------------

  defp spread("..." <> rest) do
    with {:ok, name, rest} <- Common.parse_name(rest),
         {:ok, hint, join, rest} <- embed_params(rest),
         "(" <> _ <- rest do
      embed(%Embed{name: name, hint: hint, join: join, spread: true}, rest)
    else
      _ -> :no_match
    end
  end

  defp spread(_rest), do: :no_match

  defp relation(rest) do
    {alias_name, rest} = optional_alias(rest)

    with {:ok, name, rest} when name != "count" <- Common.parse_name(rest),
         {:ok, hint, join, rest} <- embed_params(rest),
         "(" <> _ <- rest do
      embed(%Embed{name: name, alias: alias_name, hint: hint, join: join}, rest)
    else
      _ -> :no_match
    end
  end

  defp embed(%Embed{} = embed, "(" <> rest) do
    with {:ok, items, rest} <- forest(rest) do
      case Common.skip_blanks(rest) do
        ")" <> after_paren ->
          {:ok, %{embed | select: items}, Common.skip_blanks(after_paren)}

        other ->
          {:fail, other, unclosed_expecting(items)}
      end
    end
  end

  # An embed still empty at the failure expects an item or the closing parenthesis.
  defp unclosed_expecting([]), do: @empty_embed_expecting
  defp unclosed_expecting(_items), do: @field_expecting

  # Up to two `!param`s in either order: `left`, `inner`, or a hint name.
  defp embed_params(rest) do
    {first, rest} = embed_param(rest)
    {second, rest} = embed_param(rest)

    {hint, join} = Enum.reduce([first, second], {nil, nil}, &merge_param/2)
    {:ok, hint, join || :left, rest}
  end

  # The first hint and the first join type win.
  defp merge_param({:hint, name}, {nil, join}), do: {name, join}
  defp merge_param({:join, type}, {hint, nil}), do: {hint, type}
  defp merge_param(_param, acc), do: acc

  defp embed_param("!" <> rest) do
    case rest do
      "left" <> after_param -> {{:join, :left}, Common.skip_blanks(after_param)}
      "inner" <> after_param -> {{:join, :inner}, Common.skip_blanks(after_param)}
      _ -> hint_param(rest)
    end
  end

  defp embed_param(rest), do: {nil, rest}

  defp hint_param(rest) do
    case Common.parse_name(rest) do
      {:ok, name, after_name} -> {{:hint, name}, after_name}
      :no_match -> {nil, "!" <> rest}
    end
  end

  # --- fields and aggregates -------------------------------------------------------

  defp field_select("*" <> rest) do
    with {:ok, rest} <- item_end(rest, @field_expecting) do
      {:ok, %SelectField{field: :star}, rest}
    end
  end

  defp field_select(rest) do
    {alias_name, after_alias} = optional_alias(rest)
    expecting = if alias_name, do: @alias_expecting, else: @item_expecting

    case after_alias do
      "count()" <> after_count -> count_aggregate(alias_name, after_count)
      _ -> column_select(alias_name, after_alias, expecting)
    end
  end

  defp count_aggregate(alias_name, rest) do
    with {:ok, cast, rest} <- optional_cast(rest),
         {:ok, rest} <- item_end(rest, @field_expecting) do
      {:ok, %Aggregate{fun: :count, alias: alias_name, cast: cast}, rest}
    end
  end

  defp column_select(alias_name, rest, expecting) do
    with {:ok, field, after_field} <- Common.parse_field(rest, expecting),
         {:ok, input_cast, rest} <- optional_cast(after_field),
         {:ok, agg, rest} <- aggregate_call(rest),
         {:ok, agg_cast, rest} <- optional_cast(rest),
         {:ok, rest} <- item_end(rest, end_expecting(input_cast, agg_cast)) do
      {:ok, build_select(field, alias_name, agg, input_cast, agg_cast), rest}
    end
  end

  defp build_select(field, alias_name, nil, cast, _agg_cast),
    do: %SelectField{field: field, alias: alias_name, cast: cast}

  defp build_select(field, alias_name, fun, input_cast, cast),
    do: %Aggregate{fun: fun, field: field, alias: alias_name, cast: cast, input_cast: input_cast}

  for {name, fun} <- @aggregates do
    defp aggregate_call("." <> unquote(name) <> "()" <> rest), do: {:ok, unquote(fun), rest}
  end

  defp aggregate_call("." <> rest), do: {:fail, rest, @agg_expecting}

  defp aggregate_call(rest), do: {:ok, nil, rest}

  defp end_expecting(nil, nil), do: @field_expecting
  defp end_expecting(_input_cast, _agg_cast), do: @after_cast_expecting

  # `::type`, matching the cast rule shared with `Builder.cast/2`.
  defp optional_cast("::" <> rest), do: Common.take_cast(rest)

  defp optional_cast(rest), do: {:ok, nil, rest}

  # --- shared pieces ---------------------------------------------------------------

  defp item_end(rest, expecting) do
    case Common.skip_blanks(rest) do
      "" -> {:ok, ""}
      <<char, _::binary>> = rest when char in [?,, ?)] -> {:ok, rest}
      other -> {:fail, other, expecting}
    end
  end

  # `name:` where the colon does not start a `::`.
  defp optional_alias(rest) do
    with {:ok, %Field{name: name, json_path: []}, ":" <> after_colon} <- Common.parse_field(rest),
         false <- String.starts_with?(after_colon, ":") do
      {name, after_colon}
    else
      _ -> {nil, rest}
    end
  end
end
