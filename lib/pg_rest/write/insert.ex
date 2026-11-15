defmodule PgRest.Write.Insert do
  @moduledoc """
  Serves `POST /<table>`: single and bulk inserts and upserts, on the pipeline in
  `PgRest.Write`.

  `Prefer: resolution=merge-duplicates|ignore-duplicates` makes it an upsert on the
  `on_conflict=` columns (default: the primary key). `merge` updates only the payload
  columns of a conflicting row and needs `:update` as well as `:create`. The status follows
  PostgREST: `merge` is 200 when no row was inserted (`SQL.Write` counts them) and 201
  otherwise; `ignore` is always 201. `Preference-Applied` echoes `resolution` unless the
  table has no primary key and the request names no `on_conflict`.

  A `PUT` (`PgRest.Write.Put`) arrives here as a one row `merge` on the primary key, and is answered
  by `PgRest.Responder.put/6`. Over a non-identity scope the conflicting row must be in scope (`PgRest.SQL.Write` guards
  the update with a correlated `EXISTS`); a `merge` that skips a row because of it is a 42501
  and rolls back.

  The order is `PgRest.Write`'s: authorize, then plan the target (and its representation) and
  read `column_defaults/3` when `missing=default`, then validate the payload
  (`PgRest.Write.Payload`: row count, key shape, unknown and non-writable columns, a custom
  changeset), and `PgRest.SQL.Write.insert/3` builds the statement. A request the hook denies
  or whose `select=` is invalid never runs a user changeset.
  """

  alias PgRest.{Auth, MediaType, Negotiate, Plan, Request, Responder, Write}
  alias PgRest.Authorization.Apply
  alias PgRest.Error.Translate
  alias PgRest.SQL.ScopedSource
  alias PgRest.SQL.Write, as: SQL
  alias PgRest.Write.Payload

  @doc """
  Runs the insert and sends the response. `key` is a `PUT`'s URL key (`PgRest.Write.Put`): see
  `PgRest.SQL.Write.insert/3`.
  """
  @spec run(Plug.Conn.t(), map(), map(), Request.t(), map(), [{String.t(), String.t()}] | nil) ::
          Plug.Conn.t()
  def run(conn, opts, config, %Request{} = request, context, key \\ nil) do
    with {:ok, _provisional} <- Negotiate.negotiate(request),
         {:ok, columns} <- Write.columns(request.params),
         {:ok, conflict} <- conflict(config, request),
         operations = operations(conflict),
         {:ok, state} <-
           Write.authorize(
             conn,
             config,
             operations,
             request,
             context,
             filters?: key != nil or Write.filters?(request),
             location?: key == nil
           ),
         request = %{request | authorization_state: state},
         {:ok, planned} <- plan(opts, config, request, context, key),
         {:ok, media} <-
           Negotiate.resolve(request, representation(planned), conn, context,
             targets: Plan.Read.targets(planned.plan),
             mutating?: true
           ),
         :ok <- payload_conflict(config, conflict, state),
         {:ok, built} <-
           Payload.build(
             config,
             request,
             columns,
             context,
             opts.max_bulk_rows,
             operation(conflict)
           ),
         job = job(config, planned, built, conflict, media),
         {:ok, result} <-
           Write.execute(opts, config, request, job, &statement(opts, config, request, job, &1)) do
      respond(conn, result, request, job, media, config)
    else
      {:error, error} -> Responder.error(conn, error)
    end
  end

  # The plan text of an explained insert, else the insert's response.
  defp respond(conn, text, request, _job, %MediaType{kind: :plan} = media, _config),
    do: Responder.plan(conn, text, request, media)

  defp respond(conn, result, request, %{put?: true} = job, media, _config),
    do: Responder.put(conn, result, request, job.plan, media, upsert_status(request, result))

  defp respond(conn, result, request, job, media, config) do
    Responder.insert(
      conn,
      result,
      request,
      job.plan,
      media,
      Write.location(config, request, result),
      status: upsert_status(request, result),
      resolution?: job.resolution_applied?
    )
  end

  defp payload_conflict(_config, nil, _context), do: :ok
  defp payload_conflict(_config, %{named?: false}, _context), do: :ok

  defp payload_conflict(config, conflict, state) do
    read = Map.get_lazy(state.policies, {[], :read}, fn -> Apply.unrestricted(nil) end)

    readable =
      config.readable_sources
      |> Apply.intersect_columns(state.payload_columns)
      |> Apply.intersect_columns(read.columns)

    Write.ensure_conflict_columns(%{config | readable_sources: readable}, conflict.target)
  end

  # --- on_conflict -----------------------------------------------------------------

  # `nil` for a plain insert; otherwise `%{target: [source column], action:, applied?:}`.
  # The target is `on_conflict=` (every name a readable column, else 42703 before any SQL)
  # or else the primary key; PostgREST only echoes the resolution when there is one.
  defp conflict(_config, %Request{prefer: %{resolution: nil}}), do: {:ok, nil}

  defp conflict(config, %Request{prefer: %{resolution: resolution}, params: params}) do
    with {:ok, named} <- Write.on_conflict(params),
         :ok <- ensure_columns(config, named) do
      target = named || Write.source_columns(config, config.primary_key)

      {:ok,
       %{
         target: target,
         action: action(resolution),
         applied?: named != nil or target != [],
         named?: named != nil
       }}
    end
  end

  defp ensure_columns(_config, nil), do: :ok
  defp ensure_columns(config, names), do: Write.ensure_conflict_columns(config, names)

  defp action(:merge_duplicates), do: :merge
  defp action(:ignore_duplicates), do: :ignore

  # A merge with a conflict target updates existing rows: it needs `:update` too.
  defp updates?(%{action: :merge, target: [_ | _]}), do: true
  defp updates?(_conflict), do: false

  defp operations(conflict), do: if(updates?(conflict), do: [:create, :update], else: [:create])

  # What a custom `changeset/3` sees as `context.operation`.
  defp operation(%{target: [_ | _]}), do: :upsert
  defp operation(_conflict), do: :create

  defp upsert_status(%Request{prefer: %{resolution: :merge_duplicates}}, %{inserted: inserted}),
    do: if((inserted || 0) > 0, do: 201, else: 200)

  defp upsert_status(_request, _result), do: 201

  defp on_conflict(_config, _plan, nil, _written), do: nil
  defp on_conflict(_config, _plan, %{target: [], action: :ignore}, _written), do: nil

  defp on_conflict(config, plan, %{target: target, action: action} = conflict, written) do
    %{target: target, action: action, guard: guard(config, plan, conflict, written)}
  end

  # Only a merge that really updates (a target and columns to set) over a scope.
  defp guard(config, plan, conflict, [_ | _]) do
    if updates?(conflict) and not ScopedSource.identity_scope?(config.module, plan.source_query),
      do: %{plan: plan, key: Write.key_pairs(config, ScopedSource.key_fields(config))}
  end

  defp guard(_config, _plan, _conflict, []), do: nil

  # Catalog loads and planning, before any transaction and before any user changeset runs, so
  # a representation the hook denies (or a bad `select=`) never reaches it.
  defp plan(opts, config, request, context, key) do
    representation? = Write.representation?(request)

    Translate.guard_db(
      fn ->
        with {:ok, plan} <- Write.plan(request, config, context, representation?),
             {:ok, defaults} <- Write.defaults(opts.repo, plan, request.prefer.missing),
             {:ok, state} <- Write.policy_state(plan, context),
             do:
               {:ok,
                %{
                  plan: plan,
                  defaults: defaults,
                  representation?: representation?,
                  put?: key != nil,
                  key: key,
                  authorization_state: state
                }}
      end,
      Auth.role(request)
    )
  end

  defp representation(%{representation?: true, plan: plan}), do: plan
  defp representation(_planned), do: nil

  defp job(config, planned, built, conflict, media) do
    on_conflict = on_conflict(config, planned.plan, conflict, built.columns)

    Map.merge(planned, %{
      media: media,
      write_path: built.write_path,
      input: built.input,
      input_count: if(planned.put?, do: 1, else: built.count),
      columns: built.columns,
      on_conflict: on_conflict,
      guarded?: match?(%{guard: %{}}, on_conflict),
      resolution_applied?: match?(%{applied?: true}, conflict),
      locate?: not planned.put?
    })
  end

  defp statement(opts, config, request, job, keys) do
    SQL.insert(config.module, job.input,
      repo: opts.repo,
      source_query: job.plan.source_query,
      columns: job.columns,
      missing: request.prefer.missing,
      defaults: job.defaults,
      on_conflict: job.on_conflict,
      key: job.key,
      returning_plan: if(job.representation?, do: job.plan),
      hook_limit: job.plan.hook_limit,
      media: job.media,
      keys: keys
    )
  end
end
