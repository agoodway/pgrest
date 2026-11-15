defmodule PgRest.SQL.Explain do
  @moduledoc """
  Wraps a compiled statement in `EXPLAIN`, PostgREST's `explainF`: the plan of the statement a
  request would run, for the `application/vnd.pgrst.plan` media type.

      EXPLAIN (FORMAT TEXT | JSON[, ANALYZE][, VERBOSE][, SETTINGS][, BUFFERS][, WAL]) <statement>

  The statement and its bind parameters are untouched (`$n` numbering is unchanged), so the plan
  shows the values it would run with. Options are a closed set of atoms (`PgRest.MediaType`),
  never request text.

  ## Differences from PostgREST

  The explained statement is PgRest's own, so the plan's nodes differ from PostgREST's in
  places: a write adds an aggregate over the rows it wrote (and reads its `pgrst_payload`
  CTE), a function call reads a `pgrst_rpc` CTE where PostgREST reads `pgrst_source`.
  """

  alias PgRest.MediaType

  @typedoc "The `format` and `options` of a `PgRest.MediaType` plan."
  @type spec :: %{
          required(:format) => :text | :json,
          required(:options) => [MediaType.plan_option()],
          optional(atom()) => term()
        }

  @doc """
  `{sql, params}` explained. The options follow the order of `spec.options`, which
  `PgRest.Request.Accept` fixes to PostgREST's (`analyze`, `verbose`, `settings`, `buffers`,
  `wal`).
  """
  @spec wrap({String.t(), [term()]}, spec()) :: {String.t(), [term()]}
  def wrap({sql, params}, %{format: format, options: options}) do
    names = Enum.map_join([format_name(format) | Enum.map(options, &option_name/1)], ", ", & &1)

    {"EXPLAIN (" <> names <> ") " <> sql, params}
  end

  defp format_name(:text), do: "FORMAT TEXT"
  defp format_name(:json), do: "FORMAT JSON"

  defp option_name(:analyze), do: "ANALYZE"
  defp option_name(:verbose), do: "VERBOSE"
  defp option_name(:settings), do: "SETTINGS"
  defp option_name(:buffers), do: "BUFFERS"
  defp option_name(:wal), do: "WAL"
end
