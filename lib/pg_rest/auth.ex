defmodule PgRest.Auth do
  @moduledoc """
  Who a request runs as: RLS mode's bearer token, role allowlist and request GUCs
  (`PgRest.Plug`'s `rls:` option), or, without it, the `anonymous?` predicate.

  ## RLS mode

  `rls:` makes every request run as a database role, as PostgREST does:

      forward "/api", PgRest.Plug,
        repo: MyApp.AuthenticatorRepo,
        rls: [
          roles: ["anon", "authenticated", "service_role"],
          jwt: {PgRest.JWT.HS256, secret: {:system, "JWT_SECRET"}},
          pre_request: "public.check_request"
        ]

    1. No `Authorization: Bearer` header: the `default_role` (`"anon"`; `nil` makes the request
       a 401 `PGRST302`). A token is verified by `jwt:` (`{PgRest.JWT.HS256, secret: ...}`, or
       `:context` to take the claims a `:context_builder` verified from `context[:jwt_claims]`).
    2. The role is the claim at `role_claim` (`"role"`, or a key path such as
       `["app_metadata", "role"]`), else `default_role`. A role outside the `roles:` allowlist
       is a 401 `22023` `role "<role>" does not exist`, before any SQL runs.
    3. The request transaction's setup statement sets the role's `ALTER ROLE ... SET` settings
       (database-wide, of the roles the login is a member of, as PostgREST reads them), then
       `role`, `request.jwt.claims` (the claims with `role` inserted), `request.method`,
       `request.path`, `request.headers` (lowercase names, no `Cookie`; a repeated header keeps
       its last value where the adapter keeps duplicates, as Plug.Test and Bandit do, while
       Plug.Cowboy joins them with `", "`) and `request.cookies`; reads run in a read-only
       transaction. `pre_request: "schema.fn"` is then called in the same transaction.

  A request is authenticated when its role is not `default_role` (PostgREST's
  `authRole /= anonRole`): a `42501` is then a 403 instead of a 401.

  `ALTER ROLE ... SET` changes need a restart or `PgRest.Catalog.forget/1` for the plug's repo.

  The repo must log in as a role that is neither superuser nor `BYPASSRLS` (a `NOINHERIT`
  authenticator granted the API roles): otherwise every request raises `ArgumentError`, unless
  `allow_privileged_login: true`, which logs a warning once per repo instead.

  ## Differences from PostgREST

    * Roles are an allowlist: a token naming `none`, `postgres` or any role outside `roles:` is
      a 401 `22023`. PostgREST switches to any role the authenticator may assume
      (`role: "none"` runs as the authenticator; `role: "postgres"` is a 403 `42501`
      `permission denied to set role`).
    * `request.path` is relative to the plug's mount (`forward "/api"` sees `/rls_notes`);
      PostgREST's is the full request path.
    * `pre_request` runs after PgRest has planned the request, so an error found while planning
      (an unknown column) answers before the function's own. PostgREST calls it before the
      database sees the query: `select=nope` with a pre-request that raises gets its `P0001`.
    * A superuser or `BYPASSRLS` login raises (see above); PostgREST serves it.
    * A role's `default_transaction_isolation` setting is not applied; PostgREST opens that
      role's transactions at that isolation level. PgRest's run at the server default.
  """

  alias PgRest.{Error, Options}
  alias PgRest.SQL.Builder

  require Logger

  @keys [:roles, :role_claim, :default_role, :jwt, :pre_request, :allow_privileged_login]
  @pseudo_roles ~w(none session_user current_user public)

  @type rls :: %{
          roles: [String.t()],
          role_claim: [String.t()],
          default_role: String.t() | nil,
          jwt: {module(), keyword()} | :context,
          pre_request: String.t() | nil,
          allow_privileged_login: boolean()
        }

  @type t :: %{claims: map(), db_role: String.t() | nil, authenticated?: boolean()}

  @doc """
  Validates the `rls:` plug option and fills its defaults (`role_claim: "role"`,
  `default_role: "anon"`, `pre_request: nil`, `allow_privileged_login: false`). `nil` (no RLS
  mode) stays `nil`. Raises `ArgumentError`.
  """
  @spec init(keyword() | nil) :: rls() | nil
  def init(nil), do: nil

  def init(opts) when is_list(opts) do
    unless Keyword.keyword?(opts), do: invalid!("must be a keyword list")
    Options.validate_keys!(opts, @keys, "PgRest.Plug :rls")

    opts =
      Keyword.merge(
        [
          role_claim: "role",
          default_role: "anon",
          pre_request: nil,
          allow_privileged_login: false
        ],
        opts
      )

    roles = roles!(Keyword.get(opts, :roles))

    %{
      roles: roles,
      role_claim: role_claim!(opts[:role_claim]),
      default_role: default_role!(opts[:default_role], roles),
      jwt: jwt!(Keyword.get(opts, :jwt)),
      pre_request: pre_request!(opts[:pre_request]),
      allow_privileged_login: privileged!(opts[:allow_privileged_login])
    }
  end

  # Never inspected: the value may hold a secret.
  def init(_other), do: invalid!("must be a keyword list or nil")

  defp roles!(roles) do
    unless Options.strings?(roles) and roles != [],
      do: invalid!("requires roles:, a non-empty list of role names (the allowlist)")

    case Enum.filter(roles, &(&1 in @pseudo_roles)) do
      [] -> roles
      pseudo -> invalid!("roles: may not contain #{Enum.join(pseudo, ", ")}")
    end
  end

  defp role_claim!(claim) when is_binary(claim), do: [claim]

  defp role_claim!(path) do
    if Options.strings?(path) and path != [],
      do: path,
      else: invalid!("role_claim: must be a claim name or a non-empty key path")
  end

  defp default_role!(nil, _roles), do: nil

  defp default_role!(role, roles) do
    if role in roles,
      do: role,
      else: invalid!("default_role: #{inspect(role)} must be nil or one of roles:")
  end

  defp jwt!(:context), do: :context

  defp jwt!({module, opts}) when is_atom(module) and is_list(opts) do
    unless Options.exports?(module, :verify, 2),
      do: invalid!("jwt: #{inspect(module)} does not implement PgRest.JWT.Verifier")

    if Options.exports?(module, :init, 1), do: {module, module.init(opts)}, else: {module, opts}
  end

  defp jwt!(_other), do: invalid!("requires jwt: {verifier_module, opts} or :context")

  defp pre_request!(nil), do: nil

  defp pre_request!(name) when is_binary(name) do
    case String.split(name, ".", parts: 2) do
      [schema, function] when schema != "" and function != "" ->
        IO.iodata_to_binary([
          "SELECT ",
          Builder.ident(schema),
          ".",
          Builder.ident(function),
          "()"
        ])

      _ ->
        invalid!("pre_request: must be \"schema.function\", got #{inspect(name)}")
    end
  end

  defp pre_request!(other), do: invalid!("pre_request: must be a string, got #{inspect(other)}")

  defp privileged!(value) when is_boolean(value), do: value

  defp privileged!(other),
    do: invalid!("allow_privileged_login: must be a boolean, got #{inspect(other)}")

  defp invalid!(message), do: raise(ArgumentError, "PgRest.Plug :rls " <> message)

  @doc """
  Resolves who `conn` runs as. In RLS mode (`rls` from `init/1`), from the bearer token (see the
  moduledoc); otherwise `claims` are empty, `db_role` is `nil` and the request is authenticated
  unless `anonymous?.(conn, context)`.
  """
  @spec resolve(Plug.Conn.t(), rls() | nil, map(), (Plug.Conn.t(), map() -> boolean())) ::
          {:ok, t()} | {:error, Error.t()}
  def resolve(conn, nil, context, anonymous?),
    do: {:ok, %{anonymous() | authenticated?: not anonymous?.(conn, context)}}

  def resolve(conn, rls, context, _anonymous?) do
    with {:ok, claims} <- claims(conn, rls.jwt, context),
         {:ok, role} <- claim_role(claims, rls),
         :ok <- allowed(role, rls.roles) do
      {:ok,
       %{
         claims: Map.put(claims, "role", role),
         db_role: role,
         authenticated?: role != rls.default_role
       }}
    end
  end

  defp claims(_conn, :context, context), do: context_claims(Map.get(context, :jwt_claims))

  defp claims(conn, {module, opts}, _context) do
    case bearer(conn) do
      nil -> {:ok, %{}}
      token -> module.verify(token, opts)
    end
  end

  defp context_claims(nil), do: {:ok, %{}}
  defp context_claims(%{} = claims), do: {:ok, claims}

  defp context_claims(_other) do
    Logger.error("PgRest.Auth: jwt: :context needs context[:jwt_claims] to be a map or nil")
    {:error, Error.internal()}
  end

  # PostgREST (WAI's `extractBearerAuth`): the first `Authorization` header, a case-insensitive
  # `bearer` scheme up to the first whitespace, then the token with leading whitespace dropped.
  defp bearer(conn) do
    with [value | _] <- Plug.Conn.get_req_header(conn, "authorization"),
         [scheme | rest] <- String.split(value, ~r/\s/, parts: 2),
         "bearer" <- String.downcase(scheme) do
      rest |> List.first("") |> String.trim_leading()
    else
      _ -> nil
    end
  end

  # A claim that is not a string is used as its JSON text, as PostgREST does.
  defp claim_role(claims, %{role_claim: path, default_role: default}) do
    case {get_in_path(claims, path), default} do
      {:error, nil} -> {:error, Error.token_required()}
      {:error, default} -> {:ok, default}
      {{:ok, role}, _default} when is_binary(role) -> {:ok, role}
      {{:ok, value}, _default} -> {:ok, Jason.encode!(value)}
    end
  end

  defp get_in_path(value, []), do: {:ok, value}

  defp get_in_path(%{} = map, [key | rest]) do
    case Map.fetch(map, key) do
      {:ok, value} -> get_in_path(value, rest)
      :error -> :error
    end
  end

  defp get_in_path(_value, _path), do: :error

  defp allowed(role, roles),
    do: if(role in roles, do: :ok, else: {:error, Error.unknown_role(role)})

  @doc "An anonymous resolution without RLS mode: no claims, no role."
  @spec anonymous() :: t()
  def anonymous, do: %{claims: %{}, db_role: nil, authenticated?: false}

  @doc """
  The default `anonymous?` predicate of non-RLS mode: whether `context[:role]` (the default
  context reads it from `conn.assigns`) is `nil`, `:anon` or `"anon"`.
  """
  @spec default_anonymous?(Plug.Conn.t(), map()) :: boolean()
  def default_anonymous?(_conn, context), do: Map.get(context, :role) in [nil, :anon, "anon"]

  @doc """
  The role `PgRest.Error` constructors and `PgRest.Error.Translate` take, from anything that
  carries `authenticated?` (a resolution, a request, a context or an executor config).
  """
  @spec role(map() | nil) :: :anon | :authenticated
  def role(%{authenticated?: true}), do: :authenticated
  def role(_anonymous), do: :anon

  @doc """
  What the request transaction needs from an RLS-mode request: the role's `ALTER ROLE` settings
  (`PgRest.Catalog.Facts`, set before the role, as PostgREST does), the setup statement's GUCs
  in PostgREST's order, whether a read is read-only, and the `pre_request` call. Without RLS
  mode only `authenticated?` is set (for error statuses).
  """
  @spec transaction(Plug.Conn.t(), t(), rls() | nil, PgRest.Catalog.Facts.t()) :: map()
  def transaction(_conn, auth, nil, _facts), do: %{authenticated?: auth.authenticated?}

  def transaction(conn, auth, rls, facts) do
    conn = Plug.Conn.fetch_cookies(conn)

    %{
      authenticated?: auth.authenticated?,
      role_settings: Map.get(facts.role_settings, auth.db_role, []),
      read_only?: conn.method in ["GET", "HEAD"],
      pre_request: rls.pre_request,
      gucs: [
        {"role", auth.db_role},
        {"request.jwt.claims", Jason.encode!(auth.claims)},
        {"request.method", conn.method},
        {"request.path", "/" <> Enum.join(conn.path_info, "/")},
        {"request.headers", Jason.encode!(headers(conn.req_headers))},
        {"request.cookies", Jason.encode!(conn.req_cookies)}
      ]
    }
  end

  # PostgREST builds the object with `HM.fromList`: the last of a repeated header wins.
  defp headers(req_headers) do
    for {name, value} <- req_headers,
        name != "cookie",
        into: %{},
        do: {String.downcase(name), value}
  end

  @doc """
  Raises when RLS mode's repo logs in as a superuser or `BYPASSRLS` role (from
  `PgRest.Catalog.facts/1`), unless `allow_privileged_login: true`, which logs the same text as
  a warning once per repo.
  """
  @spec check_login!(module(), PgRest.Catalog.Facts.t(), rls()) :: :ok
  def check_login!(_repo, %{bypasses_rls?: false}, _rls), do: :ok

  def check_login!(repo, _facts, %{allow_privileged_login: false}),
    do: raise(ArgumentError, privileged_message(repo))

  def check_login!(repo, _facts, %{allow_privileged_login: true}) do
    # Under the catalog's namespace, so `PgRest.Catalog.forget/1` resets it with the facts.
    key = {PgRest.Catalog, repo, :privileged_login, :warned}

    Options.log_once(key, fn -> Logger.warning(privileged_message(repo)) end)

    :ok
  end

  defp privileged_message(repo) do
    "PgRest RLS mode: repo #{inspect(repo)} logs in as a superuser or BYPASSRLS role; a token " <>
      "role claim or RESET ROLE would regain full access. Use a NOINHERIT authenticator role, " <>
      "or pass allow_privileged_login: true"
  end
end
