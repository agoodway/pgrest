defmodule PgRest.Compat.Compare do
  @moduledoc """
  Compares two HTTP responses on what a client can observe: status, body and a
  semantic header allowlist. Transport details (`Server`, `Date`, ordering) are
  ignored. A scenario that asserts custom headers (`x-test`, `set-cookie`) names them with
  `diff/3`'s `headers:` option, which adds them to the allowlist.

  Responses are `%{status: integer, headers: %{lowercase_name => value | [value]}, body: binary}`
  with `body` the raw wire body.
  """

  @headers ~w(content-range content-type preference-applied location content-location content-profile allow range-unit)

  @type response :: %{
          status: integer(),
          headers: %{String.t() => String.t() | [String.t()]},
          body: binary()
        }

  @doc "The header names that take part in the comparison."
  @spec semantic_headers() :: [String.t()]
  def semantic_headers, do: @headers

  @doc """
  Returns `:ok` when the responses match, otherwise `{:error, description}`.

  With `sort: true` the top-level JSON array is compared order-insensitively. With
  `compare: :plan` (default `:exact`) a successful body is checked for query-plan shape
  instead of equality: a JSON plan is a one-element array whose element has a `"Plan"`
  key, a text plan is non-empty and starts with a `(cost=` line. Status and the
  semantic headers still match exactly, and error bodies are still compared exactly.

  `headers:` (lowercase names, default `[]`) adds headers to the allowlist for this
  comparison. A repeated header is a list of its values in wire order (two `Set-Cookie`s),
  so it is compared as an ordered value list and never equals one merged `"a, b"` value.
  """
  @spec diff(response(), response(), keyword()) :: :ok | {:error, String.t()}
  def diff(expected, actual, opts) do
    sort? = Keyword.get(opts, :sort, false)
    bodies = bodies(Keyword.get(opts, :compare, :exact), expected, actual, sort?)

    headers = @headers ++ Keyword.get(opts, :headers, [])

    case compare_status(expected, actual) ++ compare_headers(headers, expected, actual) ++ bodies do
      [] -> :ok
      errors -> {:error, Enum.join(errors, "\n")}
    end
  end

  defp bodies(:plan, %{status: status} = expected, %{status: status} = actual, _sort?)
       when status in 200..299,
       do: plan_shape(expected, "expected") ++ plan_shape(actual, "actual")

  defp bodies(_mode, expected, actual, sort?), do: compare_bodies(expected, actual, sort?)

  defp plan_shape(%{body: body} = response, side) do
    if json?(response), do: json_plan_shape(body, side), else: text_plan_shape(body, side)
  end

  defp json_plan_shape(body, side) do
    case Jason.decode(body) do
      {:ok, [%{"Plan" => _}]} -> []
      _ -> ["plan: #{side} body is not a one-element array with a \"Plan\" key: #{inspect(body)}"]
    end
  end

  defp text_plan_shape(body, side) do
    if body |> String.split("\n", parts: 2) |> hd() |> String.match?(~r/^\S.*\(cost=/),
      do: [],
      else: ["plan: #{side} text body has no `(cost=` first line: #{inspect(body)}"]
  end

  defp compare_status(%{status: status}, %{status: status}), do: []

  defp compare_status(expected, actual),
    do: ["status: expected #{expected.status}, got #{actual.status}"]

  defp compare_headers(names, expected, actual) do
    names
    |> Enum.flat_map(fn name ->
      left = header(expected, name)
      right = header(actual, name)

      if left == right,
        do: [],
        else: ["header #{name}: expected #{inspect(left)}, got #{inspect(right)}"]
    end)
  end

  defp header(%{headers: headers}, "content-type") do
    headers |> Map.get("content-type") |> strip_charset()
  end

  defp header(%{headers: headers}, name), do: Map.get(headers, name)

  defp strip_charset(nil), do: nil

  defp strip_charset(value) do
    value
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&String.starts_with?(String.downcase(&1), "charset="))
    |> Enum.join("; ")
    |> String.downcase()
  end

  defp compare_bodies(%{body: ""}, %{body: ""}, _sort?), do: []

  defp compare_bodies(%{body: ""}, actual, _sort?),
    do: ["body: expected empty, got #{inspect(actual.body)}"]

  defp compare_bodies(expected, %{body: ""}, _sort?),
    do: ["body: expected #{inspect(expected.body)}, got empty"]

  defp compare_bodies(expected, actual, sort?) do
    if json?(expected) or json?(actual) do
      compare_json(expected.body, actual.body, sort?)
    else
      compare_text(expected.body, actual.body)
    end
  end

  defp json?(response), do: json_content_type?(response.headers)

  @doc """
  Whether a header map names a JSON media type. Parameters do not count: a text plan's
  `for="application/json"` must not make it JSON.
  """
  @spec json_content_type?(%{String.t() => String.t()}) :: boolean()
  def json_content_type?(headers) do
    [media_type | _] = headers |> Map.get("content-type") |> to_string() |> String.split(";")

    String.contains?(media_type, "json")
  end

  defp compare_text(body, body), do: []

  defp compare_text(expected, actual),
    do: ["body (text): expected #{inspect(expected)}, got #{inspect(actual)}"]

  defp compare_json(expected, actual, sort?) do
    with {:ok, left} <- decode(expected, "expected"),
         {:ok, right} <- decode(actual, "actual") do
      if normalize(left, sort?) == normalize(right, sort?),
        do: [],
        else: ["body (JSON): expected #{inspect(left)}, got #{inspect(right)}"]
    else
      {:error, message} -> [message]
    end
  end

  @spec decode(binary(), String.t()) :: {:ok, term()} | {:error, String.t()}
  defp decode(body, side) do
    case Jason.decode(body) do
      {:ok, term} -> {:ok, term}
      {:error, _} -> {:error, "body: #{side} is not valid JSON: #{inspect(body)}"}
    end
  end

  defp normalize(list, true) when is_list(list), do: Enum.sort(list)
  defp normalize(term, _sort?), do: term
end
