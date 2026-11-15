defmodule PgRest.Write do
  @moduledoc """
  The pipeline shared by every write: insert, upsert, update and delete.

      authorize -> plan the target (and catalog) -> payload -> execute -> respond

  Every write plans before building the payload, so a request the hook or `allow:` denies (or
  whose `select=` is invalid) never runs a user changeset.

  A write supplies its statement builder; this module owns what is the same for all of them:

    * `authorize/6`: the write's own operation, plus `:read` on the root when the response
      shows rows, a `Location` or a count, or the request filters (filters, counts and
      `RETURNING` are a read channel), all through `PgRest.Authorization.check/5` (`allow:`,
      then the hook). A `Location` also needs a readable primary key. Representation embeds
      are authorized by the planner.
    * `plan_mutation/4`: the same for `PATCH` and `DELETE`, keeping the root filters on the plan
      (`PgRest.Write.Modify`). `execute/5` takes `job.check` (`:with_check`, the default, or
      `:none` for a delete) and `job.locate?` (`false` when there is no `Location`).
    * `plan/4`: the target planned through `PgRest.Planner`, which yields the scoped source
      and column types. A representation plans the request's `select=`, `order=` and embedded
      parameters; root filters and paging do not apply to written rows. Anything else plans
      `select=*` without the planner's `:read` walk (the `authorize?: false` planner option),
      since `authorize/6` already decided what the write needs. The target table, its
      catalog and the `search_path` follow the scope's effective schema prefix
      (`PgRest.SQL.ScopedSource.effective_prefix/2`), as reads do.
    * `execute/5`: the transaction: the statement, the single-object check and the write
      check (the scope as a row-level security `WITH CHECK`). A failure rolls back.
    * `key_columns/4` (with a `locate?` flag) and `location/3`: the written keys and the
      `Location` header.

  The write check **fails closed**: a non-identity scope on a resource without a key
  cannot be checked, so the write is refused before any SQL (`PgRest.Registry` already
  rejects such a resource at start).

  ## Differences from PostgREST

  Strict max-affected counts rows actually written, including when aggregate
  representations collapse them. PostgREST counts the response rows instead.
  A hidden on_conflict column returns 42703, like a nonexistent conflict column.

  Hook permission caps bound response counts as well as representations. Transactional
  checks and single-row Location decisions still use the uncapped written rows; a cap
  cannot make a bulk write singular. PostgREST has no application permission cap.
  """

  alias PgRest.{
    Auth,
    Authorization,
    Catalog,
    Error,
    Executor,
    MediaType,
    Planner,
    Request,
    Responder
  }

  alias PgRest.Authorization.{Apply, State}
  alias PgRest.Grammar.Common
  alias PgRest.Planner.{Params, Result}
  alias PgRest.SQL.ScopedSource
  alias PgRest.SQL.Write, as: SQL

  require Logger

  @columns_expecting "field name (* or [a..z0..9_$])"

  @typedoc "A planned write: the read plan of the target and the negotiated media type."
  @type job :: %{
          required(:plan) => PgRest.Plan.Read.t(),
          required(:media) => PgRest.MediaType.t(),
          required(:write_path) => atom(),
          optional(atom()) => term()
        }

  # --- authorization -------------------------------------------------------------

  @doc """
  Authorizes each of `operations` on the target, and `:read` on the root when the response needs it
  (`headers-only`, a `count=` or a representation). Returns an explicit authorization
  state for the request; user context is never used to store grants.

  Options: `:filters?` (default `false`) says the request filters rows, which is a read
  channel and needs `:read` too; `:location?` (default `true`) says `headers-only` sends a
  `Location`, which `PATCH` and `DELETE` never do. A `Location` shows the primary key, so it
  also needs every key column to be readable (`readable:`), else `42501`, as Postgres needs
  `SELECT` on the columns a `RETURNING` reads.
  """
  @spec authorize(Plug.Conn.t(), map(), atom() | [atom()], Request.t(), map(), keyword()) ::
          {:ok, State.t()} | {:error, Error.t()}
  def authorize(conn, config, operations, request, context, opts \\ []) do
    if Authorization.query_hook?(Map.get(context, :authorization)) do
      authorize_policies(conn, config, List.wrap(operations), request, context, opts)
    else
      with :ok <- authorize_bare(conn, config, operations, request, context, opts),
           do: {:ok, State.empty()}
    end
  end

  defp authorize_policies(conn, config, operations, request, context, opts) do
    context = Map.merge(context, %{path: [], root?: true})
    located? = located?(request, opts)
    shown? = shows_rows?(request, located?)
    ops = read_ops(operations, shown? or targets_rows?(request, opts))

    with %Ecto.Query{} = base <- ScopedSource.base_query(config.module, context, []),
         {:ok, policies} <- policy_sources(conn, config, ops, base, context),
         {:ok, write} <- combine_policies(operations, policies, config.module),
         read = Map.get_lazy(policies, {[], :read}, fn -> Apply.unrestricted(base) end),
         {:ok, target} <- Apply.combine(read, write, config.module, columns: :left),
         :ok <- policy_location(config, read.columns, located?, context) do
      {:ok, write_state(policies, read, write, target, shown?)}
    else
      {:error, :denied} -> {:error, Error.table_denied(config, context)}
      {:error, _} = error -> error
    end
  end

  defp write_state(policies, read, write, target, shown?) do
    %{
      State.empty()
      | policies: Map.put(policies, {[], :read}, target),
        payload_columns: write.columns,
        write_check: write.query,
        read_check: read_check_source(shown?, read),
        hook?: true
    }
  end

  defp read_check_source(true, policy), do: policy.query
  defp read_check_source(false, _policy), do: nil

  defp located?(request, opts),
    do: Keyword.get(opts, :location?, true) and request.prefer.return == :headers_only

  defp shows_rows?(request, located?),
    do: representation?(request) or located? or request.prefer.count != nil

  defp targets_rows?(request, opts),
    do:
      Keyword.get(opts, :filters?, false) or
        Enum.any?(request.params, fn {key, _} -> key in ["select", "order", "on_conflict"] end)

  defp read_ops(ops, true), do: ops ++ [:read]
  defp read_ops(ops, false), do: ops

  defp policy_sources(conn, config, operations, base, context) do
    Result.reduce_ok(operations, %{}, fn op, policies ->
      with {:ok, policy} <-
             Apply.source(conn, context.authorization, config.module, op, base, context),
           do: {:ok, Map.put(policies, {[], op}, policy)}
    end)
  end

  defp combine_policies([first | rest], policies, resource) do
    Result.reduce_ok(rest, Map.fetch!(policies, {[], first}), fn op, accumulated ->
      Apply.combine(accumulated, Map.fetch!(policies, {[], op}), resource)
    end)
  end

  defp policy_location(_config, _columns, false, _context), do: :ok

  defp policy_location(config, columns, true, context) do
    with :ok <- ensure_key_readable(config, true, Auth.role(context)),
         do:
           Apply.check_columns(
             columns,
             config.module,
             Enum.map(config.primary_key, &Atom.to_string/1)
           )
  end

  defp authorize_bare(conn, config, operations, %Request{prefer: prefer}, context, opts) do
    auth = Map.get(context, :authorization)
    located? = located?(%Request{prefer: prefer}, opts)
    # A representation is planned later, and the planner authorizes `:read` on every resource
    # it shows, the root included.
    reads? =
      prefer.return != :representation and
        (Keyword.get(opts, :filters?, false) or prefer.count != nil or located?)

    with :ok <- check_all(auth, conn, config, read_ops(List.wrap(operations), reads?), context),
         do: ensure_key_readable(config, located?, Auth.role(context))
  end

  defp ensure_key_readable(config, true, role) do
    if Enum.all?(config.primary_key, &MapSet.member?(config.readable, Atom.to_string(&1))),
      do: :ok,
      else: {:error, Error.table_denied(config, role)}
  end

  defp ensure_key_readable(_config, false, _role), do: :ok

  defp check_all(auth, conn, config, operations, context),
    do: Result.all_ok(operations, &Authorization.check(auth, conn, config.module, &1, context))

  # --- columns= ------------------------------------------------------------------

  @doc "Parses `columns=a,b` into source column names, or `nil` when absent."
  @spec columns([{String.t(), String.t() | nil}]) ::
          {:ok, [String.t()] | nil} | {:error, Error.t()}
  def columns(params), do: name_list(params, "columns")

  @doc """
  Parses `on_conflict=a,b` into column names, or `nil` when absent. Same grammar and
  errors as `columns=`.
  """
  @spec on_conflict([{String.t(), String.t() | nil}]) ::
          {:ok, [String.t()] | nil} | {:error, Error.t()}
  def on_conflict(params), do: name_list(params, "on_conflict")

  defp name_list(params, name) do
    case List.keyfind(params, name, 0) do
      nil -> {:ok, nil}
      {^name, value} -> parse_names(name, value || "")
    end
  end

  defp parse_names(param, value) do
    with :ok <- Common.reject_nul(value),
         {:ok, names} <- take_names(value, []) do
      {:ok, Enum.uniq(names)}
    else
      {:error, %Error{}} = error ->
        error

      {:error, rest} ->
        {:error,
         Common.syntax_error("#{param} parameter", value, value, rest, @columns_expecting)}
    end
  end

  defp take_names(input, acc) do
    case Common.parse_name(input) do
      {:ok, name, ""} when name != "" -> {:ok, Enum.reverse([name | acc])}
      {:ok, name, "," <> rest} when name != "" -> take_names(rest, [name | acc])
      _ -> {:error, input}
    end
  end

  @doc "Whether the request asks for `return=representation`."
  @spec representation?(Request.t()) :: boolean()
  def representation?(%Request{prefer: prefer}), do: prefer.return == :representation

  @doc """
  Whether constraint details are hidden from the client (S-H5): when the effective source is
  not the identity scope (`scoped?`) or a column allowlist narrows the resource, as Postgres
  does under row-level security.
  """
  @spec scrub_details?(map(), boolean()) :: boolean()
  def scrub_details?(config, scoped?), do: scoped? or config.restricted_columns?

  @doc """
  The column defaults for `missing=default`, else none. Read from the target's effective
  schema (`PgRest.SQL.ScopedSource.effective_schema/2`).
  """
  @spec defaults(module(), PgRest.Plan.Read.t(), atom() | nil) :: {:ok, map()}
  def defaults(repo, %PgRest.Plan.Read{resource: resource} = plan, :default) do
    schema = ScopedSource.effective_schema(resource, plan.source_query)
    {:ok, Catalog.column_defaults(repo, schema, resource.__pgrest_config__().table)}
  end

  def defaults(_repo, _plan, _missing), do: {:ok, %{}}

  # --- planning ------------------------------------------------------------------

  # Parameters that never select rows or shape a representation.
  @ignored_params Params.not_shaping()
  @reserved_params Params.reserved()

  @doc """
  Plans the target of a write (see the moduledoc). Catalog lookups happen here, before the
  transaction opens.
  """
  @spec plan(Request.t(), map(), map(), boolean()) ::
          {:ok, PgRest.Plan.Read.t()} | {:error, Error.t()}
  def plan(%{authorization_state: %{hook?: true}} = request, config, context, _representation?) do
    shaped(
      plan_with(request, config, context, fn {key, _} -> key not in @ignored_params end, true)
    )
  end

  def plan(request, config, context, true) do
    shaped(plan_with(request, config, context, &representation_param?(&1, config), true))
  end

  def plan(request, config, context, false) do
    shaped(plan_with(request, config, context, fn _param -> false end, false))
  end

  defp representation_param?({key, value}, config),
    do: key in ["select", "order"] or embedded?(key, value, config)

  # Embeddedness comes from the parsed path alone (a quoted or JSON-path key may hold a dot).
  defp embedded?(key, value, config), do: Params.path(key, value, config.custom_params) != []

  defp shaped({:ok, plan}), do: {:ok, returning_plan(plan)}
  defp shaped(error), do: error

  # `keep?` picks the request parameters to plan; the planner authorizes `:read` (`allow:` and
  # the hook) only when `authorize?`. Paging and counts never apply to written rows.
  defp plan_with(request, config, context, keep?, authorize?) do
    request = %{request | params: Enum.filter(request.params, keep?)}

    with {:ok, plan} <-
           Planner.plan_read(request, config.module, context,
             authorize?: authorize?,
             policies: request.authorization_state.policies
           ),
         do:
           {:ok,
            %{
              plan
              | authorization_state: request.authorization_state,
                limit: nil,
                offset: 0,
                count: nil,
                max_limit: nil
            }}
  end

  @doc """
  Plans a `PATCH` or `DELETE`: `{:ok, %{plan:, returning:}}`.

  `plan` selects the rows: the root filters and logic trees stay on it (`plan.where`) for the
  statement to compile on the mutation target. It is planned against `select=*`, as upstream
  does, so an embedded parameter that names no embed (`?clients.id=eq.1`) is `PGRST108` before
  any SQL, and `embed=is.null` is a column filter (`42703`), never silently dropped.
  `limit`, `offset`, `columns` and `on_conflict` do not select rows and are dropped.

  `returning` is the plan of the representation (`select=`, `order=`, embedded parameters, the
  hook's `:read`), without filters, or `nil` for any other `return=`.

  `check_source` carries the base scope intersected with the write-operation policy. Custom
  params select rows like filters do, so, like filters, they never constrain the new row.
  """
  @spec plan_mutation(Request.t(), map(), map(), boolean()) ::
          {:ok,
           %{
             plan: PgRest.Plan.Read.t(),
             returning: PgRest.Plan.Read.t() | nil,
             authorization_state: State.t()
           }}
          | {:error, Error.t()}
  def plan_mutation(request, config, context, representation?) do
    with :ok <- reject_embedded_logic(request.params, config),
         {:ok, plan} <-
           plan_with(
             request,
             config,
             context,
             fn {key, _} = param ->
               (request.authorization_state.hook? and not representation? and
                  key in ["select", "order"]) or
                 target_param?(param, representation?, config)
             end,
             false
           ),
         {:ok, returning} <- returning(request, config, context, representation?),
         {:ok, state} <- policy_state(plan, context) do
      {:ok,
       %{
         plan: plan,
         returning: returning,
         authorization_state: state
       }}
    end
  end

  @doc false
  @spec policy_state(PgRest.Plan.Read.t(), map()) :: {:ok, State.t()} | {:error, Error.t()}
  def policy_state(%{authorization_state: %State{write_check: %Ecto.Query{}} = state}, _ctx),
    do: {:ok, state}

  def policy_state(plan, context) do
    with %Ecto.Query{} = source <- check_source(plan, context),
         do: {:ok, %{plan.authorization_state | write_check: source}}
  end

  defp check_source(%{custom_params: [], source_query: query}, _context), do: query

  defp check_source(%{resource: resource}, context),
    do: ScopedSource.base_query(resource, context, [])

  # The target sees every filter. A representation's embedded parameters are checked by its
  # own plan; without one they stay, so a parameter naming no embed is an error.
  defp target_param?({key, _value}, _representation?, _config) when key in @reserved_params,
    do: false

  defp target_param?({key, value}, true, config), do: not embedded?(key, value, config)
  defp target_param?(_param, false, _config), do: true

  # `clients.or=(...)` filters the embed in a read. PostgREST applies it to the mutated
  # table instead (a bug); PgRest refuses rather than choose.
  defp reject_embedded_logic(params, config) do
    if Enum.any?(params, fn {key, value} ->
         Params.logic_key?(key) and embedded?(key, value, config)
       end),
       do: {:error, Error.parse_error("embedded logic trees are not supported on mutations")},
       else: :ok
  end

  defp returning(request, config, context, true) do
    keep? = fn {key, _value} -> key not in @ignored_params end
    shaped(plan_with(request, config, context, keep?, true))
  end

  defp returning(_request, _config, _context, false), do: {:ok, nil}

  defp returning_plan(%PgRest.Plan.Read{} = plan), do: %{plan | where: nil}

  @doc """
  Whether the request names a row filter (or something that may be one: an embedded
  parameter). Computed from the query string, before any planning, so `:read` can be
  authorized first. For this `:read` check, declared `custom_params` count:
  `handle_param/4` narrows the rows a `PATCH` or `DELETE` touches, so it is a read
  channel like any filter. They do not satisfy `require_filters_for_mutations`, which
  needs a column filter.
  """
  @spec filters?(Request.t()) :: boolean()
  def filters?(%Request{params: params}),
    do: Enum.any?(params, fn {key, _value} -> key not in @reserved_params end)

  # --- execution -----------------------------------------------------------------

  @doc """
  Runs the write in one transaction. `build` receives the key fields (strings) the
  statement must return as `pgrst_keys`, or `nil`, and returns `{sql, params}`.

  Returns `{:ok, result}` (`body`, `page_total`, `keys`; the plan text of a plan media type) or
  `{:error, error}`.
  """
  @spec execute(map(), map(), Request.t(), job(), ([String.t()] | nil -> {String.t(), [term()]})) ::
          {:ok, map() | String.t()} | {:error, Error.t()}
  def execute(opts, config, request, job, build) do
    scoped? =
      not ScopedSource.identity_scope?(config.module, job.plan.source_query) or
        job.plan.hook_limit != nil

    # WITH CHECK uses scope plus write policy, never request filters or custom params.
    check_source = job.authorization_state.write_check

    checked? =
      not ScopedSource.identity_scope?(config.module, check_source) or read_checked?(config, job)

    with :ok <- ensure_checkable(config, scoped?) do
      # PATCH/DELETE keep their representation tree separately from the target.
      # Its embeds contribute both schema paths and detail-scrubbing restrictions.
      execution_plan = Map.get(job, :returning) || job.plan

      scrub? =
        scrub_details?(config, scoped?) or
          job.authorization_state.payload_columns != :all or checked?

      exec =
        opts
        |> Executor.config(execution_plan, request.prefer)
        |> Map.update!(
          :scrub_details?,
          &(&1 or scrub?)
        )

      case job.media do
        %MediaType{kind: :plan, plan: spec} ->
          Executor.explain_transaction(opts.repo, request.prefer, build.(nil), spec, exec)

        _media ->
          transact_checked(opts, config, request, job, build, exec, checked?, check_source)
      end
    end
  end

  defp read_checked?(config, %{authorization_state: %State{read_check: %Ecto.Query{} = query}}),
    do: not ScopedSource.identity_scope?(config.module, query)

  defp read_checked?(_config, _job), do: false

  defp transact_checked(opts, config, request, job, build, exec, checked?, check_source) do
    check = Map.get(job, :check, :with_check)
    statement = build.(keys_for(config, checked?, request, job, check))
    checking = checked? and check == :with_check and %{job.plan | source_query: check_source}
    transact(opts, config, request, job, {checking, statement}, exec)
  end

  # A write without a check (a delete) never needs its keys back; an update has no `Location`.
  defp keys_for(_config, _scoped?, _request, _job, :none), do: nil

  defp keys_for(config, scoped?, request, job, :with_check),
    do: key_columns(config, scoped?, request, Map.get(job, :locate?, true))

  # `checking` carries the write policy and base scope, or is false for no check.
  defp transact(opts, config, request, job, {checking, statement}, exec) do
    write_exec = Map.put(exec, :query_meta, %{write_path: job.write_path})

    Executor.transaction(
      opts.repo,
      request.prefer,
      fn ->
        with {:ok, result} <- Executor.write(opts.repo, statement, write_exec),
             :ok <- ensure_matched(job, result),
             :ok <- ensure_complete(job, config, result, Auth.role(request)),
             :ok <- Executor.ensure_single(job.media, singular_result(job, result)),
             :ok <- ensure_max_affected(job, request, result),
             :ok <- write_check(opts, config, checking, result, exec),
             :ok <- read_check(opts, config, job, result, exec) do
          {:ok, result}
        end
      end,
      exec
    )
  end

  # Permission caps hide response rows, but cannot turn a multi-row write into a single write.
  defp singular_result(%{plan: %{hook_limit: cap}}, result) when not is_nil(cap),
    do: %{result | page_total: result.written}

  defp singular_result(_job, result), do: result

  @doc false
  # A scope that is not the identity can only be enforced on written rows through a key.
  @spec ensure_checkable(map(), boolean()) :: :ok | {:error, Error.t()}
  def ensure_checkable(config, true) do
    if ScopedSource.key_fields(config) == [] do
      Logger.error(
        "PgRest: #{inspect(config.module)} has a scope but no primary key or unique_key, " <>
          "so writes cannot be checked against it; refusing the write"
      )

      {:error, Error.internal()}
    else
      :ok
    end
  end

  def ensure_checkable(_config, false), do: :ok

  # A `PUT` writes only when exactly one payload element has the URL's key.
  defp ensure_matched(%{put?: true}, %{matched: 0}), do: {:error, Error.put_payload_mismatch()}

  defp ensure_matched(%{put?: true}, %{matched: n}) when n > 1,
    do: {:error, Error.single_put_object()}

  defp ensure_matched(_job, _result), do: :ok

  # A guarded upsert (`merge` over a scope) skips a conflicting row the scope does not
  # show, so fewer rows *written* (not shown: an `!inner` embed can drop rows from the
  # representation) than were sent means one of them lay outside it: 42501, rolled back.
  defp ensure_complete(%{guarded?: true, input_count: sent}, config, %{written: written}, role)
       when written < sent,
       do: {:error, Error.check_violation(config.table, role)}

  defp ensure_complete(_job, _config, _result, _role), do: :ok

  # Only an update or delete is bounded by `max-affected` (the job says so), after the
  # singularity check, as PostgREST orders them. The bound is on the rows written: an aggregating
  # `select=` (`count()`) shows fewer rows than it touched (PostgREST compares those; a known
  # difference).
  defp ensure_max_affected(%{max_affected?: true}, %Request{prefer: prefer}, result),
    do: Executor.ensure_max_affected(prefer, result.written)

  defp ensure_max_affected(_job, _request, _result), do: :ok

  defp read_check(
         opts,
         config,
         %{authorization_state: %State{read_check: %Ecto.Query{} = source}, plan: plan} = job,
         result,
         exec
       ) do
    if same_check?(config, source, job.authorization_state),
      do: :ok,
      else: write_check(opts, config, %{plan | source_query: source}, result, exec)
  end

  defp read_check(_opts, _config, _job, _result, _exec), do: :ok

  defp same_check?(config, source, state),
    do: ScopedSource.identity_scope?(config.module, source) or source == state.write_check

  # Every written key must still be visible through the scope.
  defp write_check(_opts, _config, false, _result, _exec), do: :ok
  defp write_check(_opts, _config, _plan, %{keys: nil}, _exec), do: :ok

  defp write_check(opts, config, plan, %{keys: keys}, exec) do
    fields = config |> ScopedSource.key_fields() |> field_order(config)
    statement = SQL.check(config.module, plan, keys, fields, opts.repo)

    case Executor.count(opts.repo, statement, exec) do
      {:ok, 0} -> :ok
      {:ok, _missing} -> {:error, Error.check_violation(config.table, Auth.role(exec))}
      {:error, _error} = error -> error
    end
  end

  # --- keys and Location ---------------------------------------------------------

  @doc """
  The key fields (strings, in field order) a statement returns as `pgrst_keys`: the scope
  key when the write is checked, plus the primary key for `return=headers-only`.
  """
  @spec key_columns(map(), boolean(), Request.t(), boolean()) :: [String.t()] | nil
  def key_columns(config, scoped?, %Request{prefer: prefer}, locate? \\ true) do
    checked = if scoped?, do: ScopedSource.key_fields(config), else: []
    located = if locate? and prefer.return == :headers_only, do: config.primary_key, else: []

    case field_order(Enum.uniq(checked ++ located), config) do
      [] -> nil
      fields -> fields
    end
  end

  @doc """
  The source columns of `fields` (atoms), in the resource's field order.
  """
  @spec source_columns(map(), [atom()]) :: [String.t()]
  def source_columns(config, fields),
    do: fields |> field_order(config) |> Enum.map(&Map.fetch!(config.field_columns, &1))

  @doc """
  `{field name, source column}` for each of `fields` (atoms), in the resource's field order.
  """
  @spec key_pairs(map(), [atom()]) :: [{String.t(), String.t()}]
  def key_pairs(config, fields),
    do: Enum.zip(field_order(fields, config), source_columns(config, fields))

  @doc """
  `:ok` when every `on_conflict=` name is a readable column of the resource; otherwise the
  `42703` Postgres reports for an unknown column, so the parameter is no oracle for hidden
  columns or index names.
  """
  @spec ensure_conflict_columns(map(), [String.t()]) :: :ok | {:error, Error.t()}
  def ensure_conflict_columns(config, names) do
    case Enum.find(names, &(not MapSet.member?(config.readable_sources, &1))) do
      nil -> :ok
      name -> {:error, Error.undefined_column(name)}
    end
  end

  defp field_order(key, config), do: for(f <- config.fields, f in key, do: Atom.to_string(f))

  @doc """
  The `Location` of a single written row, `/<table>?<pk>=eq.<value>` joined with `&`
  (`is.null` for a null), or `nil`. Values are encoded like PostgREST's query strings and
  keep their text (`1.50`).
  """
  @spec location(map(), Request.t(), map()) :: String.t() | nil
  def location(config, %Request{prefer: %{return: :headers_only}}, %{keys: keys, written: 1})
      when is_binary(keys) do
    [row] = Jason.decode!(keys, floats: :decimals)
    pk = field_order(config.primary_key, config)

    if pk != [] and Enum.all?(pk, &Map.has_key?(row, &1)) do
      query = Enum.map_join(pk, "&", &key_param(config, &1, Map.fetch!(row, &1)))
      "/" <> config.table <> "?" <> query
    end
  end

  def location(_config, _request, _result), do: nil

  defp key_param(config, field, value),
    do: Map.fetch!(config.field_columns, field) <> "=" <> key_value(value)

  defp key_value(nil), do: "is.null"
  defp key_value(value), do: "eq." <> Responder.encode_part(text(value))

  defp text(value) when is_binary(value), do: value
  defp text(%Decimal{} = value), do: Decimal.to_string(value, :normal)
  defp text(value) when is_map(value) or is_list(value), do: Jason.encode!(value)
  defp text(value), do: to_string(value)
end
