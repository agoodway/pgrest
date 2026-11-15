defmodule PgRest.SQL.Placeholders do
  @moduledoc """
  Shifts the `$n` placeholders of a SQL text by an offset.

  This is a tokenizer, not a regex: it skips standard strings (doubled quotes), `E'...'`
  strings (backslash escapes), dollar quoting, `--` and nested `/* */` comments and quoted
  identifiers, and only renumbers placeholders found outside them.

  It assumes `standard_conforming_strings = on` (the default), where a backslash is
  literal inside `'...'`. With it off the scan can disagree with the server about where
  a string ends, which fails closed: the placeholder check or a Postgres syntax error
  rejects the statement.
  """

  @doc """
  Adds `offset` to every placeholder in `sql`.

  Raises `ArgumentError` unless the placeholders found are exactly `$1..$param_count`
  (each used at least once), or when a `$` outside a token cannot be classified.
  """
  @spec renumber(String.t(), non_neg_integer(), non_neg_integer()) :: String.t()
  def renumber(sql, offset, param_count)
      when is_binary(sql) and is_integer(offset) and offset >= 0 and is_integer(param_count) and
             param_count >= 0 do
    {iodata, seen} = scan(sql, offset, [], %{})
    found = seen |> Map.keys() |> Enum.sort()

    if found != Enum.to_list(1..param_count//1) do
      raise ArgumentError,
            "expected placeholders $1..$#{param_count}, found #{inspect(found)}"
    end

    iodata |> Enum.reverse() |> IO.iodata_to_binary()
  end

  defp scan(<<>>, _offset, acc, seen), do: {acc, seen}

  defp scan(<<c, _::binary>> = bin, offset, acc, seen)
       when c in ?a..?z or c in ?A..?Z or c in ?0..?9 or c == ?_ or c >= 128 do
    [word] = Regex.run(~r/\A[A-Za-z0-9_\x80-\xff][A-Za-z0-9_$\x80-\xff]*/, bin)
    rest = binary_part(bin, byte_size(word), byte_size(bin) - byte_size(word))

    case {word, rest} do
      {w, <<?', after_quote::binary>>} when w in ["E", "e"] ->
        {taken, rest} = take_estring(after_quote, 0)
        scan(rest, offset, [taken, "'", word | acc], seen)

      _ ->
        scan(rest, offset, [word | acc], seen)
    end
  end

  defp scan(<<?', rest::binary>>, offset, acc, seen) do
    {taken, rest} = take_quoted(rest, ?', 0)
    scan(rest, offset, [taken, "'" | acc], seen)
  end

  defp scan(<<?", rest::binary>>, offset, acc, seen) do
    {taken, rest} = take_quoted(rest, ?", 0)
    scan(rest, offset, [taken, "\"" | acc], seen)
  end

  defp scan(<<"--", rest::binary>>, offset, acc, seen) do
    {taken, rest} = take_line(rest)
    scan(rest, offset, [taken, "--" | acc], seen)
  end

  defp scan(<<"/*", rest::binary>>, offset, acc, seen) do
    {taken, rest} = take_block(rest, 0, 1)
    scan(rest, offset, [taken, "/*" | acc], seen)
  end

  defp scan(<<?$, rest::binary>>, offset, acc, seen) do
    case Regex.run(~r/\A[0-9]+/, rest) do
      [digits] ->
        n = String.to_integer(digits)
        rest = binary_part(rest, byte_size(digits), byte_size(rest) - byte_size(digits))
        scan(rest, offset, ["$" <> Integer.to_string(n + offset) | acc], Map.put(seen, n, true))

      nil ->
        {taken, rest} = take_dollar_quoted(rest)
        scan(rest, offset, [taken | acc], seen)
    end
  end

  defp scan(<<c, rest::binary>>, offset, acc, seen), do: scan(rest, offset, [<<c>> | acc], seen)

  # Takes a quoted token body (after the opening quote), honouring doubled quotes.
  defp take_quoted(bin, q, from) do
    case :binary.match(bin, <<q>>, scope: {from, byte_size(bin) - from}) do
      :nomatch ->
        raise ArgumentError, "unterminated quoted token in SQL"

      {pos, 1} ->
        n = pos + 1

        case bin do
          <<_::binary-size(n), ^q, _::binary>> -> take_quoted(bin, q, n + 1)
          _ -> :erlang.split_binary(bin, n)
        end
    end
  end

  defp take_estring(bin, i) when i >= byte_size(bin),
    do: raise(ArgumentError, "unterminated E'' string in SQL")

  defp take_estring(bin, i) do
    case :binary.at(bin, i) do
      ?\\ ->
        take_estring(bin, i + 2)

      ?' ->
        if i + 1 < byte_size(bin) and :binary.at(bin, i + 1) == ?' do
          take_estring(bin, i + 2)
        else
          :erlang.split_binary(bin, i + 1)
        end

      _ ->
        take_estring(bin, i + 1)
    end
  end

  defp take_line(bin) do
    case :binary.match(bin, "\n") do
      {pos, 1} -> :erlang.split_binary(bin, pos + 1)
      :nomatch -> {bin, ""}
    end
  end

  defp take_block(bin, i, _depth) when i + 1 >= byte_size(bin),
    do: raise(ArgumentError, "unterminated block comment in SQL")

  defp take_block(bin, i, depth) do
    case binary_part(bin, i, 2) do
      "*/" when depth == 1 -> :erlang.split_binary(bin, i + 2)
      "*/" -> take_block(bin, i + 2, depth - 1)
      "/*" -> take_block(bin, i + 2, depth + 1)
      _ -> take_block(bin, i + 1, depth)
    end
  end

  # `rest` starts right after a `$` that is not followed by a digit.
  defp take_dollar_quoted(rest) do
    case Regex.run(~r/\A(?:[A-Za-z_\x80-\xff][A-Za-z0-9_\x80-\xff]*)?\$/, rest) do
      [tag_and_dollar] ->
        delimiter = "$" <> tag_and_dollar

        body =
          binary_part(
            rest,
            byte_size(tag_and_dollar),
            byte_size(rest) - byte_size(tag_and_dollar)
          )

        case :binary.match(body, delimiter) do
          {pos, len} ->
            {taken, rest} = :erlang.split_binary(body, pos + len)
            {[delimiter, taken], rest}

          :nomatch ->
            raise ArgumentError, "unterminated dollar-quoted string in SQL"
        end

      nil ->
        raise ArgumentError,
              "cannot classify `$` in SQL near #{inspect(String.slice(rest, 0, 20))}"
    end
  end
end
