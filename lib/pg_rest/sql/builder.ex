defmodule PgRest.SQL.Builder do
  @moduledoc """
  Accumulates bind parameters and emits SQL fragments as iodata.

  Request text reaches SQL only as a bind parameter (`param/4`) or through `ident/1`
  and `cast/2`, which validate what they emit.
  """

  alias PgRest.AST.Field
  alias PgRest.Grammar.Common

  defstruct repo: nil, params: [], count: 0

  @typedoc "How a parameter value is bound."
  @type mode :: :text | :native

  @type t :: %__MODULE__{
          repo: module() | nil,
          params: [term()],
          count: non_neg_integer()
        }

  @doc "Binds an integer using the shared text-to-bigint SQL representation."
  @spec bigint(t(), integer()) :: {iodata(), t()}
  def bigint(builder, value), do: param(builder, Integer.to_string(value), "bigint", :text)

  @doc "A bound LIMIT clause, or no clause when the limit is nil."
  @spec limit(t(), non_neg_integer() | nil) :: {iodata(), t()}
  def limit(builder, nil), do: {[], builder}

  def limit(builder, value) do
    {param, builder} = bigint(builder, value)
    {[" LIMIT ", param], builder}
  end

  @doc """
  Starts an empty builder.

  ## Options

    * `:repo` - the Ecto repo used to compile scoped Ecto queries to SQL
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []), do: %__MODULE__{repo: Keyword.get(opts, :repo)}

  @doc "Number of parameters bound so far."
  @spec param_count(t()) :: non_neg_integer()
  def param_count(%__MODULE__{count: count}), do: count

  @doc """
  Binds `value` and returns its placeholder.

  In `:text` mode (request-derived values) the value is bound as text and cast in SQL:
  `$n::text` or `$n::text::<type>`; a list binds as `$n::text[]::<type>[]`. In `:native`
  mode (values produced by `Ecto.Type.dump/2`) it emits `$n`, or `$n::<type>` when a type
  is given. `type` is always trusted text (a catalog type or a fixed PgRest type), never
  request text.
  """
  @spec param(t(), term(), String.t() | nil, mode()) :: {iodata(), t()}
  def param(%__MODULE__{} = builder, value, type, mode) when mode in [:text, :native] do
    n = builder.count + 1
    placeholder = ["$", Integer.to_string(n) | cast_suffix(value, type, mode)]
    {placeholder, %{builder | params: [value | builder.params], count: n}}
  end

  defp cast_suffix(value, nil, :text) when is_list(value), do: ["::text[]"]
  defp cast_suffix(value, type, :text) when is_list(value), do: ["::text[]::", type, "[]"]
  defp cast_suffix(_value, nil, :text), do: ["::text"]
  defp cast_suffix(_value, type, :text), do: ["::text::", type]
  defp cast_suffix(_value, nil, :native), do: []
  defp cast_suffix(_value, type, :native), do: ["::", type]

  @doc """
  Appends already-dumped values whose placeholders are written elsewhere (spliced SQL),
  keeping the numbering of later `param/4` calls consistent.
  """
  @spec append_params(t(), [term()]) :: t()
  def append_params(%__MODULE__{} = builder, values) do
    %{
      builder
      | params: Enum.reverse(values, builder.params),
        count: builder.count + length(values)
    }
  end

  @doc """
  Appends JSON path steps (`{:arrow | :double_arrow, key}`) to `column`. Every key is a bind
  parameter, never spliced into the SQL text.

  Array indexes are unbounded integer text: bound as text and cast, never natively.
  PostgREST sends a non-negative index with a leading `+`, which shows in the 22003 message
  of an out-of-range index, so this does too. String keys bind as a bare `$n` so Postgres
  infers their type exactly as it does for PostgREST's untyped literals (`jsonb ->> unknown`
  is a key lookup, `text ->> unknown` is 42883).
  """
  @spec json_path(iodata(), [PgRest.AST.Field.json_step()], t()) :: {iodata(), t()}
  def json_path(column, steps, %__MODULE__{} = builder) do
    Enum.reduce(steps, {column, builder}, fn {arrow, key}, {expr, b} ->
      {key_sql, b} = json_key(key, b)
      {[expr, arrow_sql(arrow), key_sql], b}
    end)
  end

  defp arrow_sql(:arrow), do: " -> "
  defp arrow_sql(:double_arrow), do: " ->> "

  defp json_key(index, b) when is_integer(index) and index >= 0,
    do: param(b, "+" <> Integer.to_string(index), "int", :text)

  defp json_key(index, b) when is_integer(index),
    do: param(b, Integer.to_string(index), "int", :text)

  defp json_key(key, b) when is_binary(key), do: param(b, key, nil, :native)

  @doc "Double-quotes an identifier. Raises `ArgumentError` on a NUL byte."
  @spec ident(String.t()) :: iodata()
  def ident(name) when is_binary(name) do
    if String.contains?(name, <<0>>) do
      raise ArgumentError, "identifier contains a NUL byte: #{inspect(name)}"
    end

    [?", String.replace(name, "\"", "\"\""), ?"]
  end

  @doc "Quoted identifiers joined with `, `."
  @spec ident_list([String.t()]) :: iodata()
  def ident_list(names), do: Enum.map_intersperse(names, ", ", &ident/1)

  @doc "A schema-qualified, quoted relation name."
  @spec qualified(String.t(), String.t()) :: iodata()
  def qualified(schema, table), do: [ident(schema), ?., ident(table)]

  @doc """
  `CAST(<expr> AS <type>)`. The type name is re-validated with
  `PgRest.Grammar.Common.cast_name?/1`; invalid input raises `ArgumentError` (the grammar
  has already turned it into a 400, so a raise means a bug). This is the only way a
  request-supplied type name reaches SQL.
  """
  @spec cast(iodata(), String.t()) :: iodata()
  def cast(expr, type) do
    if Common.cast_name?(type) do
      ["CAST(", expr, " AS ", type, ")"]
    else
      raise ArgumentError, "invalid cast type name: #{inspect(type)}"
    end
  end

  @doc "`cast/2`, or `expr` unchanged when `type` is `nil`."
  @spec maybe_cast(iodata(), String.t() | nil) :: iodata()
  def maybe_cast(expr, nil), do: expr
  def maybe_cast(expr, type), do: cast(expr, type)

  @doc """
  A column of `table_alias` with its JSON path (`json_path/3`). As PostgREST, a path on a column
  whose type (`column_types`, keyed by field name) is not json or jsonb reads it through
  `to_jsonb`.
  """
  @spec column(String.t(), Field.t(), %{String.t() => String.t()}, t()) :: {iodata(), t()}
  def column(table_alias, %Field{name: name, json_path: json_path}, column_types, builder) do
    column = [ident(table_alias), ".", ident(name)]

    column =
      if json_path != [] and Map.get(column_types, name) not in ["json", "jsonb"],
        do: ["to_jsonb(", column, ")"],
        else: column

    json_path(column, json_path, builder)
  end

  @doc "Finalises the statement: the SQL text and the parameters in placeholder order."
  @spec to_sql(t(), iodata()) :: {String.t(), [term()]}
  def to_sql(%__MODULE__{} = builder, iodata) do
    {IO.iodata_to_binary(iodata), Enum.reverse(builder.params)}
  end
end
