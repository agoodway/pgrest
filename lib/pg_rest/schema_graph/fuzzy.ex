defmodule PgRest.SchemaGraph.Fuzzy do
  @moduledoc """
  Fuzzy name matching for the "Perhaps you meant ..." hints, modelled on the
  `fuzzyset` library PostgREST uses: gram-count cosine similarity (gram size 3,
  then 2), rescored with a Levenshtein ratio.
  """

  @min_score 0.33
  @rescored 50

  @doc """
  Returns `[{score, candidate}]`, best first, for candidates scoring at least
  #{@min_score} against `value`.
  """
  @spec get([String.t()], String.t()) :: [{float(), String.t()}]
  def get(candidates, value), do: get(candidates, value, @min_score)

  @doc """
  Like `get/2` with a caller-chosen minimum score: PostgREST asks for 0.75 when suggesting
  a table or function name and 0.33 for a parameter list. The first gram size with any
  candidate at or above `min_score` wins.
  """
  @spec get([String.t()], String.t(), float()) :: [{float(), String.t()}]
  def get(candidates, value, min_score) do
    items = candidates |> Enum.uniq() |> Enum.map(&{&1, padded(&1)})
    target = padded(value)

    Enum.find_value([3, 2], [], fn size ->
      case scored(items, {value, target}, size, min_score) do
        [] -> nil
        results -> results
      end
    end)
  end

  @doc "The best match scoring at least `min_score` (default #{@min_score}), or `nil`."
  @spec closest([String.t()], String.t(), float()) :: String.t() | nil
  def closest(candidates, value, min_score \\ @min_score) do
    case get(candidates, value, min_score) do
      [{_score, best} | _] -> best
      [] -> nil
    end
  end

  @doc """
  `render.(best)` for the closest candidate scoring at least `min_score`, or `nil`: the shape of
  every "Perhaps you meant ..." hint.
  """
  @spec hint([String.t()], String.t(), float(), (String.t() -> String.t())) :: String.t() | nil
  def hint(candidates, value, min_score, render) do
    with best when is_binary(best) <- closest(candidates, value, min_score), do: render.(best)
  end

  # Cosine over the padded, cleaned gram vectors picks at most 50 candidates; each is rescored
  # as `fuzzyset` does, with the normalized Levenshtein ratio of the lowercased originals.
  defp scored(items, {value, target}, size, min_score) do
    value_grams = grams(target, size)
    value_norm = norm(value_grams)
    value_lower = String.downcase(value)
    value_length = String.length(value_lower)

    items
    |> Enum.map(fn {original, text} ->
      item_grams = grams(text, size)
      {original, dot(value_grams, item_grams), norm(item_grams)}
    end)
    |> Enum.filter(fn {_original, dot, _norm} -> dot > 0 end)
    |> Enum.map(fn {original, dot, item_norm} -> {dot / (value_norm * item_norm), original} end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(@rescored)
    |> Enum.map(fn {_cosine, original} -> {String.downcase(original), original} end)
    # The ratio is at most min(len)/max(len), so a candidate below `min_score` on length alone
    # can never pass; skipping it keeps the edit distance off URL-sized terms.
    |> Enum.filter(fn {lower, _original} -> length_ratio(lower, value_length) >= min_score end)
    |> Enum.map(fn {lower, original} -> {ratio(lower, value_lower), original} end)
    |> Enum.filter(fn {score, _} -> score >= min_score end)
    # Ties are common for short names and upstream order is unspecified; take the
    # alphabetically first so hints are deterministic.
    |> Enum.sort_by(fn {score, candidate} -> {-score, candidate} end)
  end

  # The text the gram vectors are built from: lowercased, stripped to letters, digits, commas
  # and spaces, and padded with "-". The Levenshtein rescoring does not use it.
  defp padded(text) do
    cleaned = text |> String.downcase() |> String.replace(~r/[^\p{L}\p{N} ,]/u, "")
    "-" <> cleaned <> "-"
  end

  # Linear in the text length: callers feed request-sized strings through here.
  defp grams(text, size) do
    text
    |> String.pad_trailing(size, "-")
    |> String.graphemes()
    |> Enum.chunk_every(size, 1, :discard)
    |> Enum.frequencies()
  end

  defp norm(grams),
    do: grams |> Map.values() |> Enum.map(&(&1 * &1)) |> Enum.sum() |> :math.sqrt()

  defp dot(left, right) do
    Enum.reduce(left, 0, fn {gram, count}, acc -> acc + count * Map.get(right, gram, 0) end)
  end

  defp length_ratio(lower, value_length) do
    longest = max(String.length(lower), value_length)
    if longest == 0, do: 1.0, else: min(String.length(lower), value_length) / longest
  end

  defp ratio(left, right) do
    longest = max(String.length(left), String.length(right))
    if longest == 0, do: 1.0, else: 1 - levenshtein(left, right) / longest
  end

  @doc "Levenshtein edit distance between two strings (by grapheme)."
  @spec levenshtein(String.t(), String.t()) :: non_neg_integer()
  def levenshtein(left, right) do
    right = String.graphemes(right)
    first_row = Enum.to_list(0..length(right))

    left
    |> String.graphemes()
    |> Enum.with_index(1)
    |> Enum.reduce(first_row, fn {l, i}, previous ->
      next_row(l, i, right, previous)
    end)
    |> List.last()
  end

  defp next_row(l, i, right, previous) do
    right
    |> Enum.zip(Enum.zip(previous, tl(previous)))
    |> Enum.reduce([i], fn {r, {diagonal, above}}, [left | _] = row ->
      cost = if l == r, do: 0, else: 1
      [min(left + 1, min(above + 1, diagonal + cost)) | row]
    end)
    |> Enum.reverse()
  end
end
