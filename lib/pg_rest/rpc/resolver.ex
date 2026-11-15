defmodule PgRest.RPC.Resolver do
  @moduledoc """
  Finds the function a `/rpc/<name>` request calls, a port of PostgREST's `Plan.hs` `findProc`
  over the registry snapshot's functions.

  A function matches the request's argument names when, writing `R` for its required
  parameter names and `O` for its optional ones, `keys - O == R`. That covers no parameters
  (`keys == []`), only required (`keys == R`), only optional (`keys` is a subset of `O`) and
  both.

  A POST can also reach a function with one unnamed parameter, which takes the whole body. The
  invocation says which body media type the request carries and so which parameter type that
  is: `:post` (`{:post, :json}`, `application/json`) takes `json` or `jsonb`, `{:post, :text}`
  (`text/plain`) `text`, `{:post, :xml}` (`text/xml`) `xml` and `{:post, :bytea}`
  (`application/octet-stream`) `bytea`. A non-JSON body matches only that unnamed parameter,
  never a function found by argument names.

  Resolution excludes unnamed parameters other than that single-parameter shape.

  ## Differences from PostgREST

  Multi-parameter signatures with an unnamed argument are reported as uncached
  (PGRST202). PostgREST v14.18 may attempt them: a POST with an empty argument name
  reaches SQL and fails with 42601; its GET fails parsing that empty name.
  """

  alias PgRest.{Error, Function}
  alias PgRest.Registry.Snapshot
  alias PgRest.SchemaGraph.Fuzzy

  @type invocation :: :read | :post | {:post, :json | :text | :xml | :bytea}

  # The unnamed-parameter types each body media type can reach.
  @unnamed %{json: ~w(json jsonb), text: ~w(text), xml: ~w(xml), bytea: ~w(bytea)}
  @unnamed_types @unnamed |> Map.values() |> List.flatten()
  # PostgREST suggests a function name at 0.75 and a parameter list at 0.33.
  @name_score 0.75
  @params_score 0.33
  # Hints are skipped for request-sized input: the fuzzy match and edit distance are not free.
  @max_hint_bytes 1024
  @max_extra_keys 2

  @doc """
  Resolves `schema.name` for the request's argument `keys`.
  """
  @spec resolve(Snapshot.t(), String.t(), String.t(), [String.t()], invocation()) ::
          {:ok, Function.t()} | {:error, Error.t()}
  def resolve(snap, schema, name, keys, :post),
    do: resolve(snap, schema, name, keys, {:post, :json})

  def resolve(snap, schema, name, keys, invocation) do
    # Sorted before deduplicating: `Enum.uniq/1` on request-sized input is the dominant cost.
    keys = keys |> Enum.sort() |> Enum.dedup()
    overloads = snap |> Snapshot.functions(schema, name) |> Enum.filter(&cached?/1)
    request = {schema, name, keys, invocation}

    case invocation do
      {:post, media} when media != :json -> unnamed(snap, request, overloads, media)
      _json_or_read -> by_names(snap, request, overloads)
    end
  end

  defp by_names(snap, {_schema, _name, keys, _invocation} = request, overloads) do
    key_set = MapSet.new(keys)

    case Enum.filter(overloads, &matches?(&1, key_set)) do
      [function] -> {:ok, function}
      [_, _ | _] = matches -> {:error, ambiguous(matches)}
      [] -> fallback(snap, request, overloads)
    end
  end

  defp fallback(snap, {_schema, _name, _keys, {:post, :json}} = request, overloads) do
    case Enum.filter(overloads, &unnamed?(&1, :json)) do
      [function] -> {:ok, function}
      [_, _ | _] = candidates -> {:error, ambiguous(candidates)}
      [] -> {:error, not_found(snap, request, overloads)}
    end
  end

  defp fallback(snap, request, overloads), do: {:error, not_found(snap, request, overloads)}

  defp unnamed(_snap, {schema, name, _keys, _invocation}, overloads, media) do
    case Enum.filter(overloads, &unnamed?(&1, media)) do
      [function] -> {:ok, function}
      [_, _ | _] = candidates -> {:error, ambiguous(candidates)}
      [] -> {:error, Error.function_not_found_unnamed(schema, name, hd(@unnamed[media]))}
    end
  end

  # The request keys, minus the optional parameters, are exactly the required ones.
  defp matches?(%Function{params: params}, keys) do
    {required, optional} = Enum.split_with(params, & &1.required?)
    MapSet.equal?(MapSet.difference(keys, names(optional)), names(required))
  end

  defp names(params), do: MapSet.new(params, & &1.name)

  defp unnamed?(%Function{params: [%{name: "", type: type}]}, media),
    do: type in Map.fetch!(@unnamed, media)

  defp unnamed?(_function, _media), do: false

  # Whether PostgREST's schema cache holds the function at all.
  defp cached?(%Function{params: [%{name: "", type: type}]}), do: type in @unnamed_types
  defp cached?(%Function{params: params}), do: Enum.all?(params, &(&1.name != ""))

  # PostgREST lists the candidates by parameter count, then parameter types.
  defp ambiguous(functions) do
    functions
    |> Enum.sort_by(&{length(&1.params), Enum.map(&1.params, fn param -> param.type end)})
    |> Enum.map(&describe/1)
    |> Error.ambiguous_function()
  end

  defp describe(%Function{params: params} = function) do
    args = Enum.map_join(params, ", ", &"#{&1.name} => #{&1.type}")
    "#{Function.label(function)}(#{args})"
  end

  defp not_found(snap, {schema, name, keys, invocation}, overloads) do
    hint =
      case overloads do
        [] -> name_hint(snap, schema, name)
        _some -> params_hint(schema, name, keys, overloads)
      end

    Error.function_not_found(schema, name, keys, invocation != :read, hint)
  end

  defp name_hint(_snap, _schema, name) when byte_size(name) > @max_hint_bytes, do: nil

  defp name_hint(snap, schema, name) do
    names =
      snap |> Snapshot.schema_functions(schema) |> Enum.filter(&cached?/1) |> Enum.map(& &1.name)

    Fuzzy.hint(
      names,
      name,
      @name_score,
      &"Perhaps you meant to call the function #{schema}.#{&1}"
    )
  end

  # PostgREST compares `(a, b)` texts: sorted names in parentheses, for the request and for
  # each overload. A request with far more keys than any overload has parameters cannot be
  # close: that cap is checked before any text is built (500k keys would be sorted and joined
  # again for nothing), so such a request is not scored at all.
  defp params_hint(schema, name, keys, overloads) do
    widest = overloads |> Enum.map(&length(&1.params)) |> Enum.max()

    with true <- length(keys) <= widest + @max_extra_keys,
         term = list_text(keys),
         true <- byte_size(term) <= @max_hint_bytes do
      lists =
        for %Function{params: params} <- overloads, do: list_text(Enum.map(params, & &1.name))

      Fuzzy.hint(
        lists,
        term,
        @params_score,
        &"Perhaps you meant to call the function #{schema}.#{name}#{&1}"
      )
    else
      false -> nil
    end
  end

  defp list_text(names), do: "(" <> (names |> Enum.sort() |> Enum.join(", ")) <> ")"
end
