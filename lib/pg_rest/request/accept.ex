defmodule PgRest.Request.Accept do
  @moduledoc """
  Parses an `Accept` header into `PgRest.MediaType`s, PostgREST's `Accept` handling.

  The header is split on `,` outside double quotes; each type's parameters on `;` outside
  quotes. As in wai (PostgREST), spaces are dropped and a lowercase `;q=` ends the type: its value
  (default `1.0`) orders the types, highest first, ties going to the more specific type
  (parameters count for it, `*` against) and then to header order.
  Parameters read: `nulls=stripped` (on `application/vnd.pgrst.array` and
  `application/vnd.pgrst.object` only; the name is case-insensitive, the value may be quoted and
  is case-sensitive), and for the plan type `for="<media type>"` and
  `options=<name>|<name>` (an empty value or a trailing `;` is fine: supabase-js sends
  `options=;`). Unknown plan options are ignored. A missing header is `*/*`, an empty one no
  type at all (which `PgRest.Negotiate` answers with JSON).

  Types and parameter names are matched against fixed tables; nothing a client sends becomes an
  atom.
  """

  alias PgRest.MediaType

  @kinds %{
    "application/json" => :json,
    "*/*" => :any,
    "application/vnd.pgrst.object" => :object,
    "application/vnd.pgrst.object+json" => :object,
    "application/vnd.pgrst.array" => :array,
    "application/vnd.pgrst.array+json" => :array,
    "text/csv" => :csv
  }
  @plan_formats %{
    "application/vnd.pgrst.plan" => :text,
    "application/vnd.pgrst.plan+text" => :text,
    "application/vnd.pgrst.plan+json" => :json
  }
  # Types PostgREST knows and this library does not serve: listed by their bare name.
  @known_other ~w(text/plain text/xml application/octet-stream application/geo+json
                  application/x-www-form-urlencoded application/openapi+json)
  @plan_options [
    {"analyze", :analyze},
    {"verbose", :verbose},
    {"settings", :settings},
    {"buffers", :buffers},
    {"wal", :wal}
  ]

  @doc "The media types of an `Accept` header value, by descending `q`."
  @spec parse(String.t() | nil) :: [MediaType.t()]
  def parse(nil), do: [MediaType.any()]

  def parse(header) do
    header
    |> split_outside_quotes(?,)
    |> Enum.map(&String.replace(&1, " ", ""))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&media_type/1)
    |> Enum.sort_by(fn {media, specificity} -> {media.q, specificity} end, :desc)
    |> Enum.map(&elem(&1, 0))
  end

  # As wai: spaces are gone, `;q=` (lowercase) ends the type and the rest is its quality.
  # Ties in `q` go to the more specific type: its parameters count for, its `*` against.
  defp media_type(compact) do
    {main, q} =
      case :binary.split(compact, ";q=") do
        [main] -> {main, 1.0}
        [main, rest] -> {main, quality(rest)}
      end

    [base | params] = split_outside_quotes(main, ?;)
    params = Enum.reject(params, &(&1 == ""))
    lowered = String.downcase(base)
    kind = kind(lowered)
    stripped? = kind in [:array, :object] and Enum.any?(params, &stripped?/1)

    plan = plan(lowered, params)

    media = %MediaType{
      kind: kind,
      raw: raw(kind, lowered, main, stripped?, plan),
      q: q,
      nulls_stripped?: stripped?,
      plan: plan
    }

    {media, count(main, ?;) - count(main, ?*)}
  end

  defp quality(text) do
    case Float.parse(text) do
      {q, _rest} -> q
      :error -> 1.0
    end
  end

  defp count(text, byte), do: text |> :binary.matches(<<byte>>) |> length()

  # What a PGRST107 lists: the canonical name of a type PostgREST knows, the text as sent
  # (spaces removed) of any other.
  defp raw(:json, _base, _main, _stripped?, _plan), do: "application/json"
  defp raw(:csv, _base, _main, _stripped?, _plan), do: "text/csv"
  defp raw(:any, _base, _main, _stripped?, _plan), do: "*/*"

  defp raw(kind, _base, _main, stripped?, _plan) when kind in [:array, :object],
    do: "application/vnd.pgrst.#{kind}+json" <> if(stripped?, do: ";nulls=stripped", else: "")

  defp raw(:plan, _base, _main, _stripped?, plan), do: plan_raw(plan)
  defp raw(:other, base, _main, _stripped?, _plan) when base in @known_other, do: base
  defp raw(_kind, _base, main, _stripped?, _plan), do: main

  # PostgREST's `toMime`: the format, the type it is for (an array that is not stripped is
  # plain JSON there) and the options, in canonical order.
  defp plan_raw(%{format: format, for: target, options: options}) do
    "application/vnd.pgrst.plan+#{format}; for=\"#{for_name(target)}\"" <>
      if(options == [],
        do: "",
        else: "; options=" <> Enum.map_join(options, "|", &Atom.to_string/1)
      )
  end

  defp for_name(%MediaType{kind: :array, nulls_stripped?: false}), do: "application/json"
  defp for_name(%MediaType{raw: raw}), do: raw

  defp kind(base) when is_map_key(@plan_formats, base), do: :plan
  defp kind(base), do: Map.get(@kinds, base, :other)

  defp plan(base, params) when is_map_key(@plan_formats, base) do
    %{
      format: Map.fetch!(@plan_formats, base),
      for: plan_for(params),
      options: plan_options(params)
    }
  end

  defp plan(_base, _params), do: nil

  # The type a plan is for: `application/json` by default.
  defp plan_for(params) do
    case find_param(params, "for") do
      nil -> MediaType.json()
      value -> value |> unquote_value() |> parse() |> List.first(MediaType.json())
    end
  end

  # Names are matched exactly (`Analyze` is no option, as upstream) and always listed in
  # PostgREST's order, whatever the client's.
  defp plan_options(params) do
    names =
      params
      |> find_param("options")
      |> to_string()
      |> unquote_value()
      |> String.split("|")

    for {name, option} <- @plan_options, name in names, do: option
  end

  defp find_param(params, name) do
    Enum.find_value(params, fn param -> if param_name(param) == name, do: param_value(param) end)
  end

  defp stripped?(param),
    do: param_name(param) == "nulls" and param |> param_value() |> unquote_value() == "stripped"

  defp param_name(param),
    do: param |> String.split("=", parts: 2) |> hd() |> String.trim() |> String.downcase()

  defp param_value(param) do
    case String.split(param, "=", parts: 2) do
      [_name, value] -> String.trim(value)
      [_name] -> ""
    end
  end

  defp unquote_value(value), do: value |> String.trim() |> String.trim("\"")

  # Splits on `separator` except inside double quotes (a backslash escapes the next byte).
  defp split_outside_quotes(text, separator), do: split(text, separator, false, [], [])

  defp split(<<>>, _sep, _quoted?, current, parts), do: Enum.reverse([done(current) | parts])

  defp split(<<?\\, byte, rest::binary>>, sep, true, current, parts),
    do: split(rest, sep, true, [byte, ?\\ | current], parts)

  defp split(<<?", rest::binary>>, sep, quoted?, current, parts),
    do: split(rest, sep, not quoted?, [?" | current], parts)

  defp split(<<sep, rest::binary>>, sep, false, current, parts),
    do: split(rest, sep, false, [], [done(current) | parts])

  defp split(<<byte, rest::binary>>, sep, quoted?, current, parts),
    do: split(rest, sep, quoted?, [byte | current], parts)

  defp done(current), do: current |> Enum.reverse() |> :binary.list_to_bin()
end
