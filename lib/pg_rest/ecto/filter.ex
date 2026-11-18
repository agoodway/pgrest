defmodule PgRest.Ecto.Filter do
  @moduledoc """
  Compiles PostgREST filter AST nodes (`PgRest.AST.Condition`, `PgRest.AST.Logic`) into
  `Ecto.Query.dynamic/2` expressions, for applications that parse PostgREST filters with
  `PgRest.Grammar.Filter` and run the query through their own Ecto code instead of
  `PgRest.Plug`.

      {:ok, status} = PgRest.Grammar.Filter.parse_condition("status", "in.(active,draft)")
      {:ok, cheap} = PgRest.Grammar.Filter.parse_logic("or", "(price.lt.10,qty.gte.100)")

      {:ok, query} = PgRest.Ecto.Filter.where(Product, [status, cheap])
      Repo.all(query)

  Every value is a bind parameter; no request text is spliced into SQL. Conditions bind
  to the query's first binding.

  ## Field names and casting

  Field names resolve against an allowlist, never by creating atoms:

    * `:schema` - an Ecto schema module. Its fields are filterable and each value is cast
      with `Ecto.Type.cast/2` against the field's type, so `qty=eq.abc` is a `22P02`
      before the query runs. `where/3` defaults it to the query's schema; pass
      `schema: nil` to skip casting.
    * `:fields` - a list of field atoms that may be filtered. With `:schema` it narrows
      the schema's fields; without one it is required and values bind uncast, as the
      strings the grammar produced. Postgrex encodes parameters in binary, so an uncast
      string only matches a text-like column (`text`, `varchar`, `citext`, enums); filter
      other columns through a `:schema`.

  A name outside the allowlist is a `42703`. Passing neither option raises
  `ArgumentError`.

  Supported operators: `eq neq gt gte lt lte isdistinct in like ilike match imatch is cs
  cd ov fts plfts phfts wfts`, with `not.` and `and`/`or` trees. JSON paths, `any`/`all`
  modifiers and range operators are refused with a `PGRST100`. The
  [Filtering Ecto queries](ecto-filter.md) guide has the operator table.
  """

  import Ecto.Query, only: [dynamic: 2]

  alias Ecto.{Query, Queryable, Type, UUID}
  alias PgRest.AST.{Condition, Field, Logic}
  alias PgRest.Error
  alias PgRest.Grammar.Filter, as: Grammar

  require Query

  @type ast :: Condition.t() | Logic.t()
  @type option :: {:schema, module() | nil} | {:fields, [atom()]}

  @scalar_ops [:eq, :neq, :gt, :gte, :lt, :lte, :isdistinct]
  @text_ops [:like, :ilike, :match, :imatch, :fts, :plfts, :phfts, :wfts]
  @array_ops [:cs, :cd, :ov]
  @range_ops [:sl, :sr, :nxr, :nxl, :adj]
  @known_ops @scalar_ops ++ @text_ops ++ @array_ops ++ [:in, :is]
  @is_values [:null, :not_null, true, false, :unknown]
  @fts_funs %{
    fts: "to_tsquery",
    plfts: "plainto_tsquery",
    phfts: "phraseto_tsquery",
    wfts: "websearch_to_tsquery"
  }

  @doc """
  Compiles one filter node to a dynamic expression over the query's first binding.

  Returns `{:error, %PgRest.Error{}}` for an unknown field (`42703`), a value the field
  type rejects (`22P02`), or an unsupported filter or a value of the wrong shape for its
  operator, such as an `is` value other than `null`, `not_null`, `true`, `false` or
  `unknown` (`PGRST100`). It never raises on a malformed node.
  """
  @spec to_dynamic(ast(), [option()]) :: {:ok, Query.dynamic_expr()} | {:error, Error.t()}
  def to_dynamic(node, opts) do
    compile(node, resolver(opts))
  end

  @doc """
  Adds one `where` per node to `queryable`. `:schema` defaults to the query's schema.

  Returns the first node's error, if any.
  """
  @spec where(Queryable.t(), [ast()], [option()]) :: {:ok, Query.t()} | {:error, Error.t()}
  def where(queryable, nodes, opts \\ []) do
    query = Queryable.to_query(queryable)

    resolver =
      opts
      |> Keyword.put_new_lazy(:schema, fn -> query_schema(query) end)
      |> resolver()

    with {:ok, dynamics} <- collect(nodes, &compile(&1, resolver)) do
      {:ok, Enum.reduce(dynamics, query, fn dynamic, acc -> Query.where(acc, ^dynamic) end)}
    end
  end

  defp query_schema(%Query{from: %{source: {_source, schema}}}), do: schema
  defp query_schema(_query), do: nil

  # --- field resolution ----------------------------------------------------------

  defp resolver(opts) do
    schema = Keyword.get(opts, :schema)
    %{schema: schema, fields: field_map(schema, Keyword.get(opts, :fields))}
  end

  defp field_map(nil, nil),
    do: raise(ArgumentError, "PgRest.Ecto.Filter needs a :schema or :fields option")

  defp field_map(nil, fields), do: Map.new(fields, &{Atom.to_string(&1), &1})
  defp field_map(schema, nil), do: field_map(nil, schema.__schema__(:fields))

  defp field_map(schema, fields) do
    schema_fields = schema.__schema__(:fields)
    field_map(nil, Enum.filter(fields, &(&1 in schema_fields)))
  end

  defp resolve(%Field{name: name}, %{fields: fields, schema: schema})
       when is_map_key(fields, name) do
    field = Map.fetch!(fields, name)
    {:ok, field, field_type(schema, field)}
  end

  defp resolve(%Field{name: name}, %{schema: nil}), do: {:error, Error.undefined_column(name)}

  defp resolve(%Field{name: name}, %{schema: schema}),
    do: {:error, Error.unknown_column(schema.__schema__(:source), name)}

  defp field_type(nil, _field), do: nil
  defp field_type(schema, field), do: schema.__schema__(:type, field)

  # --- compilation ---------------------------------------------------------------

  defp compile(%Logic{op: op}, _resolver) when op not in [:and, :or],
    do: unsupported("the #{inspect(op)} logic operator")

  defp compile(%Logic{op: op, children: []}, _resolver), do: unsupported("an empty #{op}")

  defp compile(%Logic{op: op, negate: negate, children: children}, resolver) do
    with {:ok, dynamics} <- collect(children, &compile(&1, resolver)) do
      {:ok, dynamics |> combine(op) |> negated(negate)}
    end
  end

  defp compile(%Condition{} = condition, resolver) do
    with :ok <- supported(condition),
         {:ok, field, type} <- resolve(condition.field, resolver),
         {:ok, value} <- cast(condition, field, type) do
      {:ok, condition |> operator(field, value) |> negated(condition.negate)}
    end
  end

  defp combine([first | rest], :and),
    do: Enum.reduce(rest, first, fn dynamic, acc -> dynamic([r], ^acc and ^dynamic) end)

  defp combine([first | rest], :or),
    do: Enum.reduce(rest, first, fn dynamic, acc -> dynamic([r], ^acc or ^dynamic) end)

  defp negated(dynamic, false), do: dynamic
  defp negated(dynamic, true), do: dynamic([r], not (^dynamic))

  defp supported(%Condition{field: %Field{json_path: [_ | _]}}), do: unsupported("JSON paths")

  defp supported(%Condition{modifier: modifier}) when modifier in [:any, :all],
    do: unsupported("the #{modifier} modifier")

  defp supported(%Condition{op: op}) when op in @range_ops,
    do: unsupported("the #{op} range operator")

  defp supported(%Condition{op: op}) when op not in @known_ops,
    do: unsupported("the #{inspect(op)} operator")

  defp supported(%Condition{}), do: :ok

  defp unsupported(what),
    do: {:error, Error.parse_error("PgRest.Ecto.Filter does not support #{what}")}

  defp malformed(%Condition{op: op, value: value}),
    do: {:error, Error.parse_error("PgRest.Ecto.Filter cannot apply #{op} to #{inspect(value)}")}

  # --- casting -------------------------------------------------------------------

  defp cast(%Condition{op: :is, value: value}, _field, _type) when value in @is_values,
    do: {:ok, value}

  defp cast(%Condition{op: op, value: value, fts_config: config}, _field, _type)
       when op in @text_ops and is_binary(value) and (is_nil(config) or is_binary(config)),
       do: {:ok, value}

  defp cast(%Condition{op: op} = condition, _field, _type) when op in [:is | @text_ops],
    do: malformed(condition)

  # Array values go into a `fragment/1`, where Ecto does not dump parameters through the
  # field type, so they are dumped here (`Ecto.Enum` atoms to strings, UUIDs to binaries).
  defp cast(%Condition{op: op, value: value}, field, type) when op in @array_ops do
    with {:ok, elements} <- array_value(value, field),
         {:ok, cast} <- cast_value(type, elements, field) do
      dump_value(type, cast, field)
    end
  end

  # As PostgREST, `in.()` and `in.("")` both parse to `[""]` and mean the empty list.
  defp cast(%Condition{op: :in, value: [""]}, _field, _type), do: {:ok, []}

  defp cast(%Condition{op: :in, value: values}, field, type) when is_list(values),
    do: collect(values, &cast_value(type, &1, field))

  defp cast(%Condition{op: :in} = condition, _field, _type), do: malformed(condition)

  # Ecto refuses to compare with `nil`; `is.null` and `isdistinct` are the null tests.
  defp cast(%Condition{op: op, value: nil} = condition, _field, _type)
       when op in @scalar_ops and op != :isdistinct,
       do: malformed(condition)

  # Without a field type nothing checks the value, and a list or a plain map would only fail
  # when Postgrex encodes it.
  defp cast(%Condition{op: op, value: value} = condition, _field, nil)
       when op in @scalar_ops and (is_list(value) or (is_map(value) and not is_struct(value))),
       do: malformed(condition)

  defp cast(%Condition{value: value}, field, type), do: cast_value(type, value, field)

  defp cast_value(nil, value, _field), do: {:ok, value}

  # `:binary_id` casts any string, so a malformed UUID would only fail in Postgres.
  defp cast_value(:binary_id, value, field), do: cast_uuid(value, field)

  defp cast_value({:array, :binary_id}, values, field) when is_list(values),
    do: collect(values, &cast_uuid(&1, field))

  defp cast_value(type, value, field) do
    case Type.cast(type, value) do
      {:ok, cast} -> {:ok, cast}
      _error -> {:error, Error.invalid_input(Atom.to_string(field), value)}
    end
  end

  defp cast_uuid(value, field) do
    case UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, Error.invalid_input(Atom.to_string(field), value)}
    end
  end

  defp dump_value(nil, value, _field), do: {:ok, value}

  defp dump_value(type, value, field) do
    case Type.dump(type, value, &dump_element/2) do
      {:ok, dumped} -> {:ok, dumped}
      :error -> {:error, Error.invalid_input(Atom.to_string(field), value)}
    end
  end

  # Postgrex takes a `uuid` as 16 bytes; `:binary_id` only dumps to them through the adapter.
  defp dump_element(:binary_id, value), do: UUID.dump(value)
  defp dump_element(type, value), do: Type.dump(type, value, &dump_element/2)

  defp array_value(elements, _field) when is_list(elements), do: {:ok, elements}

  defp array_value(literal, field) when not is_binary(literal),
    do: {:error, Error.invalid_input(Atom.to_string(field), literal)}

  defp array_value(literal, field) do
    case Grammar.parse_array_literal(literal) do
      {:ok, elements} -> {:ok, elements}
      :error -> {:error, Error.invalid_input(Atom.to_string(field), literal)}
    end
  end

  # --- operators -----------------------------------------------------------------

  defp operator(%Condition{op: :eq}, field, value), do: dynamic([r], field(r, ^field) == ^value)
  defp operator(%Condition{op: :neq}, field, value), do: dynamic([r], field(r, ^field) != ^value)
  defp operator(%Condition{op: :gt}, field, value), do: dynamic([r], field(r, ^field) > ^value)
  defp operator(%Condition{op: :gte}, field, value), do: dynamic([r], field(r, ^field) >= ^value)
  defp operator(%Condition{op: :lt}, field, value), do: dynamic([r], field(r, ^field) < ^value)
  defp operator(%Condition{op: :lte}, field, value), do: dynamic([r], field(r, ^field) <= ^value)
  defp operator(%Condition{op: :in}, field, values), do: dynamic([r], field(r, ^field) in ^values)

  # `IS DISTINCT FROM` a non-null value, in Ecto operators so the value is dumped through
  # the field type (a `fragment/1` parameter would bind an `Ecto.Enum` atom as is).
  defp operator(%Condition{op: :isdistinct}, field, nil),
    do: dynamic([r], not is_nil(field(r, ^field)))

  defp operator(%Condition{op: :isdistinct}, field, value),
    do: dynamic([r], field(r, ^field) != ^value or is_nil(field(r, ^field)))

  defp operator(%Condition{op: :like}, field, value),
    do: dynamic([r], like(field(r, ^field), ^wildcards(value)))

  defp operator(%Condition{op: :ilike}, field, value),
    do: dynamic([r], ilike(field(r, ^field), ^wildcards(value)))

  defp operator(%Condition{op: :match}, field, value),
    do: dynamic([r], fragment("? ~ ?", field(r, ^field), ^value))

  defp operator(%Condition{op: :imatch}, field, value),
    do: dynamic([r], fragment("? ~* ?", field(r, ^field), ^value))

  defp operator(%Condition{op: :is}, field, :null), do: dynamic([r], is_nil(field(r, ^field)))

  defp operator(%Condition{op: :is}, field, :not_null),
    do: dynamic([r], not is_nil(field(r, ^field)))

  defp operator(%Condition{op: :is}, field, true),
    do: dynamic([r], fragment("? IS TRUE", field(r, ^field)))

  defp operator(%Condition{op: :is}, field, false),
    do: dynamic([r], fragment("? IS FALSE", field(r, ^field)))

  defp operator(%Condition{op: :is}, field, :unknown),
    do: dynamic([r], fragment("? IS UNKNOWN", field(r, ^field)))

  defp operator(%Condition{op: :cs}, field, value),
    do: dynamic([r], fragment("? @> ?", field(r, ^field), ^value))

  defp operator(%Condition{op: :cd}, field, value),
    do: dynamic([r], fragment("? <@ ?", field(r, ^field), ^value))

  defp operator(%Condition{op: :ov}, field, value),
    do: dynamic([r], fragment("? && ?", field(r, ^field), ^value))

  # `fragment/1` takes a literal; the SQL text comes from compile-time constants only.
  for {op, fun} <- @fts_funs do
    defp operator(%Condition{op: unquote(op), fts_config: nil}, field, query),
      do:
        dynamic(
          [r],
          fragment(unquote("to_tsvector(?) @@ #{fun}(?)"), field(r, ^field), ^query)
        )

    defp operator(%Condition{op: unquote(op), fts_config: config}, field, query),
      do:
        dynamic(
          [r],
          fragment(
            unquote("to_tsvector(?::text::regconfig, ?) @@ #{fun}(?::text::regconfig, ?)"),
            ^config,
            field(r, ^field),
            ^config,
            ^query
          )
        )
  end

  defp wildcards(pattern), do: String.replace(pattern, "*", "%")

  # --- helpers -------------------------------------------------------------------

  # Maps `fun` over `items`, stopping at the first `{:error, _}`.
  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, _error} = error -> {:halt, error}
      end
    end)
    |> reverse_ok()
  end

  defp reverse_ok({:ok, results}), do: {:ok, Enum.reverse(results)}
  defp reverse_ok(error), do: error
end
