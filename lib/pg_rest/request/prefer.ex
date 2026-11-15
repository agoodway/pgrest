defmodule PgRest.Request.Prefer do
  @moduledoc """
  Parses `Prefer` headers into a `PgRest.Prefer` and renders `Preference-Applied`.

  Matches PostgREST: tokens are comma separated, whitespace around a whole token
  is ignored (not around `=`), and for each preference the first recognized value
  wins, in request order across repeated headers. Any `timezone=` or
  `max-affected=` token is recognized whatever its value (an unparseable
  `max-affected` becomes `nil` and still claims the first slot; `0` and negative integers
  parse, as in PostgREST). Everything else, including an empty token from a trailing comma
  and an unrecognized value of a known key (`return=foo`), goes to `unknown`.

  `validate/2` then applies the server-side rules: a timezone the server does not know is
  dropped (so it is neither applied nor echoed), and under `handling=strict` any invalid
  token is a 400 `PGRST122`.
  """

  alias PgRest.Catalog.Facts
  alias PgRest.{Error, Prefer}

  # The one spelling of the timezone preference: parsed, and rendered in `Preference-Applied`.
  @timezone "timezone="

  @tokens (for {name, values} <- [
                 return: [
                   {"minimal", :minimal},
                   {"headers-only", :headers_only},
                   {"representation", :representation}
                 ],
                 count: [{"exact", :exact}, {"planned", :planned}, {"estimated", :estimated}],
                 resolution: [
                   {"merge-duplicates", :merge_duplicates},
                   {"ignore-duplicates", :ignore_duplicates}
                 ],
                 missing: [{"default", :default}, {"null", :null}],
                 handling: [{"lenient", :lenient}, {"strict", :strict}],
                 tx: [{"commit", :commit}, {"rollback", :rollback}]
               ],
               {wire, value} <- values,
               into: %{} do
             {"#{name}=#{wire}", {name, value}}
           end)

  # `Preference-Applied` order, as PostgREST renders it.
  @applied_order [
    :resolution,
    :missing,
    :return,
    :count,
    :tx,
    :handling,
    :timezone,
    :max_affected
  ]

  @doc "Parses the values of every `Prefer` request header, in request order."
  @spec parse([String.t()]) :: Prefer.t()
  def parse(header_values) do
    tokens =
      header_values
      |> Enum.reject(&(&1 == ""))
      |> Enum.flat_map(&String.split(&1, ","))
      |> Enum.map(&String.trim/1)

    {recognized, unknown} = Enum.reduce(tokens, {%{}, []}, &token/2)

    struct!(
      Prefer,
      Map.merge(recognized, %{
        unknown: Enum.reverse(unknown),
        tokens: tokens,
        handling_sent: Map.has_key?(recognized, :handling)
      })
    )
  end

  @doc """
  Applies the server-side rules to a parsed `Prefer` (PostgREST v14 semantics).

  A timezone not in `facts.timezones` (decided by the first `timezone=` token, as PostgREST
  does) becomes `timezone: nil`. Under `handling=strict`, every invalid token (the unknown
  ones and, when the timezone is invalid, every `timezone=` token) makes the request a 400
  `PGRST122` listing them in request order, for every method and for RPC. Under `lenient`
  nothing fails.
  """
  @spec validate(Prefer.t(), Facts.t()) :: {:ok, Prefer.t()} | {:error, Error.t()}
  def validate(%Prefer{} = prefer, %Facts{timezones: names}) do
    timezone_valid? = prefer.timezone != nil and MapSet.member?(names, prefer.timezone)
    prefer = if timezone_valid?, do: prefer, else: %{prefer | timezone: nil}

    case invalid_tokens(prefer, timezone_valid?) do
      [] -> {:ok, prefer}
      tokens when prefer.handling == :strict -> {:error, Error.invalid_preferences(tokens)}
      _tokens -> {:ok, prefer}
    end
  end

  defp invalid_tokens(%Prefer{tokens: tokens, unknown: unknown}, timezone_valid?) do
    unknown = MapSet.new(unknown)

    Enum.filter(tokens, fn token ->
      MapSet.member?(unknown, token) or (not timezone_valid? and timezone_token?(token))
    end)
  end

  defp timezone_token?(@timezone <> _tz), do: true
  defp timezone_token?(_token), do: false

  @doc """
  Renders the `Preference-Applied` value for the preferences named in `applied_keys`
  that are set, in PostgREST's order. `max_affected` only appears under
  `handling=strict`. Returns `nil` when nothing is applied.
  """
  @spec applied_header(Prefer.t(), [atom()]) :: String.t() | nil
  def applied_header(%Prefer{} = prefer, applied_keys) do
    case for(key <- @applied_order, key in applied_keys, part = render(prefer, key), do: part) do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  defp token(@timezone <> tz, {recognized, unknown}),
    do: {Map.put_new(recognized, :timezone, tz), unknown}

  defp token("max-affected=" <> n, {recognized, unknown}),
    do: {Map.put_new(recognized, :max_affected, integer(n)), unknown}

  defp token(token, {recognized, unknown}) do
    case Map.fetch(@tokens, token) do
      {:ok, {key, value}} -> {Map.put_new(recognized, key, value), unknown}
      :error -> {recognized, [token | unknown]}
    end
  end

  # An optional minus sign and digits. PostgREST's `readMaybe` for an Int64 also accepts
  # surrounding whitespace, hex/octal (`0x10`) and parentheses and wraps on overflow; those
  # edge forms are not mirrored (they read as `nil`).
  defp integer(string) do
    if Regex.match?(~r/\A-?\d+\z/, string), do: String.to_integer(string)
  end

  defp render(%Prefer{handling: :strict, max_affected: n}, :max_affected) when is_integer(n),
    do: "max-affected=#{n}"

  defp render(%Prefer{}, :max_affected), do: nil
  defp render(%Prefer{timezone: nil}, :timezone), do: nil
  defp render(%Prefer{timezone: tz}, :timezone), do: @timezone <> tz

  defp render(%Prefer{} = prefer, key) do
    case Map.fetch!(prefer, key) do
      nil ->
        nil

      value ->
        Enum.find_value(@tokens, fn
          {token, {^key, ^value}} -> token
          _ -> nil
        end)
    end
  end
end
