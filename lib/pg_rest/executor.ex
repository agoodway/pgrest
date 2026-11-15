defmodule PgRest.Executor do
  @moduledoc """
  Runs compiled statements against the repo: one statement per read, count modes,
  the request transaction, statement-cache promotion and error translation.

  Every PgRest repo call goes through `repo_opts/2`, which merges `log: false` and
  `telemetry_event: nil` for statements (Ecto's query events carry the bind parameters, so
  they reach neither the logger nor repo telemetry handlers; `[:pgrest, :query]` replaces
  them), `telemetry_options: [pgrest: true]`,
  the `PgRest.StatementCache` options and, when `statement_timeout` is set, a client
  timeout one second above it.

  ## Config

  A map with `:statement_cache` (see `PgRest.StatementCache`) and `:statement_timeout`
  (a Postgres interval string such as `"5s"`); missing keys take the plug defaults. `config/3`
  adds the transaction setup (`transaction/4`) and `:authenticated?`, which decides a `42501`'s
  401 or 403.

  ## Telemetry

  `[:pgrest, :query]` is a span around each statement with `%{sql, params_count,
  prepared}` metadata and `%{rows, error_kind}` added on stop (`error_kind` is `nil`, or `:database`,
  `:connection` or `:internal` for a failure). Parameter values are never included.
  """

  alias PgRest.{Auth, Error, Plan, ResponseGucs, StatementCache}
  alias PgRest.Error.Translate
  alias PgRest.SQL.{Builder, Explain, Read, ScopedSource}

  @base_opts [log: false, telemetry_options: [pgrest: true]]
  # Setup, read, planned or estimated count, explain (plus `pre_request` when configured).
  @max_statements 4
  @unit_ms %{
    "us" => 0.001,
    "ms" => 1,
    "s" => 1_000,
    "min" => 60_000,
    "h" => 3_600_000,
    "d" => 86_400_000
  }

  @type result :: %{
          body: String.t(),
          page_total: non_neg_integer(),
          total: non_neg_integer() | nil,
          gucs: PgRest.ResponseGucs.decoded()
        }

  # The options every PgRest repo call carries. `sql` is the statement text (or `nil`
  # for a transaction or a catalog load) and decides statement-cache promotion.
  @doc false
  @spec repo_opts(String.t() | nil, map()) :: keyword()
  def repo_opts(sql, config) do
    @base_opts
    |> Keyword.merge(event_opts(sql))
    |> Keyword.merge(cache_opts(sql, config))
    |> Keyword.merge(timeout_opts(sql, config))
  end

  # A statement carries bind parameters, which Ecto's query event would hand to every
  # repo telemetry handler; `[:pgrest, :query]` stands in for it. Parameterless calls
  # (transactions, catalog loads) keep the repo event, marked `pgrest: true`.
  defp event_opts(nil), do: []
  defp event_opts(_sql), do: [telemetry_event: nil]

  defp cache_opts(nil, _config), do: []

  defp cache_opts(sql, config) do
    StatementCache.query_opts(sql, Map.get(config, :statement_cache), guc(config, "role"))
  end

  defp guc(config, name) do
    case List.keyfind(Map.get(config, :gucs, []), name, 0) do
      {_, value} -> value
      nil -> nil
    end
  end

  # A statement may take `statement_timeout` plus a second of client slack. The
  # transaction (`sql` nil) checks out the connection for all its statements, so its
  # deadline covers the most a request runs: setup, `pre_request`, read, count and explain.
  defp timeout_opts(sql, %{statement_timeout: interval} = config) when is_binary(interval) do
    {:ok, ms} = interval_ms(interval)
    statements = if sql == nil, do: transaction_statements(config), else: 1
    [timeout: statements * ms + 1_000]
  end

  defp timeout_opts(_sql, _config), do: []

  defp transaction_statements(%{pre_request: sql}) when is_binary(sql), do: @max_statements + 1
  defp transaction_statements(_config), do: @max_statements

  @doc """
  Milliseconds of a Postgres interval string (`"50ms"`, `"5s"`, `"2min"`, `"1h"`, `"1d"`;
  a bare integer is milliseconds): `{:ok, ms}`, or `:error` for anything else.
  """
  @spec interval_ms(String.t()) :: {:ok, pos_integer()} | :error
  def interval_ms(interval) do
    with [_, number, unit] <- Regex.run(~r/^\s*(\d+)\s*(us|ms|s|min|h|d|)\s*$/, interval),
         ms when ms > 0 <-
           ceil(String.to_integer(number) * Map.fetch!(@unit_ms, unit_or_ms(unit))) do
      {:ok, ms}
    else
      _ -> :error
    end
  end

  defp unit_or_ms(""), do: "ms"
  defp unit_or_ms(unit), do: unit

  @doc """
  Runs a read statement and resolves the total for `count`.

  `planned` runs `EXPLAIN (FORMAT JSON)` on the count subquery. `estimated` follows
  PostgREST: the exact count is bounded by `max_limit + 1`; above `max_limit` (or with no
  `max_limit`) the larger of the exact count and the planner's estimate is used. An RPC runs
  no further query: its `estimated` total is exact and its `planned` total is `nil`.
  """
  @spec read(module(), {String.t(), [term()]}, atom() | nil, Plan.Read.t(), map()) ::
          {:ok, result()} | {:error, Error.t()}
  def read(repo, {sql, params}, count, %Plan.Read{} = plan, config \\ %{}) do
    with {:ok, %{rows: [[total, page_total, body, headers, status]]}} <-
           query(repo, sql, params, config),
         {:ok, gucs} <- ResponseGucs.decode(headers, status),
         {:ok, total} <- resolve_total(repo, count, total, page_total, plan, config) do
      {:ok, %{body: body, page_total: page_total, total: total, gucs: gucs}}
    end
  end

  defp resolve_total(_repo, nil, total, _page_total, _plan, _config), do: {:ok, total}
  defp resolve_total(_repo, :exact, total, _page_total, _plan, _config), do: {:ok, total}

  # Capped reads compute an exact total in their existing statement for every count mode.
  defp resolve_total(_repo, _count, total, _page_total, %Plan.Read{hook_limit: cap}, _config)
       when not is_nil(cap), do: {:ok, total}

  # A count query would run the function again: `estimated` is the exact total the statement
  # computed, and `planned` stays unknown (`NULL`), as in PostgREST.
  defp resolve_total(_repo, _count, total, _page_total, %Plan.Read{source: {:call, _}}, _config),
    do: {:ok, total}

  defp resolve_total(repo, :planned, _total, _page_total, plan, config),
    do: explain_total(repo, plan, config)

  defp resolve_total(repo, :estimated, _total, page_total, plan, config) do
    with {:ok, exact} <- bounded_count(repo, page_total, plan, config) do
      estimate(repo, exact, plan, config)
    end
  end

  defp estimate(repo, exact, %{max_limit: cap} = plan, config) when cap == nil or exact > cap do
    with {:ok, explained} <- explain_total(repo, plan, config),
         do: {:ok, max(exact, explained || 0)}
  end

  defp estimate(_repo, exact, _plan, _config), do: {:ok, exact}

  defp bounded_count(_repo, page_total, %{limit: nil, offset: 0, max_limit: nil}, _config),
    do: {:ok, page_total}

  defp bounded_count(repo, _page_total, plan, config) do
    {rows, builder} = count_rows(repo, plan)

    {limit, builder} =
      case plan.max_limit do
        nil -> {[], builder}
        max -> Builder.limit(builder, max + 1)
      end

    {sql, params} =
      Builder.to_sql(builder, ["SELECT pg_catalog.count(*) FROM (", rows, limit, ") _pgrst_count"])

    with {:ok, %{rows: [[total]]}} <- query(repo, sql, params, config), do: {:ok, total}
  end

  defp explain_total(repo, plan, config) do
    {rows, builder} = count_rows(repo, plan)
    {sql, params} = Builder.to_sql(builder, ["EXPLAIN (FORMAT JSON) ", rows])

    with {:ok, %{rows: [[plan_json]]}} <- query(repo, sql, params, config) do
      {:ok, plan_rows(plan_json)}
    end
  end

  defp plan_rows([%{"Plan" => %{"Plan Rows" => rows}} | _]) when is_integer(rows), do: rows
  defp plan_rows(_other), do: nil

  # The filters and row-count-changing joins of the plan, without order, limit or select.
  defp count_rows(repo, plan) do
    Read.node(plan, nil, Builder.new(repo: repo), %{count?: true, cte?: false})
  end

  @doc """
  Runs a write statement (see `PgRest.SQL.Write`), which returns one row of `total`,
  `page_total`, `body`, `pgrst_keys` (the written keys as JSON text, or `nil`) and
  `pgrst_inserted` (the rows an upsert really inserted, or `nil`) and `pgrst_written` (rows
  the mutation wrote, whatever the representation then shows), `pgrst_matched` (the payload
  elements a `PUT` matched, or `nil`), then the decoded response GUCs
  (`PgRest.ResponseGucs`).

  A `:query_meta` map in `config` is merged into the `[:pgrest, :query]` metadata.
  """
  @spec write(module(), {String.t(), [term()]}, map()) ::
          {:ok,
           %{
             body: String.t() | nil,
             page_total: non_neg_integer(),
             keys: String.t() | nil,
             inserted: integer() | nil,
             written: non_neg_integer(),
             matched: non_neg_integer() | nil,
             gucs: PgRest.ResponseGucs.decoded()
           }}
          | {:error, Error.t()}
  def write(repo, {sql, params}, config) do
    with {:ok,
          %{rows: [[_total, page_total, body, keys, inserted, written, matched, headers, status]]}} <-
           query(repo, sql, params, config),
         {:ok, gucs} <- ResponseGucs.decode(headers, status) do
      {:ok,
       %{
         body: body,
         page_total: page_total,
         keys: keys,
         inserted: inserted,
         written: written,
         matched: matched,
         gucs: gucs
       }}
    end
  end

  @doc """
  The request transaction around `explain/3` of `statement` explained as `spec`
  (`PgRest.SQL.Explain.wrap/2`): an `analyze` of a write rolls back with it under
  `Prefer: tx=rollback`, and none of a result's checks run.
  """
  @spec explain_transaction(module(), PgRest.Prefer.t(), {String.t(), [term()]}, map(), map()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def explain_transaction(repo, prefer, statement, spec, config) do
    transaction(
      repo,
      prefer,
      fn -> explain(repo, Explain.wrap(statement, spec), config) end,
      config
    )
  end

  @doc """
  Runs an `EXPLAIN` statement (`PgRest.SQL.Explain.wrap/2`) and returns the plan as the
  response body: for `FORMAT JSON` the single `QUERY PLAN` value re-encoded with `Jason`
  (`[{"Plan":...}]`), for `FORMAT TEXT` the rows joined with a newline. Like every statement it
  passes `log: false` (`repo_opts/2`); the plan shows the bound values, which is why the plan
  media type is gated (`PgRest.Negotiate`). Meant for the request transaction, so that
  `ANALYZE` of a write is rolled back with it.
  """
  @spec explain(module(), {String.t(), [term()]}, map()) ::
          {:ok, String.t()} | {:error, Error.t()}
  def explain(repo, {sql, params}, config \\ %{}) do
    with {:ok, %{rows: rows}} <- query(repo, sql, params, config), do: {:ok, plan_body(rows)}
  end

  defp plan_body([[plan]]) when is_list(plan) or is_map(plan), do: Jason.encode!(plan)
  defp plan_body(rows), do: Enum.map_join(rows, "\n", fn [line] -> line end)

  @doc """
  The `vnd.pgrst.object+json` media type needs exactly one row: PGRST116 otherwise. Checked
  inside the request transaction (a write or a volatile call is then rolled back), before
  `ensure_max_affected/2`, as PostgREST orders them.
  """
  @spec ensure_single(PgRest.MediaType.t(), %{
          required(:page_total) => non_neg_integer(),
          optional(atom()) => term()
        }) :: :ok | {:error, Error.t()}
  def ensure_single(%PgRest.MediaType{kind: :object}, %{page_total: count}) when count != 1,
    do: {:error, Error.single_object(count)}

  def ensure_single(_media, _result), do: :ok

  @doc """
  `Prefer: handling=strict, max-affected=n`: `{:error, PGRST124}` when `affected`, the rows the
  statement affected, is over `n` (the caller's transaction then rolls back), else `:ok`.
  Lenient handling ignores `max-affected`. A write passes the rows it wrote (`written`), never
  the rows its `select=` returns, which an aggregate can collapse; a call passes its result rows.
  """
  @spec ensure_max_affected(PgRest.Prefer.t(), non_neg_integer()) :: :ok | {:error, Error.t()}
  def ensure_max_affected(%PgRest.Prefer{handling: :strict, max_affected: max}, affected)
      when is_integer(max) and affected > max,
      do: {:error, Error.max_affected_exceeded(affected)}

  def ensure_max_affected(_prefer, _affected), do: :ok

  @doc "Runs a statement returning one integer (the write check's count)."
  @spec count(module(), {String.t(), [term()]}, map()) ::
          {:ok, non_neg_integer()} | {:error, Error.t()}
  def count(repo, {sql, params}, config) do
    with {:ok, %{rows: [[count]]}} <- query(repo, sql, params, config), do: {:ok, count}
  end

  @doc false
  # The executor config of a request: statement cache, timeout, and the `search_path` of the
  # resource schemas the plan touches, then `public`, like PostgREST.
  # An RPC's read-only call (`PgRest.Plan.Call` `read_only?`) runs in a read-only transaction.
  # A valid `Prefer: timezone` (`PgRest.Request.Prefer.validate/2`) is the transaction's `timezone`.
  # `opts.transaction` (`PgRest.Auth.transaction/3`, set by `PgRest.Plug`) adds the request's
  # role (for error statuses) and, in RLS mode, its GUCs, `pre_request` and read-only reads.
  @spec config(map(), Plan.Read.t(), PgRest.Prefer.t()) :: map()
  def config(opts, plan, %PgRest.Prefer{} = prefer) do
    transaction = Map.get(opts, :transaction, %{})

    %{
      scrub_details?: Plan.Read.scrub_details?(plan),
      timezone: prefer.timezone,
      statement_cache: opts.statement_cache,
      statement_timeout: opts.statement_timeout,
      search_path: plan_search_path(plan),
      read_only?: read_only?(plan) or Map.get(transaction, :read_only?, false),
      authenticated?: Map.get(transaction, :authenticated?, false),
      role_settings: Map.get(transaction, :role_settings, []),
      gucs: Map.get(transaction, :gucs, []),
      pre_request: Map.get(transaction, :pre_request)
    }
  end

  defp read_only?(%Plan.Read{source: {:call, %Plan.Call{read_only?: read_only?}}}), do: read_only?
  defp read_only?(_plan), do: false

  # Each node's effective schema (`ScopedSource.effective_schema/2`, the scope's prefix first).
  # An RPC runs under the request schema (its function's) first, as PostgREST's
  # `[schema] ++ db-extra-search-path`. A resource result also lists the resource's schemas:
  # unlike PostgREST, PgRest leaves unprefixed tables (and the scope's own SQL) unqualified,
  # so they resolve through `search_path`. The function body sees those schemas too.
  defp plan_search_path(plan) do
    function = for {:call, %Plan.Call{function: function}} <- [plan.source], do: function.schema

    nodes =
      for {resource, query} <- Plan.Read.sources(plan),
          do: ScopedSource.effective_schema(resource, query)

    Enum.uniq(function ++ nodes ++ ["public"])
  end

  # One repo call: telemetry span, repo options, translation of database exceptions.
  defp query(repo, sql, params, config) do
    opts = repo_opts(sql, config)
    prepared? = Keyword.has_key?(opts, :cache_statement)

    meta =
      config
      |> Map.get(:query_meta, %{})
      |> Map.merge(%{sql: sql, params_count: length(params), prepared: prepared?})

    :telemetry.span([:pgrest, :query], meta, fn ->
      case run(repo, sql, params, opts, config) do
        {:ok, %{num_rows: rows}} = ok ->
          {ok, Map.merge(meta, %{rows: rows, error_kind: nil})}

        {:error, error, kind} ->
          {{:error, error}, Map.merge(meta, %{rows: 0, error_kind: kind})}
      end
    end)
  end

  defp run(repo, sql, params, opts, config) do
    case repo.query(sql, params, opts) do
      {:ok, _result} = ok -> ok
      {:error, exception} -> {:error, translate(exception, config), kind(exception)}
    end
  rescue
    exception -> {:error, translate(exception, config), kind(exception)}
  end

  # Translates an exception; it is reported by module only, never with SQL, parameters or its
  # message.
  defp translate(exception, config) do
    Translate.from_exception_logged(exception, Auth.role(config),
      context: "querying",
      scrub_details?: Map.get(config, :scrub_details?, false)
    )
  end

  defp kind(exception), do: Translate.kind(exception)

  @doc """
  Runs `fun` in a transaction opened with one setup statement, `SELECT set_config(...)`,
  that sets `search_path` (config `:search_path`, a list of schemas), then config
  `:role_settings` (`[{name, value}]`, both bound) and `:gucs`
  (`[{name, value}]`: RLS mode's `role` and `request.*`, `PgRest.Auth`), `transaction_read_only`
  when config `:read_only?` is true, `statement_timeout` when configured and `timezone` for
  a `Prefer: timezone` (config `:timezone`), all transaction-local, every value a bind
  parameter. There is never a separate
  `SET TRANSACTION`: a write under `read_only?` fails with Postgres' `25006`. Config
  `:pre_request` (a `SELECT "schema"."fn"()` statement) then runs before `fun`.

  `fun` returns the response. An `{:error, _}` result, or `prefer.tx == :rollback`, rolls
  the transaction back and still returns the computed result. A database or connection
  failure becomes `{:error, %PgRest.Error{}}`.
  """
  @spec transaction(module(), PgRest.Prefer.t(), (-> result), map()) ::
          result | {:error, Error.t()}
        when result: term()
  def transaction(repo, prefer, fun, config \\ %{}) do
    repo.transaction(
      fn ->
        with :ok <- setup(repo, config),
             :ok <- pre_request(repo, config) do
          finish(repo, prefer, fun.())
        else
          {:error, _} = error -> repo.rollback({:pgrest_rollback, error})
        end
      end,
      repo_opts(nil, config)
    )
    |> case do
      {:ok, result} -> result
      {:error, {:pgrest_rollback, result}} -> result
      {:error, other} -> {:error, translate(other, config)}
    end
  rescue
    exception -> {:error, translate(exception, config)}
  end

  defp finish(repo, prefer, result) do
    if prefer.tx == :rollback or match?({:error, _}, result),
      do: repo.rollback({:pgrest_rollback, result}),
      else: result
  end

  # PgRest's own GUC names are spliced as literals; a role setting's name comes from the catalog
  # and is bound like its value.
  defp setup(repo, config) do
    trailing = [
      {"transaction_read_only", if(Map.get(config, :read_only?), do: "on")},
      {"statement_timeout", Map.get(config, :statement_timeout)},
      {"timezone", Map.get(config, :timezone)}
    ]

    entries =
      constant([{"search_path", search_path(config)}]) ++
        for({name, value} <- Map.get(config, :role_settings, []), do: {:bound, name, value}) ++
        constant(Map.get(config, :gucs, []) ++ trailing)

    {selects, {params, _next}} = Enum.map_reduce(entries, {[], 1}, &set_config/2)
    run_setup(repo, selects, Enum.reverse(params), config)
  end

  defp constant(pairs),
    do: for({name, value} <- pairs, value != nil, do: {:constant, name, value})

  defp set_config({:constant, name, value}, {params, n}),
    do: {"set_config('#{name}', $#{n}, true)", {[value | params], n + 1}}

  defp set_config({:bound, name, value}, {params, n}),
    do: {"set_config($#{n}, $#{n + 1}, true)", {[value, name | params], n + 2}}

  defp pre_request(repo, %{pre_request: sql} = config) when is_binary(sql) do
    with {:ok, _} <- query(repo, sql, [], config), do: :ok
  end

  defp pre_request(_repo, _config), do: :ok

  defp run_setup(_repo, [], _params, _config), do: :ok

  defp run_setup(repo, selects, params, config) do
    sql = "SELECT " <> Enum.join(selects, ", ")

    with {:ok, _} <- query(repo, sql, params, config), do: :ok
  end

  defp search_path(config) do
    case Map.get(config, :search_path) do
      nil -> nil
      schemas -> Enum.map_join(schemas, ", ", &(&1 |> Builder.ident() |> IO.iodata_to_binary()))
    end
  end
end
