defmodule PgRest.Plug do
  @moduledoc """
  Phoenix Plug that serves registered PgRest resources, PostgREST style.

  ## Usage

      # In your router:
      forward "/api", PgRest.Plug, repo: MyApp.Repo

  Routes are `/<table>` and `/rpc/<function>`. A `POST` is an insert (`PgRest.Write.Insert`), a `PUT`
  a single-row upsert (`PgRest.Write.Put`);
  `PATCH` and `DELETE` act on the rows the query-string filters select (`PgRest.Write.Modify`).
  `/rpc/<function>` calls a registered `PgRest.Function`: `GET`/`HEAD` read-only with the query
  string's arguments, `POST` with the body's (`PgRest.Planner.plan_call/3`). A read (`GET`, `HEAD`) flows
  `PgRest.Request` -> `PgRest.Planner` -> `PgRest.SQL.Read` -> `PgRest.Executor` ->
  `PgRest.Responder`: one SQL statement inside one short transaction.

  ## Options

    * `:repo` (required) - the Ecto repo module
    * `:registry` - the `PgRest.Registry` whose resources the plug serves (default
      `PgRest.Registry`). Requests pick a schema of that registry with `Accept-Profile` (reads)
      or `Content-Profile` (writes); without one they get its default schema.
    * `:context_builder` - `(conn, opts) -> context_map` for the context passed to
      `scope/2`, `after_load/2` and the authorization module (default: the repo plus
      `user_id`, `role`, `tenant_id` and `assigns` from `conn.assigns`). It runs once per
      served request after parsing, with the schema `graph` in `opts`; only RLS mode with
      `jwt: :context` needs it before routing (without `graph`). The plug overrides `repo`,
      `authorization`, `max_limit`, `max_embed_depth`, `aggregates`, `plan_enabled`,
      `count_modes`, `graph` and `authenticated?`; only RLS mode also sets `jwt_claims`
      and `db_role`.
    * `:authorization` - a `PgRest.Authorization` module (default `nil`)
    * `:require_filters_for_mutations` - `true` (default) rejects `PATCH`/`DELETE`
      without a filter
    * `:max_limit` - clamps every node's row count, like PostgREST's `db-max-rows`
      (default `nil`)
    * `:max_embed_depth` - deepest embed nesting (default `8`)
    * `:max_body_bytes` - request body limit (default `8_000_000`)
    * `:max_bulk_rows` - rows accepted in one bulk write (default `10_000`)
    * `:count_modes` - allowed `Prefer: count=` modes (default
      `[:exact, :planned, :estimated]`)
    * `:tx_end` - `:commit` (default) ignores `Prefer: tx=`; `:commit_allow_override`
      honors it
    * `:statement_cache` - `[promote_after: 3, max: 500]` (default) or `false`, see
      `PgRest.StatementCache`
    * `:statement_timeout` - a Postgres interval such as `"5s"` (default `nil`). Set
      inside every request transaction. Reads run in a transaction too, but a dedicated
      repo configured with `parameters: [statement_timeout: ...]` is the belt and braces.
    * `:aggregates` - `true` allows aggregate functions in `select=` (`count()`, `col.sum()`,
      ...), like PostgREST's `db-aggregates-enabled`; `false` (default) makes any aggregate, at
      any depth, a 400 `PGRST123`. The legacy bare `count` column is no aggregate, as upstream.
    * `:plan_enabled` - serves `application/vnd.pgrst.plan` (execution plans, which show bound
      values), like PostgREST's `db-plan-enabled`: `false` (default), `true`, or a
      `(conn, context -> boolean)` function. Otherwise a 406 `PGRST107`. See `PgRest.Negotiate`
      for the `:explain` and `analyze` gates.
    * `:rls` - RLS mode (default `nil`): every request runs as a database role from its JWT,
      with PostgREST's request GUCs and an optional `pre_request` function. See `PgRest.Auth`.
    * `:anonymous?` - without `:rls`, `(conn, context -> boolean)` deciding whether a request is
      anonymous, so a `42501` is a 401, else a 403 (default `&PgRest.Auth.default_anonymous?/2`).

  A request for an operation the resource's `allow:` excludes is a `42501` (401, or 403 when
  authenticated), but only after the query string is parsed (a malformed filter is a `PGRST100`
  first, as in PostgREST); a denied request still reads a bounded body (at most
  `:max_body_bytes`).

  `init/1` validates every key and value and raises `ArgumentError` otherwise.

  `OPTIONS` answers with an `Allow` header and no body, from the registry alone: no transaction,
  no authorization, no `[:pgrest, :query]` event. It checks the profile and the filters and
  order of the query string first, as PostgREST does. `/<table>` allows the methods the
  resource's `allow:` permits (`OPTIONS`, `GET` and `HEAD` always, `PUT` only with a primary
  key), `/` allows `OPTIONS,GET,HEAD`, and `/rpc/<function>` allows `OPTIONS,POST` for a volatile
  function and `OPTIONS,GET,HEAD,POST` otherwise. Any other method is a 405 `PGRST117`.

  ## Differences from PostgREST

    * `OPTIONS` sends no CORS headers: PostgREST always adds `Access-Control-Allow-Origin: *`,
      and `Access-Control-Allow-Methods`/`Max-Age` on a preflight (`Access-Control-Request-*`),
      which PgRest does not treat specially. Serve CORS from the host app.
    * `Allow` is narrowed by `allow:` (a resource with `allow: [:read]` answers
      `OPTIONS,GET,HEAD`); PostgREST has no `allow:` and narrows it for views without the
      matching trigger. The authorization module is not consulted, as in PostgREST.
    * `OPTIONS /rpc/<f>` with `select=` does not resolve the select's embeds:
      `?select=*,nope(*)` is a 200, where PostgREST plans it and answers 400 `PGRST200`.
      `?select=id&clients.id=eq.1` and `?select=&a.b=eq.1` also return 200 instead of
      PostgREST's 400 `PGRST108`: PgRest skips embed-path checks when `select` is present.
  """

  alias Plug.Router.Utils, as: RouterUtils

  @behaviour Plug

  alias PgRest.{
    Auth,
    Authorization,
    Catalog,
    Error,
    Executor,
    Function,
    MediaType,
    Negotiate,
    Options,
    Plan,
    Planner,
    Prefer,
    Registry,
    Request,
    Responder,
    Write
  }

  alias PgRest.Error.Translate
  alias PgRest.Planner.{Params, Tree}
  alias PgRest.Registry.Snapshot
  alias PgRest.Request.Prefer, as: PreferParser
  alias PgRest.Request.QueryString
  alias PgRest.RPC.{Args, Resolver}

  alias PgRest.SQL.Read
  alias PgRest.Write.{Insert, Modify, Put}

  require Logger

  @count_modes [:exact, :planned, :estimated]
  @cache_keys [:promote_after, :max]
  # The `allow:` operation each served method needs. A `PUT` is checked for `:create` here; its
  # `:update` and `:read` are checked by `PgRest.Write.authorize/6`, so do not "fix" it to `:update`.
  @operations %{
    "GET" => :read,
    "HEAD" => :read,
    "POST" => :create,
    "PUT" => :create,
    "PATCH" => :update,
    "DELETE" => :delete
  }
  # What `OPTIONS /<table>` advertises, in PostgREST's order, and the `allow:` operations each
  # method needs. `PUT` also needs a primary key.
  @table_methods [
    {"OPTIONS", []},
    {"GET", []},
    {"HEAD", []},
    {"POST", [:create]},
    {"PUT", [:create, :update]},
    {"PATCH", [:update]},
    {"DELETE", [:delete]}
  ]
  @methods Enum.map(@table_methods, &elem(&1, 0))
  @rpc_methods ~w(GET HEAD POST OPTIONS)
  @read_methods ~w(GET HEAD)

  @doc """
  The default of an option (see the moduledoc), delegated to the shared options table.
  """
  @spec default(atom()) :: term()
  defdelegate default(key), to: Options

  @doc """
  Validates the options and fills the defaults.

  Raises `ArgumentError` for an unknown key or an invalid value.
  """
  @impl Plug
  @spec init(keyword()) :: map()
  def init(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "PgRest.Plug options must be a keyword list")

    Options.validate_keys!(opts, [:repo | Keyword.keys(Options.defaults())], "PgRest.Plug")

    repo =
      Keyword.get(opts, :repo) || raise ArgumentError, "PgRest.Plug requires the :repo option"

    unless is_atom(repo), do: raise(ArgumentError, ":repo must be a module, got #{inspect(repo)}")

    Options.defaults()
    |> Keyword.merge(opts)
    |> Enum.each(fn {key, value} -> validate!(key, value) end)

    Options.defaults()
    |> Keyword.merge(opts)
    |> Keyword.put(:repo, repo)
    |> Map.new()
    |> Map.update!(:rls, &Auth.init/1)
  end

  defp validate!(:registry, value),
    do: check!(:registry, is_atom(value) and not is_nil(value), value)

  defp validate!(:context_builder, value),
    do: check!(:context_builder, is_nil(value) or is_function(value, 2), value)

  defp validate!(:authorization, value),
    do: check!(:authorization, is_nil(value) or is_atom(value), value)

  defp validate!(key, value) when key in [:require_filters_for_mutations, :aggregates],
    do: check!(key, is_boolean(value), value)

  defp validate!(:plan_enabled, value),
    do: check!(:plan_enabled, is_boolean(value) or is_function(value, 2), value)

  defp validate!(:max_limit, value), do: check!(:max_limit, is_nil(value) or pos?(value), value)

  defp validate!(key, value) when key in [:max_embed_depth, :max_body_bytes, :max_bulk_rows],
    do: check!(key, pos?(value), value)

  defp validate!(:count_modes, value),
    do: check!(:count_modes, is_list(value) and Enum.all?(value, &(&1 in @count_modes)), value)

  defp validate!(:tx_end, value),
    do: Options.validate_tx_end!(value)

  defp validate!(:anonymous?, value), do: check!(:anonymous?, is_function(value, 2), value)
  defp validate!(:statement_cache, value), do: validate_cache!(value)
  defp validate!(:statement_timeout, value), do: validate_timeout!(value)
  defp validate!(_key, _value), do: :ok

  defp validate_cache!(false), do: :ok

  defp validate_cache!(value) do
    valid? =
      Keyword.keyword?(value) and Keyword.keys(value) -- @cache_keys == [] and
        Enum.all?(value, fn
          {:promote_after, n} -> is_integer(n) and n >= 0
          {:max, n} -> pos?(n)
        end)

    check!(:statement_cache, valid?, value)
  end

  defp validate_timeout!(nil), do: :ok

  defp validate_timeout!(value) do
    valid? = is_binary(value) and match?({:ok, _ms}, Executor.interval_ms(value))
    check!(:statement_timeout, valid?, value)
  end

  defp pos?(value), do: is_integer(value) and value > 0

  defp check!(_key, true, _value), do: :ok

  defp check!(key, false, value),
    do: raise(ArgumentError, "invalid PgRest.Plug option #{inspect(key)}: #{inspect(value)}")

  @doc """
  Serves `/<table>` requests; any other path is a 404.
  """
  @impl Plug
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, opts) do
    conn = %{conn | path_info: RouterUtils.decode_path_info!(conn)} |> fetch_query_params()

    meta = %{resource: List.first(conn.path_info), method: conn.method}

    :telemetry.span([:pgrest, :request], meta, fn ->
      conn =
        case check_login!(opts) do
          :ok -> safe_route(conn, opts)
          {:error, error} -> Responder.error(conn, error)
        end

      {conn, Map.put(meta, :status, conn.status)}
    end)
  end

  # Hooks (`:context_builder`, `:authorization`) see `conn.query_params`. A malformed query
  # string stays unfetched here and is answered by the request parser as a 400.
  defp fetch_query_params(conn) do
    Plug.Conn.fetch_query_params(conn)
  rescue
    Plug.Conn.InvalidQueryError -> conn
  end

  # RLS mode refuses a repo that logs in as a superuser or `BYPASSRLS` role, before any request
  # is served: a configuration error, raised to the host. Server facts are cached per repo; a
  # failure to read them denies the request before routing.
  defp check_login!(%{rls: nil}), do: :ok

  defp check_login!(%{rls: rls, repo: repo}) do
    case Translate.guard_db(fn -> {:ok, Catalog.facts(repo)} end, :anon) do
      {:ok, facts} -> Auth.check_login!(repo, facts, rls)
      {:error, _} = error -> error
    end
  end

  # In RLS mode the token is verified first, for every route (PostgREST's auth middleware): a
  # bad token is a 401 whatever the path. Anything no handler translated (an exception or an
  # exit from a GenServer or the pool) becomes a PostgREST error body. Only its module name is
  # logged. Before a plan exists the effective source is unknown, so details are scrubbed
  # whenever the resource is scoped or restricts columns.
  defp safe_route(conn, opts), do: rescuing(conn, opts, fn -> authenticated_route(conn, opts) end)

  defp authenticated_route(conn, %{rls: nil} = opts), do: route(conn, opts)

  defp authenticated_route(conn, opts) do
    case authenticate(conn, opts) do
      {:ok, conn} -> rescuing(conn, opts, fn -> route(conn, opts) end)
      {:error, error} -> Responder.error(conn, error)
    end
  end

  defp rescuing(conn, opts, fun) do
    fun.()
  rescue
    exception -> failed(conn, opts, exception)
  catch
    :exit, _reason -> failed(conn, opts, :exit)
  end

  # Resolves who the request runs as, once: before routing in RLS mode, else when a request
  # reaches a resource or a function (so `OPTIONS`, a 404 or a 405 run no host code). The
  # `:context_builder` runs here only when the resolution reads it (`anonymous?`, or
  # `jwt: :context`); otherwise `context/2` runs it.
  defp authenticate(%Plug.Conn{private: %{pgrest_auth: _}} = conn, _opts), do: {:ok, conn}

  defp authenticate(conn, opts) do
    {conn, base} = resolution_context(conn, opts)

    with {:ok, auth} <- Auth.resolve(conn, opts.rls, base, opts.anonymous?),
         do: {:ok, Plug.Conn.put_private(conn, :pgrest_auth, auth)}
  end

  defp resolution_context(conn, %{rls: %{jwt: {_verifier, _opts}}}), do: {conn, %{}}

  defp resolution_context(conn, opts) do
    base = base_context(conn, opts)
    {Plug.Conn.put_private(conn, :pgrest_base_context, base), base}
  end

  defp base_context(conn, %{context_builder: nil}), do: default_context(conn)

  defp base_context(conn, %{context_builder: builder} = opts),
    do: conn |> builder.(opts)

  defp role(conn), do: Auth.role(conn.private[:pgrest_auth])

  defp failed(conn, opts, caught) do
    error =
      Translate.from_exception_logged(caught, role(conn),
        scrub_details?: scrub_details?(conn, opts)
      )

    Responder.error(conn, error)
  end

  defp resource_scrub?(config, opts),
    do:
      Write.scrub_details?(
        config,
        config.custom_scope? or Authorization.query_hook?(opts.authorization) or opts.rls != nil
      )

  # Fails closed: when the registry cannot answer, details are scrubbed.
  defp scrub_details?(%Plug.Conn{path_info: [table]} = conn, opts) do
    case resolve(conn, opts, table) do
      {:ok, _snapshot, _profile, config} ->
        resource_scrub?(config, opts)

      {:error, %Error{code: "PGRST002"}} ->
        true

      {:error, _not_found} ->
        false
    end
  rescue
    _exception -> true
  catch
    :exit, _reason -> true
  end

  # An RPC may read any resource: fail closed.
  defp scrub_details?(%Plug.Conn{path_info: ["rpc", _function]}, _opts), do: true
  defp scrub_details?(_conn, _opts), do: false

  # `OPTIONS` is answered from the registry (below). A method PgRest does not serve is a 405 once
  # the profile resolves, as in PostgREST, and on the root only GET, HEAD and OPTIONS are served;
  # an invalid path and an RPC (`PGRST101`) keep their own errors.
  defp route(%Plug.Conn{method: "OPTIONS", path_info: path} = conn, opts) when length(path) < 2,
    do: options(conn, opts, path)

  defp route(%Plug.Conn{method: method, path_info: path} = conn, opts)
       when (method not in @methods and length(path) < 2) or
              (path == [] and method not in @read_methods),
       do: reject_method(conn, opts, Error.unsupported_method(method))

  defp route(%Plug.Conn{path_info: [table]} = conn, opts), do: serve(conn, opts, table)
  defp route(%Plug.Conn{path_info: ["rpc", name]} = conn, opts), do: serve_rpc(conn, opts, name)
  defp route(conn, _opts), do: Responder.error(conn, Error.invalid_path())

  # The profile resolves first, so a bad one is a 406 whatever the method.
  defp reject_method(conn, opts, %Error{} = rejection) do
    case profile(conn, opts) do
      {:ok, _snapshot, _profile} -> Responder.error(conn, rejection)
      {:error, error} -> Responder.error(conn, error)
    end
  end

  # `OPTIONS` on `/`, `/<table>` or `/rpc/<name>`: the registry answers, so no transaction opens,
  # no authorization runs and no SQL runs (PostgREST runs no query either). Like PostgREST it
  # checks the profile, then the filters and order of the query string (`select` and `limit` are
  # not parsed), then the target. CORS preflight is the host app's job.
  defp options(conn, opts, path) do
    with :ok <- check_introspection(opts),
         {:ok, snapshot, {schema, _negotiated?}} <- profile(conn, opts),
         target = options_target(snapshot, schema, path),
         {:ok, params, groups} <- check_query(conn, target),
         {:ok, methods} <- allowed_methods(target),
         :ok <- check_embeds(target, params, groups) do
      Responder.allow(conn, methods)
    else
      {:error, error} -> Responder.error(conn, error)
    end
  end

  # The root, a resource or a function (resolved without arguments: every query parameter of an
  # `OPTIONS` is a filter), or the lookup error.
  defp options_target(_snapshot, _schema, []), do: {:ok, :root}

  defp options_target(snapshot, schema, [table]),
    do: Snapshot.fetch_resource(snapshot, schema, table)

  defp options_target(snapshot, schema, ["rpc", name]),
    do: Resolver.resolve(snapshot, schema, name, [], :read)

  # The query string must parse before the target is looked up (`/unknown?x=1` is a 400); a
  # resource's custom params are not filters.
  defp check_query(conn, target) do
    with {:ok, params} <- QueryString.parse(conn.query_string),
         pairs = Params.string_pairs(params),
         {:ok, groups} <- Params.group(pairs, custom_params(target)),
         do: {:ok, pairs, groups}
  end

  # Functions declare no custom params.
  defp custom_params({:ok, %{custom_params: params}}), do: params
  defp custom_params(_target), do: []

  # PostgREST plans the call of `OPTIONS /rpc/<f>`. Without `select=` nothing is embedded, so a
  # parameter on an embed path (`?a.b=eq.1`) is `PGRST108`, as for a read. A resource or the
  # root plans nothing.
  defp check_embeds({:ok, %Function{}}, params, groups) do
    if List.keymember?(params, "select", 0),
      do: :ok,
      else: Tree.check_paths(%{children: []}, groups)
  end

  defp check_embeds(_target, _params, _groups), do: :ok

  defp allowed_methods({:error, _error} = error), do: error
  defp allowed_methods({:ok, :root}), do: {:ok, ~w(OPTIONS GET HEAD)}
  defp allowed_methods({:ok, %Function{volatility: :volatile}}), do: {:ok, ~w(OPTIONS POST)}
  defp allowed_methods({:ok, %Function{}}), do: {:ok, ~w(OPTIONS GET HEAD POST)}

  # A method is advertised when the resource's `allow:` has what it needs (the authorization
  # module is not consulted: there is no request context); `PUT` also needs a primary key.
  defp allowed_methods({:ok, %{primary_key: key} = config}) do
    methods =
      for {method, operations} <- @table_methods,
          Enum.all?(operations, &Authorization.allowed?(config, &1)),
          method != "PUT" or key != [] do
        method
      end

    {:ok, methods}
  end

  # The registry snapshot, the request's schema profile (headers only) and the resource it
  # names: read once per request, before the body.
  defp resolve(conn, opts, table) do
    with {:ok, snapshot, {schema, _negotiated?} = profile} <- profile(conn, opts),
         {:ok, config} <- Snapshot.fetch_resource(snapshot, schema, table) do
      {:ok, snapshot, profile, config}
    end
  end

  defp profile(conn, opts) do
    with {:ok, snapshot} <- Registry.snapshot(opts.registry),
         {:ok, profile} <- Request.profile(conn, snapshot),
         do: {:ok, snapshot, profile}
  end

  # `/rpc/<name>`: GET and HEAD call the function read-only, POST with the body's arguments;
  # other methods are PostgREST's 405 `PGRST101`. The function is resolved in the request's
  # schema before anything is authorized, as PostgREST does (so a `PGRST202` hint may name a
  # function the hook would deny); then `:execute` on the function and `:read` on every resource
  # the result and its embeds read are authorized, before any SQL. A JSON array body must hold
  # objects with the same keys (`PGRST102`), checked before resolution.
  defp serve_rpc(%Plug.Conn{method: method} = conn, opts, _name)
       when method not in @rpc_methods,
       do: reject_method(conn, opts, Error.rpc_method_not_allowed(method))

  defp serve_rpc(%Plug.Conn{method: "OPTIONS"} = conn, opts, name),
    do: options(conn, opts, ["rpc", name])

  defp serve_rpc(conn, opts, name) do
    request_opts = Map.put(opts, :rpc_body, rpc_body(conn))

    with :ok <- check_introspection(opts),
         {:ok, snapshot, {schema, _} = profile} <- profile(conn, opts),
         {:ok, request} <- Request.from_conn(conn, Map.put(request_opts, :profile, profile)),
         :ok <- Args.check_body(request),
         invocation = Args.invocation(request),
         {keys, _filters} = Args.split(request, invocation),
         {:ok, function} <- Resolver.resolve(snapshot, schema, name, keys, invocation),
         {:ok, request} <- validate_prefer(request, opts, function),
         opts = Map.put(opts, :graph, Snapshot.graph(snapshot, schema)),
         {:ok, conn} <- authenticate(request.conn, opts) do
      rescuing(conn, opts, fn ->
        request = Request.put_auth(%{request | conn: conn}, conn.private.pgrest_auth)

        opts =
          opts
          |> Map.put(
            :rpc_scrub?,
            resource_scrub?(
              %{custom_scope?: snapshot.scrub_rpc_details?, restricted_columns?: false},
              opts
            )
          )
          |> put_transaction(conn)

        call(conn, opts, function, request)
      end)
    else
      {:error, error} -> Responder.error(conn, error)
    end
  end

  defp rpc_body(conn), do: if(Args.body_media(conn) == :json, do: :json, else: :raw)

  # A call that may write: the transaction is not read-only (a volatile function over POST).
  defp mutating?(%Plan.Read{source: {:call, %Plan.Call{read_only?: read_only?}}}),
    do: not read_only?

  defp call(conn, opts, function, request) do
    {conn, context} = with_context(conn, opts)

    with :ok <- Authorization.check(opts.authorization, conn, function, :execute, context),
         {:ok, _provisional} <- Negotiate.negotiate(request),
         {:ok, plan} <-
           Translate.guard_db(
             fn -> Planner.plan_call(request, function, context) end,
             Auth.role(request),
             scrub_details?: true
           ),
         {:ok, media} <-
           Negotiate.resolve(request, plan, conn, context, mutating?: mutating?(plan)),
         statement = Read.statement(Plan.Read.put_media(plan, media), context),
         exec =
           opts
           |> Executor.config(plan, request.prefer)
           |> Map.update!(:scrub_details?, &(&1 or opts.rpc_scrub?)),
         {:ok, result} <- execute(opts, request, statement, plan, media, exec) do
      respond(conn, result, request, plan, media)
    else
      {:error, error} -> Responder.error(conn, error)
    end
  end

  # The plan text of an explained request, else the read's result.
  defp respond(conn, text, request, _plan, %MediaType{kind: :plan} = media),
    do: Responder.plan(conn, text, request, media)

  defp respond(conn, result, request, plan, media),
    do: Responder.read(conn, result, request, plan, media)

  # The resource is looked up before the body is read (a denied request still reads a bounded
  # body: at most `:max_body_bytes`). `allow:` is checked after the query string, its filter
  # grammar and body are parsed, so malformed request text is a 400 before a missing grant,
  # as in PostgREST (where privileges are checked by the database). Server facts are warmed
  # before any request transaction opens, so they record the login role.
  defp serve(conn, opts, table) do
    with :ok <- check_introspection(opts),
         {:ok, snapshot, {schema, _} = profile, config} <- resolve(conn, opts, table),
         {:ok, request} <- Request.from_conn(conn, Map.put(opts, :profile, profile)),
         {:ok, request} <- validate_prefer(request, opts, nil),
         opts = Map.put(opts, :graph, Snapshot.graph(snapshot, schema)),
         {:ok, conn} <- authenticate(request.conn, opts) do
      rescuing(conn, opts, fn -> serve_authenticated(conn, opts, config, request) end)
    else
      {:error, error} -> Responder.error(conn, error)
    end
  end

  defp serve_authenticated(conn, opts, config, request) do
    request = Request.put_auth(%{request | conn: conn}, conn.private.pgrest_auth)

    case guard(conn.method, config, request) do
      :ok -> dispatch(conn, put_transaction(opts, conn), config, request)
      {:error, error} -> Responder.error(conn, error)
    end
  end

  # The server facts (warmed before any request transaction opens, so they record the login
  # role) decide which `Prefer: timezone` is valid. `handling=strict` makes an invalid
  # preference a 400 `PGRST122`, before anything is authorized or planned. PostgREST raises it
  # later: for a read or a call after planning (once the table or function is found and the
  # select and filters are planned), for a mutation earlier than that. So a read with a bad
  # select and strict invalid preferences is a 400 `PGRST100` there. Strict `max-affected`
  # on a function that returns no set is `PGRST128`.
  defp validate_prefer(%Request{prefer: prefer} = request, opts, function) do
    with {:ok, facts} <-
           Translate.guard_db(fn -> {:ok, Catalog.facts(opts.repo)} end, Auth.role(request)),
         {:ok, prefer} <- PreferParser.validate(prefer, facts),
         :ok <- check_max_affected(prefer, function) do
      {:ok, %{request | prefer: prefer}}
    end
  end

  defp check_max_affected(
         %Prefer{handling: :strict, max_affected: max},
         %Function{returns: %{set?: false}}
       )
       when is_integer(max),
       do: {:error, Error.max_affected_rpc()}

  defp check_max_affected(_prefer, _function), do: :ok

  # The registry's introspection must match how this plug calls functions. Checked against
  # every published snapshot (a reload may change it); it reads two maps. A mismatch is a
  # configuration error: every request fails closed with a 500, and the cause is logged once
  # per snapshot generation: one `:persistent_term` key per registry holds the last logged
  # generation and is rewritten only when the generation changes.
  defp check_introspection(opts) do
    with {:ok, %Snapshot{introspection: introspection} = snapshot} <-
           Registry.snapshot(opts.registry),
         {:error, message} <-
           introspection_mismatch(introspection, Map.get(opts, :rls), opts.authorization) do
      log_mismatch_once(snapshot, opts.registry, message)
      {:error, Error.internal()}
    else
      _ok_or_not_ready -> :ok
    end
  end

  defp log_mismatch_once(%Snapshot{generation: generation}, registry, message) do
    key = {__MODULE__, :introspection_mismatch, registry}

    Options.log_once({:generation, key, generation}, fn ->
      Logger.error("PgRest.Plug: registry #{inspect(registry)} #{message}")
    end)
  end

  # `rls` is the plug's RLS mode (`PgRest.Auth.init/1`, or `nil`).
  defp introspection_mismatch(nil, _rls, _authorization), do: :ok

  # C7: the roles the registry kept functions for are roles this plug may switch to.
  defp introspection_mismatch(%{mode: :rls, as_role: [_ | _] = as_role} = intro, %{} = rls, auth) do
    if as_role -- rls.roles == [] and (is_nil(rls.default_role) or rls.default_role in as_role),
      do: introspection_mismatch(%{intro | as_role: nil}, rls, auth),
      else:
        {:error,
         "introspects functions with mode: :rls as_role: #{inspect(as_role)}, which must be " <>
           "within this plug's rls: roles: #{inspect(rls.roles)} and include its default_role " <>
           "#{inspect(rls.default_role)}"}
  end

  defp introspection_mismatch(%{mode: :rls, filtered?: false}, nil, _authorization) do
    {:error,
     "introspects functions with mode: :rls and no only:/except:, but this plug has no rls: " <>
       "option, so every function would run as the repo role"}
  end

  defp introspection_mismatch(%{authorization: auth}, _rls, plug_auth)
       when not is_nil(auth) and auth != plug_auth do
    {:error,
     "introspects functions for authorization: #{inspect(auth)}, but this plug uses " <>
       "#{inspect(plug_auth)}"}
  end

  defp introspection_mismatch(_introspection, _rls, _authorization), do: :ok

  defp dispatch(conn, opts, config, %Request{method: method} = request)
       when method in @read_methods,
       do: read(conn, opts, config, request)

  defp dispatch(conn, opts, config, %Request{method: "POST"} = request),
    do: write(conn, opts, &Insert.run(&1, opts, config, request, &2))

  defp dispatch(conn, opts, config, %Request{method: "PUT"} = request),
    do: write(conn, opts, &Put.run(&1, opts, config, request, &2))

  defp dispatch(conn, opts, config, %Request{method: "PATCH"} = request),
    do: write(conn, opts, &Modify.run(&1, opts, config, request, &2, :update))

  defp dispatch(conn, opts, config, %Request{method: "DELETE"} = request),
    do: write(conn, opts, &Modify.run(&1, opts, config, request, &2, :delete))

  # Runs a write (`run.(conn, context)`).
  defp write(conn, opts, run) do
    {conn, context} = with_context(conn, opts)
    run.(conn, context)
  end

  # An operation the resource's `allow:` excludes is a missing grant, like Postgres' 42501.
  # Answered once the request text is parsed, before planning; `PgRest.Authorization.check/5`
  # enforces the same rule on every resource the request touches. A method PgRest does not
  # serve never gets here: `route/2` refuses it. PostgREST also parses the select, filter and
  # order grammars before privileges, so a denied request runs the planner's own steps
  # (`PgRest.Planner.Params.parse_select/1` and
  # `group/2`) once more here: a malformed select, filter or order is a 400 `PGRST100`, not a
  # 401. Only a denied request pays for it. Every result shape is matched explicitly, so an
  # unexpected one raises (a 500) instead of letting the request through.
  defp guard(method, config, request) do
    guard_operation(
      config,
      request,
      Authorization.allowed?(config, Map.fetch!(@operations, method))
    )
  end

  defp guard_operation(_config, _request, true), do: :ok

  defp guard_operation(config, request, false) do
    params = Params.string_pairs(request.params)

    with {:ok, _items} <- Params.parse_select(params),
         {:ok, _root} <- Params.root_group(request.params, config.custom_params) do
      {:error, Error.table_denied(config, Auth.role(request))}
    end
  end

  defp read(conn, opts, config, request) do
    {conn, context} = with_context(conn, opts)

    with {:ok, _provisional} <- Negotiate.negotiate(request),
         {:ok, plan} <- plan(request, config.module, context, opts),
         {:ok, media} <- Negotiate.resolve(request, plan, conn, context),
         statement = Read.statement(Plan.Read.put_media(plan, media), context),
         exec = Executor.config(opts, plan, request.prefer),
         {:ok, result} <- execute(opts, request, statement, plan, media, exec) do
      respond(conn, result, request, plan, media)
    else
      {:error, error} -> Responder.error(conn, error)
    end
  end

  # The catalog loads the planner triggers can fail on a connection problem.
  defp plan(request, module, context, opts) do
    Translate.guard_db(
      fn -> Planner.plan_read(request, module, context) end,
      Auth.role(request),
      scrub_details?: resource_scrub?(module.__pgrest_config__(), opts)
    )
  end

  # A plan is the statement explained, in the request's transaction (an `analyze` of a call
  # that writes rolls back with it) and without any of the result checks.
  defp execute(opts, request, statement, _plan, %MediaType{kind: :plan, plan: spec}, exec),
    do: Executor.explain_transaction(opts.repo, request.prefer, statement, spec, exec)

  defp execute(opts, request, statement, plan, media, exec) do
    Executor.transaction(
      opts.repo,
      request.prefer,
      fn ->
        with {:ok, result} <- Executor.read(opts.repo, statement, plan.count, plan, exec),
             :ok <- ensure_call_limits(request.prefer, plan, media, result),
             do: {:ok, result}
      end,
      exec
    )
  end

  # A function call's result is checked inside the transaction, so a failure rolls the call's
  # side effects back (a mutation's checks are in `PgRest.Write`): the object media type needs
  # one row of a set (PGRST116), then `max-affected` bounds the rows (PGRST124).
  defp ensure_call_limits(
         prefer,
         %Plan.Read{source: {:call, %Plan.Call{function: %{returns: %{set?: true}}}}},
         media,
         result
       ) do
    with :ok <- Executor.ensure_single(media, result),
         do: Executor.ensure_max_affected(prefer, result.page_total)
  end

  defp ensure_call_limits(prefer, %Plan.Read{source: {:call, _call}}, _media, result),
    do: Executor.ensure_max_affected(prefer, result.page_total)

  defp ensure_call_limits(_prefer, _plan, _media, _result), do: :ok

  # The request transaction's role, RLS GUCs, read-only flag and `pre_request` (`PgRest.Auth`),
  # merged into every `PgRest.Executor.config/3`.
  defp put_transaction(opts, conn),
    do:
      Map.put(
        opts,
        :transaction,
        Auth.transaction(conn, conn.private.pgrest_auth, opts.rls, Catalog.facts(opts.repo))
      )

  # The planner context, also stored in `conn.private[:pgrest_context]` for `after_load`.
  defp with_context(conn, opts) do
    context = context(conn, opts)
    {Plug.Conn.put_private(conn, :pgrest_context, context), context}
  end

  # The keys merged below override a builder's; keep the `:context_builder` bullet of the
  # moduledoc and the `context_builder` row of docs/guides/configuration.md in step.
  defp context(conn, opts) do
    auth = conn.private.pgrest_auth
    base = Map.get_lazy(conn.private, :pgrest_base_context, fn -> base_context(conn, opts) end)

    base
    |> Map.merge(%{
      repo: opts.repo,
      authorization: opts.authorization,
      max_limit: opts.max_limit,
      max_embed_depth: opts.max_embed_depth,
      aggregates: opts.aggregates,
      plan_enabled: opts.plan_enabled,
      count_modes: opts.count_modes,
      graph: opts.graph,
      authenticated?: auth.authenticated?
    })
    |> Map.merge(rls_context(opts.rls, auth))
  end

  # Outside RLS mode `jwt_claims` and `db_role` stay the builder's.
  defp rls_context(nil, _auth), do: %{}
  defp rls_context(_rls, auth), do: %{jwt_claims: auth.claims, db_role: auth.db_role}

  defp default_context(conn) do
    assigns = conn.assigns

    %{
      user_id: Map.get(assigns, :user_id),
      role: Map.get(assigns, :role),
      tenant_id: Map.get(assigns, :tenant_id),
      assigns: assigns
    }
  end
end
