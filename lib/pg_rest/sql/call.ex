defmodule PgRest.SQL.Call do
  @moduledoc """
  Compiles the function call of an RPC (`PgRest.Plan.Call`) to the `FROM` item the root of its
  read plan reads, following PostgREST's `callPlanToQuery`.

  The item is one parenthesised subquery exposing the result columns: a resource return under
  its Ecto field names (`PgRest.SQL.ScopedSource.projection/3`), any other composite under its
  own column names, and a scalar or void return as `pgrst_scalar`. Inside it the call is aliased
  `pgrst_call`:

    * `{:direct, args}` - `"s"."f"("a" := $n::text::<type>, VARIADIC "v" := $m::text[]::<type>)`:
      each value is one text parameter cast in SQL; a variadic one binds the list natively as
      `text[]`
    * `{:json, body, keys}` - the body bound once, `(SELECT $n::text::json AS json_data)
      pgrst_payload`, expanded with `json_to_recordset` (an object counts as an array of one)
      into `pgrst_body`, of which only the first element is used (`LIMIT 1`: PostgREST calls
      the function once), then `LATERAL "s"."f"("k" := pgrst_body."k", ...)`
    * `{:single, body}` - `"s"."f"($n::text::<json|jsonb|text|xml>)` (`bytea` binds the bytes)

  A scalar call is wrapped as `(SELECT "s"."f"(...) pgrst_scalar) pgrst_call`.

  With a `scope` (`{resource, scoped_query}`, see `PgRest.Plan.Call`) only the rows a stored,
  in-scope row matches survive: the same key and the same value in every mapped column,
  probed with `PgRest.SQL.ScopedSource.exists_probe/4`. Fabricated rows and stored rows whose
  attributes the function changed are both dropped. A scoped call reads the function
  `WITH ORDINALITY` and its source adds that number as `pgrst_ordinality`, which no select
  item reads; without a requested order the read sorts by it (`row_order/2`), so the probe
  cannot reorder the function's rows.

  Function, parameter and column names come from the registry and are quoted with
  `PgRest.SQL.Builder.ident/1`; parameter and column types are catalog (or declared) text.
  """

  alias PgRest.{Function, Plan}
  alias PgRest.SQL.{Builder, ScopedSource}

  @ordinality "pgrst_ordinality"

  @doc """
  The `FROM` item of the call, `{sql, builder}`. `scope` is `nil` or `{resource, scoped_query}`.
  """
  @spec source(Plan.Call.t(), nil | {module(), Ecto.Query.t()}, Builder.t()) ::
          {iodata(), Builder.t()}
  def source(%Plan.Call{function: function, args: args}, scope, builder) do
    {from, builder} = from(function, args, call_alias(scope), builder)
    {from, builder} = scoped(from, scope, builder)
    {["(SELECT ", columns(function.returns), ordinality(scope), " FROM ", from, ")"], builder}
  end

  @doc """
  The `ORDER BY` that keeps a scoped call's rows in the function's own output order, read
  under `alias_name`; `[]` for an unscoped call, which keeps PostgREST's statement shape.
  """
  @spec row_order(Plan.Call.t(), String.t()) :: iodata()
  def row_order(%Plan.Call{scope: nil}, _alias_name), do: []

  def row_order(%Plan.Call{}, alias_name),
    do: [" ORDER BY ", Builder.ident(alias_name), ".", Builder.ident(@ordinality)]

  # --- the call ------------------------------------------------------------------------

  defp from(function, {:direct, args}, call_alias, builder) do
    {arguments, builder} =
      function.params
      |> Enum.filter(&Map.has_key?(args, &1.name))
      |> Enum.map_reduce(builder, fn param, b ->
        direct_arg(param, Map.fetch!(args, param.name), b)
      end)

    {call_item(function, Enum.intersperse(arguments, ", "), call_alias), builder}
  end

  defp from(function, {:json, _body, []}, call_alias, builder),
    do: {call_item(function, [], call_alias), builder}

  defp from(function, {:json, body, keys}, call_alias, builder) do
    params = Enum.filter(function.params, &(&1.name in keys))
    {payload, builder} = Builder.param(builder, body, "json", :text)

    definitions =
      Enum.map_intersperse(params, ", ", &[Builder.ident(&1.name), " ", &1.type])

    arguments =
      Enum.map_intersperse(params, ", ", fn param ->
        [variadic(param), Builder.ident(param.name), " := pgrst_body.", Builder.ident(param.name)]
      end)

    sql = [
      "(SELECT ",
      payload,
      " AS json_data) pgrst_payload, LATERAL (SELECT * FROM json_to_recordset(CASE WHEN ",
      "json_typeof(pgrst_payload.json_data) = 'array' THEN pgrst_payload.json_data ",
      "ELSE json_build_array(pgrst_payload.json_data) END) AS _(",
      definitions,
      ") LIMIT 1) pgrst_body, LATERAL ",
      call_item(function, arguments, call_alias)
    ]

    {sql, builder}
  end

  defp from(%Function{params: [%{type: "bytea"}]} = function, {:single, body}, call_alias, b) do
    {arg, b} = Builder.param(b, body, "bytea", :native)
    {call_item(function, arg, call_alias), b}
  end

  defp from(%Function{params: [%{type: type}]} = function, {:single, body}, call_alias, b) do
    {arg, b} = Builder.param(b, body, type, :text)
    {call_item(function, arg, call_alias), b}
  end

  defp direct_arg(%{variadic?: true} = param, values, builder) do
    {placeholder, builder} = Builder.param(builder, List.wrap(values), nil, :native)

    {["VARIADIC ", Builder.ident(param.name), " := ", placeholder, "::text[]::", param.type],
     builder}
  end

  defp direct_arg(param, value, builder) do
    {placeholder, builder} = Builder.param(builder, value, param.type, :text)
    {[Builder.ident(param.name), " := ", placeholder], builder}
  end

  defp variadic(%{variadic?: true}), do: "VARIADIC "
  defp variadic(_param), do: []

  defp call_item(%Function{returns: %{kind: kind}} = function, arguments, _call_alias)
       when kind in [:scalar, :void],
       do: ["(SELECT ", invocation(function, arguments), " pgrst_scalar) pgrst_call"]

  defp call_item(function, arguments, call_alias),
    do: [invocation(function, arguments), call_alias]

  # A scoped call is numbered in the function's output order, which `row_order/2` restores
  # after the scope probe. Postgres names the number `ordinality`; the source exposes it as
  # `pgrst_ordinality`, which no select item reads.
  defp call_alias(nil), do: " pgrst_call"
  defp call_alias(_scope), do: " WITH ORDINALITY pgrst_call"

  defp ordinality(nil), do: []
  defp ordinality(_scope), do: [", pgrst_call.ordinality AS ", @ordinality]

  defp invocation(function, arguments),
    do: [Builder.qualified(function.schema, function.name), "(", arguments, ")"]

  # --- result scope ----------------------------------------------------------------------

  defp scoped(from, nil, builder), do: {from, builder}

  defp scoped(from, {resource, query}, builder) do
    config = resource.__pgrest_config__()
    {scope, builder} = ScopedSource.compile(query, resource, builder)
    key = ScopedSource.key_fields(config)
    fields = resource.__schema__(:query_fields)

    probe =
      ScopedSource.exists_probe(
        scope,
        Enum.map(key, &Atom.to_string/1),
        Enum.map(key, &call_column(config, &1)),
        [
          " AND (",
          Enum.map_intersperse(fields, ", ", &["s.", Builder.ident(Atom.to_string(&1))]),
          ") IS NOT DISTINCT FROM (",
          Enum.map_intersperse(fields, ", ", &call_column(config, &1)),
          ") OFFSET 0"
        ]
      )

    {["(SELECT pgrst_call.* FROM ", from, " WHERE ", probe, ") pgrst_call"], builder}
  end

  # The function returns the table's row type, so its columns carry the database names.
  defp call_column(config, field),
    do: ["pgrst_call.", Builder.ident(Map.fetch!(config.field_sources, field))]

  # --- result columns ----------------------------------------------------------------------

  defp columns(%{kind: kind}) when kind in [:scalar, :void], do: "pgrst_call.pgrst_scalar"

  defp columns(%{resource: resource}) when not is_nil(resource),
    do:
      ScopedSource.projection(
        resource.__pgrest_config__(),
        resource.__schema__(:query_fields),
        "pgrst_call"
      )

  defp columns(_returns), do: "pgrst_call.*"
end
