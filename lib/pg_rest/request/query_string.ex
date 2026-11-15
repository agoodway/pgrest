defmodule PgRest.Request.QueryString do
  @moduledoc """
  Parses a raw query string into an ordered list of `{key, value}` pairs.

  Pairs split on `&` and `;` (as PostgREST does). Order and duplicate keys are
  preserved (`a=1&a=2` stays two pairs), `+` decodes to a space, and malformed
  percent-encoding is a 400 rather than an exception.

  A key with no `=` (`?id`) has a `nil` value, while `?id=` has `""`. PostgREST
  ignores the former and parses the latter as a filter (400), so consumers drop
  `nil`-valued pairs.

  ## Differences from PostgREST

  Malformed percent escapes return PGRST100 rather than being tolerated.
  """

  alias PgRest.Error

  @doc "Splits on `&` or `;`, then the first `=`, decoding both sides."
  @spec parse(binary()) :: {:ok, [{String.t(), String.t() | nil}]} | {:error, Error.t()}
  def parse(query_string) do
    with {:ok, pairs} <- query_string |> String.split(["&", ";"], trim: true) |> decode_pairs([]) do
      {:ok, Enum.reverse(pairs)}
    end
  end

  defp decode_pairs([], acc), do: {:ok, acc}

  defp decode_pairs([segment | rest], acc) do
    with {:ok, pair} <- pair(segment), do: decode_pairs(rest, [pair | acc])
  end

  defp pair(segment) do
    {key, value} =
      case String.split(segment, "=", parts: 2) do
        [key, value] -> {key, value}
        [key] -> {key, nil}
      end

    with {:ok, key} <- decode(key),
         {:ok, value} <- decode_value(value) do
      {:ok, {key, value}}
    end
  end

  defp decode_value(nil), do: {:ok, nil}
  defp decode_value(value), do: decode(value)

  defp decode(binary) do
    # `URI.decode_www_form/1` leaves a bad `%` in place, so check it first.
    if Regex.match?(~r/%(?![0-9A-Fa-f]{2})/, binary) do
      {:error, malformed(binary)}
    else
      decoded = URI.decode_www_form(binary)
      if String.valid?(decoded), do: {:ok, decoded}, else: {:error, malformed(binary)}
    end
  end

  defp malformed(binary) do
    Error.parse_error(
      "Malformed percent-encoding in the query string",
      "Invalid percent-encoding near #{inspect(snippet(binary))}."
    )
  end

  # The text from the first bad `%` on, for the error details.
  defp snippet(binary) do
    case Regex.run(~r/%(?![0-9A-Fa-f]{2}).{0,3}/s, binary) do
      [rest] -> rest
      _ -> binary
    end
  end
end
