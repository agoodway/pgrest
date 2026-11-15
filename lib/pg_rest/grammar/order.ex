defmodule PgRest.Grammar.Order do
  @moduledoc """
  Parser for the PostgREST `order=` parameter:
  `a.desc.nullslast,data->>x,clients(name).asc`.

  A term is a field (with optional JSON path) or `relation(field)` for ordering by a
  column of a to-one embed, then optionally `.asc`/`.desc` and
  `.nullsfirst`/`.nullslast`.
  """

  alias PgRest.AST.OrderTerm
  alias PgRest.Error
  alias PgRest.Grammar.Common

  @dirs [{"asc", :asc}, {"desc", :desc}]
  @nulls [{"nullsfirst", :first}, {"nullslast", :last}]

  @field_expecting ~S|letter, digit, "-", "->>", "->", delimiter (.), "," or end of input|
  @after_dir_expecting ~S|delimiter (.), "," or end of input|
  @end_expecting ~S|"," or end of input|
  @modifier_expecting ~S|"asc", "desc", "nullsfirst" or "nullslast"|
  @nulls_expecting ~S|"nullsfirst" or "nullslast"|

  @doc """
  Parses an `order=` value into order terms.
  """
  @spec parse(String.t()) :: {:ok, [OrderTerm.t()]} | {:error, Error.t()}
  def parse(input) when is_binary(input) do
    with :ok <- Common.reject_nul(input) do
      case terms(input, []) do
        {:ok, terms, ""} -> {:ok, terms}
        {:fail, rest, expecting} -> {:error, failure(input, rest, expecting)}
      end
    end
  end

  defp failure(input, rest, expecting),
    do: Common.syntax_error("order", input, input, rest, expecting)

  defp terms(rest, acc) do
    with {:ok, term, rest} <- term(rest) do
      case rest do
        "," <> after_comma -> terms(after_comma, [term | acc])
        _ -> {:ok, Enum.reverse([term | acc]), rest}
      end
    end
  end

  # `relation(field)` first; any failure there falls back to a plain field term.
  defp term(rest) do
    with :no_match <- relation_term(rest), do: plain_term(rest)
  end

  defp relation_term(rest) do
    with {:ok, relation, "(" <> inner} <- Common.parse_name(rest),
         {:ok, field, ")" <> after_paren} <- Common.parse_field(inner),
         {:ok, term, rest} <- modifiers(%OrderTerm{field: field, relation: relation}, after_paren) do
      {:ok, term, rest}
    else
      _ -> :no_match
    end
  end

  defp plain_term(rest) do
    with {:ok, field, after_field} <- Common.parse_field(rest, Common.name_expecting()),
         do: modifiers(%OrderTerm{field: field}, after_field)
  end

  defp modifiers(%OrderTerm{} = term, rest) do
    with {:ok, term, rest, expecting} <- direction(term, rest),
         {:ok, term, rest, expecting} <- nulls(term, rest, expecting) do
      case Common.skip_blanks(rest) do
        "" -> {:ok, term, ""}
        "," <> _ = rest -> {:ok, term, rest}
        other -> {:fail, other, expecting}
      end
    end
  end

  # The last element is what the parser expects when nothing more matches.
  defp direction(term, "." <> after_dot) do
    with nil <- keyword(after_dot, @dirs, :dir, term, @after_dir_expecting),
         nil <- keyword(after_dot, @nulls, :nulls, term, @end_expecting) do
      {:fail, after_dot, @modifier_expecting}
    end
  end

  defp direction(term, rest), do: {:ok, term, rest, @field_expecting}

  defp nulls(%OrderTerm{nulls: nil} = term, "." <> after_dot, _expecting) do
    with nil <- keyword(after_dot, @nulls, :nulls, term, @end_expecting) do
      {:fail, after_dot, @nulls_expecting}
    end
  end

  defp nulls(term, rest, expecting), do: {:ok, term, rest, expecting}

  defp keyword(input, words, key, term, expecting) do
    Enum.find_value(words, fn {word, value} ->
      case input do
        ^word <> rest -> {:ok, Map.put(term, key, value), rest, expecting}
        _ -> nil
      end
    end)
  end
end
