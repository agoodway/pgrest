defmodule PgRest.SQL.Format do
  @moduledoc """
  The SQL expression of a response `body` column, by media type: PostgREST's `asJsonF`,
  `asJsonSingleF`, `addNullsToSnip` and `asCsvF`.

  The expression aggregates the `_postgrest_t` rows of the statement's final select, and
  `shape` says how:

    * `:rows` - a JSON array of the rows
    * `:single_composite` - the first row as one object, or `null` (the object media type, or a
      function returning one row)
    * `:scalar_set` - a JSON array of the `pgrst_scalar` column
    * `:scalar` - the first `pgrst_scalar` value, or `null`

  With `nulls_stripped?` the JSON aggregate is wrapped in `json_strip_nulls(...)`. CSV is the
  same for every shape: a header, a newline, then each row's text form without its enclosing
  parentheses, one per line. The rows' text is Postgres' record output (its own quoting), which
  is what PostgREST sends. The header is unquoted column names, from `header`:

    * `:first_row` (default) - the keys of the first row of `pgrst_source`, as PostgREST's
      `asCsvF`: empty when there is no row
    * `{:expr, sql}` - a SQL text expression for the names, whatever the rows (a call's or a
      write's body columns). The caller binds the names; they are request text (aliases) and
      never spliced

  ## Differences from PostgREST

  A call's or write's CSV header lists exactly the columns the body carries, empty results
  included. PostgREST v14.18 also adds unselected filter and key columns to the header:
  `GET /rpc/getallprojects?select=name&id=eq.1` answers header `id,name` over a one-column body.
  It also sorts the names and names the column behind an alias. We treat that as a bug and do
  not copy it.
  """

  alias PgRest.MediaType

  @type shape :: :rows | :single_composite | :scalar | :scalar_set

  @doc "The `body` expression (text) for `media` and `shape`."
  @spec body(MediaType.t(), shape(), :first_row | {:expr, iodata()}) :: iodata()
  def body(media, shape, header \\ :first_row)
  def body(%MediaType{kind: :csv}, _shape, header), do: csv(header)
  def body(%MediaType{nulls_stripped?: stripped?}, shape, _header), do: json(shape, stripped?)

  defp json(:rows, stripped?),
    do: ["coalesce(", strip(stripped?, "json_agg(_postgrest_t.*)"), ", '[]')::text"]

  defp json(:single_composite, stripped?),
    do: ["coalesce((", strip(stripped?, "json_agg(_postgrest_t.*)"), "->0)::text, 'null')"]

  defp json(:scalar_set, stripped?),
    do: ["coalesce(", strip(stripped?, "json_agg(_postgrest_t.pgrst_scalar)"), ", '[]')::text"]

  defp json(:scalar, stripped?),
    do: [
      "coalesce((",
      strip(stripped?, "json_agg(_postgrest_t.pgrst_scalar)"),
      "->0)::text, 'null')"
    ]

  defp strip(true, aggregate), do: ["json_strip_nulls(", aggregate, ")"]
  defp strip(false, aggregate), do: aggregate

  defp csv(header) do
    [
      header(header),
      " || E'\\n' || ",
      "coalesce(string_agg(substring(_postgrest_t::text, 2, length(_postgrest_t::text) - 2), ",
      "E'\\n'), '')"
    ]
  end

  defp header(:first_row) do
    [
      "coalesce((SELECT string_agg(a.k, ',') FROM (SELECT json_object_keys(r)::text AS k FROM ",
      "(SELECT row_to_json(hh) AS r FROM pgrst_source AS hh LIMIT 1) s) a), '')"
    ]
  end

  defp header({:expr, sql}), do: sql
end
