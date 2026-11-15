defmodule PgRest.Authorization do
  @moduledoc """
  Behavior for pluggable authorization in PgRest.

  Implement this behavior to add runtime permission checks to your PgRest resources.

  ## Usage

      defmodule MyApp.PgRestAuth do
        @behaviour PgRest.Authorization

        @impl true
        def authorize(_conn, _resource_module, :read, _context), do: :ok
        def authorize(_conn, _resource_module, _op, %{role: :admin}), do: :ok
        def authorize(_conn, _resource_module, _op, _context), do: {:error, "Forbidden"}
      end

  Then configure in your router:

      forward "/api", PgRest.Plug,
        repo: MyApp.Repo,
        authorization: MyApp.PgRestAuth

  `authorize_query/5` receives the base scope after `authorize/4` permits the operation.
  It returns `{:ok, query}` or `{:ok, query, opts}`. PgRest intersects the query with the
  base scope. `columns:` names physical columns; `limit:` caps rows per parent.
  `aggregates:` and `count:` default to false; columns default to `:all`, limit to `nil`.
  A query-only module can grant table operations; functions still require `authorize/4`.
  Function targets are `%PgRest.Function{}`: match `schema`/`name` (and `params` for
  overloads), not `module`, which is nil for introspected functions.
  `context.graph` and `context.plan_enabled` are unstable planner data; callbacks
  should use their own application keys and the documented identity/path fields.
  Both callbacks receive `context.path` (embed output names) and `context.root?`;
  a junction appends its table name to the embed path.

  ## Differences from PostgREST

  Query policies extend database privileges/RLS: stars expose permitted columns only,
  and writes use distinct read and payload policies. Filters, counts, representations
  and named conflict targets or Location require a read grant as well as the write grant.
  `GET /projects?select=*` under `columns: ["id"]` returns `[{"id":1}]`;
  PostgREST returns every granted column.

  RPC `result_scope: :none` trusts the function for rows only: query-hook denials,
  column grants, count/aggregate grants and permission limits still apply without
  keyed row matching. PostgREST relies on function/database privileges and RLS.

  A hook's bare `{:ok, query}` denies EXPLAIN; an explicit three-tuple grants it.
  EXPLAIN is an admission check on the actual authorized statement, not a second
  narrowing pass. PostgREST uses privileges and db-plan-enabled instead.
  """

  alias PgRest.{Auth, Error, Options}
  alias PgRest.Authorization.{Apply, State}
  alias PgRest.Planner.Result
  alias PgRest.SQL.ScopedSource

  @typedoc """
  `:execute` is asked for a `PgRest.Function` before an RPC call is planned; `:explain` for a
  query plan response. The others are asked for resources.
  """
  @type operation :: :read | :create | :update | :delete | :execute | :explain

  @callback authorize(
              conn :: Plug.Conn.t(),
              resource_module :: module() | PgRest.Function.t(),
              operation :: operation(),
              context :: map()
            ) :: :ok | {:error, String.t() | map()}

  @type query_operation :: :read | :create | :update | :delete | :explain
  @type query_options :: [
          columns: :all | [String.t()],
          limit: pos_integer() | nil,
          aggregates: boolean(),
          count: boolean()
        ]
  @callback authorize_query(Plug.Conn.t(), module(), query_operation(), Ecto.Query.t(), map()) ::
              {:ok, Ecto.Query.t()} | {:ok, Ecto.Query.t(), query_options()} | {:error, term()}
  @optional_callbacks authorize: 4, authorize_query: 5

  @doc "Whether a configured policy exports the query-narrowing callback."
  @spec query_hook?(module() | nil) :: boolean()
  def query_hook?(nil), do: false
  def query_hook?(auth), do: Options.exports?(auth, :authorize_query, 5)

  @doc """
  The single authorization gate: `:ok`, or the `42501` PgRest answers with when the
  resource's `allow:` list excludes `operation` (a missing grant) or `auth` (when not nil)
  denies. `allow:` is checked first, so the hook never sees an operation the resource does not
  expose. A `%PgRest.Function{}` has no `allow:` list; only the hook decides, and a denial names
  the function.

  It runs for every resource a request touches: the root and each embed, spread and
  many-to-many junction (`:read`), the write's own operations, `:read` on a write's target
  when its filters, count, representation or `Location` read rows, `:execute` on an RPC's
  function and `:read` on the resources its result and embeds read.

  Missing callbacks deny. A query-only policy delegates table operations to
  `PgRest.Authorization.Apply`; functions require `authorize/4`. A query hook's
  `:explain` grant must be a three-tuple and receives the effective source query.
  Write row checks use the write-operation query; read policies protect targeting and output.
  """
  @spec check(
          module() | nil,
          Plug.Conn.t(),
          module() | PgRest.Function.t(),
          operation(),
          map(),
          State.t()
        ) ::
          :ok | {:error, Error.t()}
  def check(auth, conn, target, operation, context, state \\ State.empty()) do
    context =
      context |> Map.put_new(:path, []) |> Map.put_new(:root?, true)

    check_target(auth, conn, target, operation, context, state)
  end

  defp check_target(nil, _conn, %PgRest.Function{}, _op, _ctx, _state), do: :ok

  defp check_target(auth, conn, %PgRest.Function{name: name} = f, op, ctx, _state),
    do: hook(auth, conn, f, op, ctx, Error.permission_denied(:function, name, Auth.role(ctx)))

  defp check_target(auth, conn, resource, op, ctx, state),
    do:
      resource_gate(
        allowed?(resource.__pgrest_config__(), op),
        auth,
        conn,
        resource,
        op,
        ctx,
        state
      )

  defp resource_gate(false, _auth, _conn, resource, _op, ctx, _state),
    do: {:error, Error.table_denied(resource, ctx)}

  defp resource_gate(true, nil, _conn, _resource, _op, _ctx, _state), do: :ok

  defp resource_gate(true, auth, conn, resource, op, ctx, state) do
    denied = Error.table_denied(resource, ctx)

    with :ok <- hook(auth, conn, resource, op, ctx, denied),
         do: explain_gate(op, auth, conn, resource, ctx, state, denied)
  end

  defp hook(auth, conn, target, op, ctx, denied) do
    if hook_allows?(auth, conn, target, op, ctx), do: :ok, else: {:error, denied}
  end

  defp explain_gate(:explain, auth, conn, resource, ctx, state, denied) do
    if not query_hook?(auth) or query_allows?(auth, conn, resource, ctx, state),
      do: :ok,
      else: {:error, denied}
  end

  defp explain_gate(_op, _auth, _conn, _resource, _ctx, _state, _denied), do: :ok

  @query_operations [:read, :create, :update, :delete, :explain]
  defp hook_allows?(auth, conn, target, op, ctx) do
    if Options.exports?(auth, :authorize, 4),
      do: auth.authorize(conn, target, op, ctx) == :ok,
      else: query_only_allows?(target, op, auth)
  end

  defp query_only_allows?(%PgRest.Function{}, _op, _auth), do: false
  defp query_only_allows?(_resource, op, auth) when op in @query_operations, do: query_hook?(auth)
  defp query_only_allows?(_resource, _op, _auth), do: false

  defp query_allows?(auth, conn, resource, context, state) do
    case explain_source(state, resource, context) do
      %Ecto.Query{} = base -> Apply.explain_granted?(auth, conn, resource, base, context)
      _error -> false
    end
  end

  defp explain_source(%State{source_query: nil}, resource, ctx),
    do: ScopedSource.base_query(resource, ctx, [])

  defp explain_source(%State{source_query: query}, _resource, _ctx), do: query

  @doc """
  Whether `:explain` is allowed (`check/5`) on every one of `targets`, resource modules and the
  `PgRest.Function` of a call: the gate of the `application/vnd.pgrst.plan` media type.
  """
  @spec explain?(
          module() | nil,
          Plug.Conn.t(),
          [module() | PgRest.Function.t()],
          map(),
          State.t()
        ) :: boolean()
  def explain?(auth, conn, targets, context, state \\ State.empty()) do
    targets
    |> Enum.flat_map(&explain_nodes(&1, state.nodes))
    |> Result.all_ok(fn {target, path, query} ->
      ctx = Map.merge(context, %{path: path, root?: path == []})
      check(auth, conn, target, :explain, ctx, %{state | source_query: query})
    end)
    |> Kernel.==(:ok)
  end

  defp explain_nodes(target, nodes) do
    case Enum.filter(nodes, fn {node, _path, _query} -> node == target end) do
      [] -> [{target, [], nil}]
      matching -> matching
    end
  end

  @doc """
  Whether the resource's `allow:` list (from its `__pgrest_config__/0`) admits `operation`.
  `:explain` is always admitted: it is decided by the hook alone.
  """
  @spec allowed?(map(), operation()) :: boolean()
  def allowed?(_config, :explain), do: true

  def allowed?(%{allow: operations}, operation) when is_list(operations),
    do: operation in operations

  def allowed?(_config, _operation), do: true
end
