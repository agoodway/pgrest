defmodule PgRest.Request.Range do
  @moduledoc """
  Combines the `Range` header with the `limit`/`offset` query parameters into a
  single `%{offset, limit}`, porting PostgREST's `getRanges`.

  Ranges are inclusive `{lower, upper}` row intervals where `upper` may be
  `:inf`. The header range is intersected with the limit/offset range; an empty
  result is a 416 `PGRST103`, except for the special `limit=0` range
  `{0, -1}` which means "no rows". Only GET honors the `Range` header (HEAD does
  not), as recorded from PostgREST.
  """

  alias PgRest.Error

  @all {0, :inf}
  @limit_zero {0, -1}

  @type t :: %{offset: non_neg_integer(), limit: non_neg_integer() | nil}

  @doc "Computes the effective offset and limit for a request."
  @spec from(String.t(), [{String.t(), String.t()}], [{String.t(), String.t()}]) ::
          {:ok, t()} | {:error, Error.t()}
  def from(method, headers, params) do
    header_range = if method == "GET", do: header_range(headers), else: @all
    limit_range = param_range(params)
    combined = intersect(header_range, limit_range)
    top_level = if limit_zero?(limit_range), do: @limit_zero, else: combined

    cond do
      empty?(top_level) and not limit_zero?(limit_range) ->
        {:error, invalid_range(empty?(header_range))}

      method == "PUT" and top_level != @all ->
        {:error, Error.put_limit_not_allowed()}

      true ->
        {:ok, to_window(top_level)}
    end
  end

  defp header_range(headers) do
    value = Enum.find_value(headers, fn {name, value} -> name == "range" && value end)

    case value && Regex.run(~r/^([0-9]+)-([0-9]*)$/, value) do
      [_, lower, ""] -> {String.to_integer(lower), :inf}
      [_, lower, upper] -> {String.to_integer(lower), String.to_integer(upper)}
      _ -> @all
    end
  end

  # The range from `limit`/`offset`: the last occurrence of each key wins and
  # unparseable values count as present-but-NaN: a NaN `limit` counts as
  # `limit=0` when an `offset` exists, as in PostgREST, and is ignored alone.
  defp param_range(params) do
    case {integer_param(params, "limit"), integer_param(params, "offset")} do
      {:absent, :absent} -> @all
      {:absent, offset} -> {offset_of(offset), :inf}
      {:nan, :absent} -> @all
      {limit, :absent} -> {0, limit - 1}
      {limit, offset} -> {offset_of(offset), offset_of(offset) + limit_of(limit) - 1}
    end
  end

  defp offset_of(:nan), do: 0
  defp offset_of(offset), do: offset

  defp limit_of(:nan), do: 0
  defp limit_of(limit), do: limit

  defp integer_param(params, key) do
    with value when is_binary(value) <- last_value(params, key),
         {n, ""} <- Integer.parse(String.trim(value)) do
      n
    else
      nil -> :absent
      _ -> :nan
    end
  end

  defp last_value(params, key) do
    params |> Enum.reverse() |> Enum.find_value(fn {name, value} -> name == key && value end)
  end

  defp intersect({lower_a, upper_a}, {lower_b, upper_b}),
    do: {max(lower_a, lower_b), min_upper(upper_a, upper_b)}

  defp min_upper(:inf, other), do: other
  defp min_upper(other, :inf), do: other
  defp min_upper(a, b), do: min(a, b)

  defp empty?({_lower, :inf}), do: false
  defp empty?({lower, upper}), do: lower > upper

  defp limit_zero?({_lower, -1}), do: true
  defp limit_zero?(_range), do: false

  defp to_window({lower, :inf}), do: %{offset: lower, limit: nil}
  defp to_window({lower, upper}), do: %{offset: lower, limit: max(upper - lower + 1, 0)}

  defp invalid_range(true),
    do:
      Error.invalid_range(
        "The lower boundary must be lower than or equal to the upper boundary in the Range header."
      )

  defp invalid_range(false),
    do: Error.invalid_range("Limit should be greater than or equal to zero.")
end
