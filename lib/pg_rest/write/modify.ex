defmodule PgRest.Write.Modify do
  @moduledoc """
  Serves `PATCH /<table>?<filters>` and `DELETE /<table>?<filters>`, on the pipeline in
  `PgRest.Write`.

  The filters (and logic trees) of the query string select the rows. They are planned like a
  read's, so a typo (`?idd=eq.1`) is a 42703 and a column outside `readable:` a 42501, before
  any SQL, and compiled onto the mutation target by `PgRest.SQL.Write.update/5` and
  `delete/4`: on the table itself for the identity scope (PostgREST's shape, which also serves
  tables without a primary key), through the scope and `FOR UPDATE` otherwise.

  * **Authorization.** The operation (`:update` or `:delete`), plus `:read` when the request
    has any filter, a count or `return=representation`: filters and counts are a read channel.
  * **`require_filters_for_mutations`** (default `true`): a request with no filter is a 400
    `21000` (`UPDATE requires a WHERE clause`, `DELETE requires a WHERE clause`), as with
    Supabase's `pg-safeupdate`. A `PATCH` that sets no column is exempt: it touches no row.
  * **`PATCH` payload.** One object (`PgRest.Write.Payload.build_update/5`). Without a custom
    changeset the supplied keys (or `columns=`) are set as sent. With one, the columns set are
    the changeset's final changes (it runs once; see `PgRest.Write.Payload`): an absent or
    uncast key is untouched, and a value equal to the struct default is set only when the
    changeset casts with `force_changes: true`. A payload column outside the resource's
    writable set is a 42501.
  * **Write check.** An updated row must still be visible through the scope, else 42501 and a
    rollback, in the form `PgRest.Write` uses for inserts. A `DELETE` has no check.
  * **Response.** 204 with `Content-Range` (`PgRest.Responder.mutation/6`), or 200 with the
    rows for `return=representation`. `Accept: application/vnd.pgrst.object+json` requires
    exactly one row (else 406 and a rollback). `limit`, `offset`, `columns` (for `DELETE`)
    do not select the rows and are ignored.

  ## Differences from PostgREST

  PATCH arrays with several objects return PGRST102 instead of applying one
  arbitrarily. Embedded mutation logic trees are rejected, and embedded pagination
  on minimal mutations returns PGRST108 rather than being ignored.
  """

  alias PgRest.{Auth, Error, MediaType, Negotiate, Plan, Request, Responder, Write}
  alias PgRest.Error.Translate
  alias PgRest.SQL.Write, as: SQL
  alias PgRest.Write.Payload

  @doc "Runs the `PATCH` (`:update`) or `DELETE` (`:delete`) and sends the response."
  @spec run(Plug.Conn.t(), map(), map(), Request.t(), map(), :update | :delete) :: Plug.Conn.t()
  def run(conn, opts, config, %Request{} = request, context, kind) do
    with {:ok, _provisional} <- Negotiate.negotiate(request),
         {:ok, columns} <- columns(kind, request),
         {:ok, state} <- authorize(conn, config, request, context, kind),
         request = %{request | authorization_state: state},
         {:ok, planned} <- plan(opts, config, request, context, kind),
         {:ok, media} <-
           Negotiate.resolve(request, planned.returning, conn, context,
             targets: Plan.Read.targets(planned.plan),
             mutating?: true
           ),
         {:ok, built} <- payload(kind, config, request, columns, context, opts),
         job = job(planned, built, media, kind),
         :ok <- require_filters(opts, kind, job),
         {:ok, result} <-
           Write.execute(
             opts,
             config,
             request,
             job,
             &statement(kind, opts, request, job, &1)
           ) do
      respond(conn, result, request, job, media, kind)
    else
      {:error, error} -> Responder.error(conn, error)
    end
  end

  # The plan text of an explained write, else the write's response.
  defp respond(conn, text, request, _job, %MediaType{kind: :plan} = media, _kind),
    do: Responder.plan(conn, text, request, media)

  defp respond(conn, result, request, job, media, kind),
    do: Responder.mutation(conn, result, request, job.returning, media, kind)

  defp columns(:update, request), do: Write.columns(request.params)
  defp columns(:delete, _request), do: {:ok, nil}

  # Filters are a read channel: `:read` as well as the operation whenever there is one.
  defp authorize(conn, config, request, context, kind) do
    Write.authorize(conn, config, kind, request, context,
      filters?: Write.filters?(request),
      location?: false
    )
  end

  defp payload(:update, config, request, columns, context, opts),
    do: Payload.build_update(config, request, columns, context, opts.max_bulk_rows)

  defp payload(:delete, _config, _request, _columns, _context, _opts),
    do: {:ok, %{input: nil, columns: nil, write_path: :fast, count: 0}}

  # Catalog loads and planning, before any transaction and before any user changeset runs, so
  # a request the hook denies (or that names an unknown column) never reaches them.
  defp plan(opts, config, request, context, kind) do
    missing = if kind == :update, do: request.prefer.missing

    Translate.guard_db(
      fn ->
        with {:ok, planned} <-
               Write.plan_mutation(request, config, context, Write.representation?(request)),
             {:ok, defaults} <- Write.defaults(opts.repo, planned.plan, missing),
             do: {:ok, Map.put(planned, :defaults, defaults)}
      end,
      Auth.role(request)
    )
  end

  defp job(planned, built, media, kind) do
    Map.merge(planned, %{
      media: media,
      write_path: built.write_path,
      input: built.input,
      columns: built.columns,
      check: if(kind == :update, do: :with_check, else: :none),
      locate?: false,
      max_affected?: true
    })
  end

  # Only column filters count: a declared custom param may narrow nothing (`handle_param/4`
  # is user code), so it never satisfies the check. It still needs `:read` (`Write.filters?/1`).
  defp require_filters(%{require_filters_for_mutations: true}, kind, %{plan: %{where: nil}} = job) do
    if writes?(kind, job), do: {:error, Error.where_required(kind)}, else: :ok
  end

  defp require_filters(_opts, _kind, _job), do: :ok

  # An update that sets nothing selects no row, so it needs no filter.
  defp writes?(:delete, _job), do: true
  defp writes?(:update, %{columns: columns}), do: columns != []

  defp statement(:update, opts, request, job, keys) do
    SQL.update(job.plan.resource, job.input, job.plan, job.returning,
      repo: opts.repo,
      columns: job.columns,
      missing: request.prefer.missing,
      defaults: job.defaults,
      media: job.media,
      keys: keys
    )
  end

  defp statement(:delete, opts, _request, job, keys) do
    SQL.delete(job.plan.resource, job.plan, job.returning,
      repo: opts.repo,
      media: job.media,
      keys: keys
    )
  end
end
