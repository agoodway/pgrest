# Authorization and RLS

Use resource `allow:`, `readable:` and `writable:` for static permissions,
`scope/2` for mandatory row predicates, and a configured `authorization:` module
for request-specific grants. RLS mode additionally enforces database policies.

## Application policies

`authorize(conn, resource_or_function, operation, context)` returns `:ok` or
`{:error, reason}`. It runs for every touched resource, including embeds and
junctions; RPC functions need `:execute` and their result resources need `:read`.
Function targets are `%PgRest.Function{}`; use `schema`/`name` and `params` for
overloads. Introspected functions have `module: nil`. Handle `:execute` and
`:explain` explicitly or deny unhandled operations with a catch-all.
Denials are `42501`: 401 for anonymous requests, 403 otherwise. Without RLS,
`anonymous?: (conn, context -> boolean)` controls that split.

A configured module fails closed. If `authorize/4` is missing, table operations
may fall through to `authorize_query/5`; `:execute` is denied. If the query callback
is missing, `authorize/4` decides. Exporting neither denies everything.

An external deny-by-default policy library can implement the query callback:

```elixir
defmodule MyApp.ApiPolicy do
  @behaviour PgRest.Authorization

  def authorize_query(_conn, resource, operation, query, context) do
    MyApp.Policy.authorized_query(resource, operation, query, context)
  end
end
```

The adapter must return `{:ok, query, columns: ["id", "title"], limit: 20,
aggregates: false, count: false}` for a grant, or `{:error, reason}` for unhandled
operations. `columns:` names physical database columns and intersects resource
allowlists. `select=*` narrows to them; explicitly using a hidden column in a
select, filter or order returns `42501`. `limit:` is per parent, including lateral
embeds, and clamps request limits. `aggregates:` and `count:` default to false.

Both scopes and hook queries are predicate-only: add `where`, `join`, `distinct`.
Hook selects and preloads are stripped; limits, offsets, ordering and grouping
raise. Return a permission `limit:` rather than changing the query limit.
Writes need `:read` for filters, representations, counts, conflict targets and
Location, plus the write-operation grant for payload columns and the check.
PUT always needs `:read`. Table requests, including writes, scrub constraint
details when any node's effective source is narrowed by a non-identity scope or
a narrowing hook, or any column set is restricted.
RPC calls also scrub conservatively whenever a query hook is configured or RLS
mode is enabled, including scalar and void RPC errors.

Execution plans are disabled by default. `plan_enabled:` accepts a boolean or
`(conn, context -> boolean)`. A configured policy must also grant `:explain` on
every touched resource/function; query-hook grants require an explicit three-tuple.
A bare `{:ok, query}` grants reads but denies EXPLAIN; return `{:ok, query, []}`
to grant EXPLAIN explicitly. `context.graph` and `context.plan_enabled` are unstable
planner data; use application keys and documented identity/path fields in policies.
A refused plan is 406 `PGRST107`. Plans can expose bound values.

## Database RLS setup

Provision roles and policies through your application's database setup:

```sql
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE authenticator LOGIN NOINHERIT NOSUPERUSER NOBYPASSRLS;
GRANT anon, authenticated TO authenticator;
GRANT USAGE ON SCHEMA public TO anon, authenticated;
GRANT SELECT ON public.tasks TO anon, authenticated;
ALTER TABLE public.tasks ENABLE ROW LEVEL SECURITY;
```

Add explicit policies and only the grants each role needs; configure the repo's
credentials outside source control. Mount the plug using that repo:

```elixir
forward "/api", PgRest.Plug,
  repo: MyApp.AuthenticatorRepo,
  rls: [
    roles: ["anon", "authenticated"],
    default_role: "anon",
    jwt: {PgRest.JWT.HS256, secret: {:system, "JWT_SECRET"}}
  ]
```

`roles:` is required and includes the default role. Tokens outside the allowlist
are rejected before SQL. A SUPERUSER or BYPASSRLS login refuses requests because
it would defeat policies; `allow_privileged_login: true` is an explicit override
with a warning. The HS256 secret can be an environment tuple, MFA or zero-argument
function, resolved per request. Alternatively `jwt: :context` accepts verified
`context.jwt_claims` from the host. Other signing algorithms need a custom verifier.

RLS setup sets role, claims, method, mount-relative path, headers and cookies in
one transaction-local setup statement. `pre_request:` runs after planning.
`OPTIONS` performs neither SQL nor authorization; CORS belongs to the host app.

## Limits of application policies

Relationship join columns are unchecked: `rel!inner` with a visible-side filter
can reveal a hidden foreign-key value. Restrict relationships or enforce database
privileges when this matters. Uncapped `count=planned|estimated` are planner
estimates, not a confidentiality boundary imposed by hook `limit:`; explicit
permission caps use capped exact totals. PUT/upsert ownership guards see a statement
snapshot: concurrent ownership changes can race the guard. Use RLS and suitable
locking when ownership can change concurrently. `after_load/2` is a transformation,
not an access-control boundary.
