defmodule PgRest.Compat.SupabaseRouter do
  @moduledoc """
  Test router for the Supabase-shaped fixture (`pgrest_supabase`): `PgRest.Plug` in RLS mode
  against `PgRest.Compat.AuthenticatorRepo`, like the Supabase PostgREST service (login
  `authenticator`, anon role `anon`, the shared JWT secret, `public.check_request` as
  pre-request), with the scenario's plug options merged in.

  It serves the `PgRest.Compat.SupabaseRegistry` registry (`PgRest.Compat.Scenario.registries/0`),
  which exposes `public` and `personal`. The JWT secret is read from `PGREST_COMPAT_JWT_SECRET`
  (set by `test/test_helper.exs`) on each request.
  """

  @behaviour Plug

  alias PgRest.Compat.Router

  @base_opts [
    repo: PgRest.Compat.AuthenticatorRepo,
    registry: PgRest.Compat.SupabaseRegistry,
    tx_end: :commit_allow_override,
    aggregates: true,
    plan_enabled: true,
    rls: [
      roles: ["anon", "authenticated", "service_role"],
      jwt: {PgRest.JWT.HS256, secret: {:system, "PGREST_COMPAT_JWT_SECRET"}},
      pre_request: "public.check_request"
    ]
  ]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts), do: Router.dispatch(conn, @base_opts)
end

defmodule PgRest.Compat.SupabaseScopeRouter do
  @moduledoc false
  @behaviour Plug
  alias PgRest.Auth
  alias PgRest.Compat.Router
  @impl true
  def init(opts), do: opts
  @impl true
  def call(conn, _opts) do
    Router.dispatch(conn,
      repo: PgRest.Compat.SupabaseRepo,
      registry: PgRest.Compat.SupabaseScopeRegistry,
      tx_end: :commit_allow_override,
      authorization: PgRest.Compat.SupabaseScopeAuthorization,
      context_builder: &context/2,
      aggregates: true,
      plan_enabled: true
    )
  end

  @doc false
  @spec context(Plug.Conn.t(), map()) :: map()
  def context(conn, _opts) do
    rls =
      Auth.init(
        roles: ["anon", "authenticated", "service_role"],
        jwt: {PgRest.JWT.HS256, secret: {:system, "PGREST_COMPAT_JWT_SECRET"}}
      )

    case Auth.resolve(conn, rls, %{}, &Auth.default_anonymous?/2) do
      {:ok, auth} -> %{jwt_claims: auth.claims, role: auth.db_role}
      {:error, error} -> raise error
    end
  end
end
