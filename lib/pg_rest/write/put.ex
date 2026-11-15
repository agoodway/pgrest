defmodule PgRest.Write.Put do
  @moduledoc """
  Serves `PUT /<table>?<pk>=eq.<value>`: a single-row upsert on the pipeline in
  `PgRest.Write.Insert`.

  The URL must carry exactly an `eq` filter for every primary key column and nothing else
  (`PGRST105`, 405, also for a table without a primary key); `limit` and `offset` are
  `PGRST114` (`PgRest.Request.Range`). The payload is one object or an array: Postgres reads
  every element (a bad value in any is its error) and the statement writes the one whose key
  equals the URL's, compared as the column compares (`PGRST115` when none, `PGRST102` when
  several do). `plan_put/2` checks the URL and hands `Insert` a `POST` shaped request:
  `resolution=merge-duplicates` on the primary key, and no `columns=`, `missing=` or
  `on_conflict=` (all ignored, as in PostgREST). Everything else is `Insert`'s: the payload
  columns only are updated, over a non-identity scope the conflicting row must be in scope
  (`PgRest.SQL.Write`), and the written row passes the write check, else 42501.

  PUT needs `:create`, `:update` and `:read` on the target, because its filters read.
  `Insert.run/6` answers with `PgRest.Responder.put/6`: 201 when the row was inserted and 200
  when it was updated, with `return=representation`; 204 for any other `return=`; no
  `Content-Range` and no `Location`. `max-affected` does not bound a PUT. The changeset of a
  custom `changeset/3` runs with `operation: :upsert`.

  ## Differences from PostgREST

    * A payload without a primary key column, or `[]`, is `PGRST115`. PostgREST answers `42703`
      (`column pgrst_body.name does not exist`): its key filter names a body column the
      payload lacks, an accident rather than a contract.
    * Several array elements matching the URL are a 400 `PGRST102`, and nothing is written.
      PostgREST fails with a 500 `21000` (`ON CONFLICT DO UPDATE command cannot affect row a
      second time`), a server error for a client mistake; PgRest, like for a `PATCH` array,
      does not pick one.
  """

  alias PgRest.AST.{Condition, Field}
  alias PgRest.{Error, Request, Responder, Write}
  alias PgRest.Planner.Params
  alias PgRest.Write.{Insert, Payload}

  @doc "Runs the `PUT` and sends the response."
  @spec run(Plug.Conn.t(), map(), map(), Request.t(), map()) :: Plug.Conn.t()
  def run(conn, opts, config, %Request{} = request, context) do
    case plan_put(request, config) do
      {:ok, insert, key} -> Insert.run(conn, opts, config, insert, context, key)
      {:error, error} -> Responder.error(conn, error)
    end
  end

  @doc """
  Validates a `PUT` and returns the `Insert` request and the URL key (`[{column, text}]`) the
  statement selects the payload element with (`PgRest.SQL.Write.insert/3`). The payload objects
  must share their keys (`PGRST102`, as for any write); `columns=` does not apply to a `PUT`.
  """
  @spec plan_put(Request.t(), map()) ::
          {:ok, Request.t(), [{String.t(), String.t()}]} | {:error, Error.t()}
  def plan_put(%Request{} = request, config) do
    with {:ok, _keys} <- Payload.uniform_keys(List.wrap(request.body), nil),
         {:ok, key} <- key_filters(request, config) do
      {:ok, insert_request(request), key}
    end
  end

  # `[{column, text}]`: the root `eq` filter of every key column, and no other filter.
  defp key_filters(request, config) do
    columns = Write.source_columns(config, config.primary_key)

    with {:ok, root} <- Params.root_group(request.params, config.custom_params) do
      filters =
        for %Condition{field: %Field{name: name}, value: value} <- root.where, do: {name, value}

      if columns != [] and root.custom == [] and Enum.all?(root.where, &bare_eq?/1) and
           MapSet.new(filters, &elem(&1, 0)) == MapSet.new(columns),
         do: {:ok, filters},
         else: {:error, Error.put_filters_not_key()}
    end
  end

  defp bare_eq?(%Condition{op: :eq, negate: false, modifier: nil, field: %Field{json_path: []}}),
    do: true

  defp bare_eq?(_item), do: false

  # `columns=` and `on_conflict=` do not apply to a `PUT`.
  defp insert_request(%Request{prefer: prefer, params: params} = request) do
    %{
      request
      | params: Enum.reject(params, fn {key, _value} -> key in ["columns", "on_conflict"] end),
        prefer: %{prefer | resolution: :merge_duplicates, missing: nil}
    }
  end
end
