# Configuration

```elixir
forward "/api", PgRest.Plug,
  repo: MyApp.Repo,
  max_limit: 1000,
  tx_end: :commit
```

`init/1` validates every key and raises `ArgumentError` for an unknown key or a bad value.

## Plug options

| Option | Default | Effect |
|---|---|---|
| `repo` | required | the Ecto repo module |
| `registry` | `PgRest.Registry` | the `PgRest.Registry` this plug serves (see `name:` on the registry) |
| `context_builder` | `nil` | `(conn, opts) -> map` for `scope/2`, `handle_param/4`, `changeset/3`, `after_load/2` and authorization. Default: `user_id`, `role`, `tenant_id` and `assigns` from `conn.assigns`. Runs once for a served request after parsing, with `opts.graph`; only RLS mode with `jwt: :context` runs it before routing (without `graph`). The plug overrides `repo`, `authorization`, `max_limit`, `max_embed_depth`, `aggregates`, `plan_enabled`, `count_modes`, `graph` and `authenticated?`; only RLS mode also sets `jwt_claims` and `db_role` |
| `authorization` | `nil` | a `PgRest.Authorization` module, asked for **every** resource a request touches (root, embeds, spreads, junctions). Writes also ask for `:read`, because filters (custom params included), counts, `RETURNING` and `Location` are a read channel. Any `{:error, _}` is a `42501`: 401 for anonymous requests (`rls:` default role, or `anonymous?`), 403 otherwise. A resource's `allow:` list is checked first, on the same resources |
| `aggregates` | `false` | serves aggregate functions (PostgREST's `db-aggregates-enabled`); otherwise `PGRST123` |
| `plan_enabled` | `false` | serves `Accept: application/vnd.pgrst.plan` (PostgREST's `db-plan-enabled`): `true`, or `(conn, context -> boolean)` per request. A plan shows bound values, so enable it for trusted callers only. With `authorization`, `:explain` must be allowed on every resource touched, and `options=analyze` of a write needs `Prefer: tx=rollback` honoured (a rollback does not undo sequences or effects outside the transaction). Otherwise a 406 `PGRST107`, whatever the reason |
| `require_filters_for_mutations` | `true` | `PATCH`/`DELETE` without a filter fail with 400 `21000`, like Supabase's `pg-safeupdate`. `false` is plain PostgREST: no filter updates or deletes every row |
| `max_limit` | `nil` | clamps the root and every embed with `LEAST`, like `db-max-rows` |
| `max_embed_depth` | `8` | deeper select trees are a 400 (`embedding depth exceeds 8`) |
| `max_body_bytes` | `8_000_000` | a larger body is a 413 (`54000`) when PgRest reads the body itself or through `PgRest.BodyReader`. On the plain `body_params` path `Plug.Parsers`' own `:length` governs: set it to at most `max_body_bytes` (that bounds memory); `PgRest.BodyReader` adds the PgRest 413 shape |
| `max_bulk_rows` | `10_000` | more rows in one write payload is a 413 (`54000`) |
| `count_modes` | `[:exact, :planned, :estimated]` | a `Prefer: count=` mode outside the list is a 400 |
| `tx_end` | `:commit` | `:commit_allow_override` honours `Prefer: tx=rollback`; under `:commit`, `tx=` is ignored and not echoed (PostgREST `db-tx-end` default) |
| `statement_cache` | `[promote_after: 3, max: 500]` | bounded named prepared statements; `false` disables it |
| `statement_timeout` | `nil` | a Postgres interval such as `"5s"` |
| `rls` | `nil` | RLS mode: each request runs as the database role its JWT names (see below) |
| `anonymous?` | `&PgRest.Auth.default_anonymous?/2` | without `rls`, `(conn, context -> boolean)`: whether a request is anonymous (a `42501` is then a 401, else a 403). The default checks `context.role` for `nil`, `:anon` or `"anon"` |

A policy may export `authorize_query/5` to intersect row scopes and column permissions.
Its `columns:` uses physical names; `limit:` caps rows per parent, including aggregate
inputs and totals. `aggregates:` and `count:` default to false. Writes intersect payload
columns with the write-operation grant and need a separate read grant for filters, counts,
representations, named conflict targets or Location. Explicit virtual writable inputs use
their field names in the grant and reach the changeset without becoming SQL columns.
See `PgRest.Authorization`.

## RLS mode

```elixir
forward "/api", PgRest.Plug,
  repo: MyApp.AuthenticatorRepo,
  rls: [
    roles: ["anon", "authenticated", "service_role"],
    jwt: {PgRest.JWT.HS256, secret: {:system, "JWT_SECRET"}},
    pre_request: "public.check_request"
  ]
```

Like PostgREST: the bearer token's `role` claim (`role_claim:`, a name or key path) picks the role, `default_role:` (`"anon"`) serves requests without one, and each transaction sets the role's `ALTER ROLE ... SET` settings (for example Supabase's `statement_timeout` for `anon`; the `statement_timeout` plug option still wins), then `role`, `request.jwt.claims`, `request.method`, `request.path`, `request.headers` and `request.cookies` before calling `pre_request:`. `roles:` is an allowlist: any other role is a 401 `22023` before SQL runs. The repo must log in as a `NOINHERIT` role without `SUPERUSER` or `BYPASSRLS` (else requests raise, unless `allow_privileged_login: true`). `jwt: :context` takes claims your `context_builder` verified (`context.jwt_claims`). The HS256 secret may be `{:system, var}`, an MFA or a function, read per request. A registry for an RLS plug can introspect with `mode: :rls` (no `only:`/`except:` needed). See `PgRest.Auth` and `PgRest.JWT.HS256`.

`ALTER ROLE ... SET` changes need a restart or `PgRest.Catalog.forget/1` for the plug's repo.

## Body parsing

Mount `Plug.Parsers` before the plug, or leave the body unparsed and PgRest reads it itself (limited by `max_body_bytes`). With `Plug.Parsers` there are two paths:

```elixir
# Fast path (resources without a custom changeset): the raw bytes are kept and
# passed to Postgres as-is
plug Plug.Parsers,
  parsers: [:json],
  json_decoder: Jason,
  body_reader: {PgRest.BodyReader, :read_body, []}
```

Without the body reader, PgRest falls back to `conn.body_params` and re-encodes the decoded payload. On that path `Plug.Parsers`' `:length` (not `max_body_bytes`) limits the body: set `:length` to at most `max_body_bytes`.

## Statement timeout

With `statement_timeout: "5s"`, PgRest sets `statement_timeout` with `set_config(..., true)` inside each request transaction and gives the repo call a `timeout:` slightly above it. Reads also run in a transaction. As defence in depth, also configure a dedicated repo for the API:

```elixir
config :my_app, MyApp.ApiRepo,
  parameters: [statement_timeout: "5s"]
```

## Repo logging

PgRest passes `log: false` to every repo call; its own `[:pgrest, :query]` span replaces the repo query log. Bind values never appear in PgRest telemetry or logs.

## Registry

`PgRest.Registry` takes `otp_app:` (auto-discovers every `use PgRest.Resource` module) or `modules:` (explicit list).

```elixir
{PgRest.Registry, otp_app: :my_app}
{PgRest.Registry, modules: [MyApp.API.Tasks, MyApp.API.Projects]}
```

Resources are keyed by schema and table. When they span several schemas, pass `schemas: ["public", "personal"]` (the first is the default); clients pick another with the `Accept-Profile` (reads) or `Content-Profile` (writes) header, as in PostgREST. Pass `name:` to run several registries, and `registry:` on `PgRest.Plug` to choose the one a plug serves.
