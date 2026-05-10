defmodule PgRest.Parser.Splitter do
  @moduledoc false
  # Internal helper for splitting filter strings on top-level commas while
  # respecting nested parentheses (used by `in.(...)` and logical conditions).

  @doc """
  Splits `str` on top-level commas. Commas inside parentheses are preserved.
  """
  @spec split_top_level(String.t()) :: [String.t()]
  def split_top_level(str), do: do_split(str, 0, "", [])

  defp do_split("", _depth, current, acc),
    do: Enum.reverse([current | acc])

  defp do_split("(" <> rest, depth, current, acc),
    do: do_split(rest, depth + 1, current <> "(", acc)

  defp do_split(")" <> rest, depth, current, acc) when depth > 0,
    do: do_split(rest, depth - 1, current <> ")", acc)

  defp do_split("," <> rest, 0, current, acc),
    do: do_split(rest, 0, "", [current | acc])

  defp do_split(<<char::binary-size(1), rest::binary>>, depth, current, acc),
    do: do_split(rest, depth, current <> char, acc)
end
