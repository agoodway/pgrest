# Testing

## Test harness only: docker compose

`docker-compose.yml` is for running this repository's own test suite against a Postgres and a pinned PostgREST. It binds to `127.0.0.1` only and must not be deployed.

```bash
docker compose up -d db        # Postgres on 54320
docker compose --profile safeupdate up -d # also PostgREST on 54321 (admin 54322) and 54329 (limits variant)
mix test                       # unit and integration tests (needs Postgres on 54320)
mix test --only differential   # compares PgRest with PostgREST (needs 54321 and 54329)
```

Override the ports and URLs with `PGREST_DB_PORT`, `PGREST_POSTGREST_URL` and `PGREST_POSTGREST_LIMITS_URL`.

The Supabase-shaped fixture (PostgREST on 54323) sets `plan_cache_mode=force_custom_plan`
for `anon` and `authenticated`. This works around v14.18's cross-role generic-plan reuse
of inlined SQL RPCs while retaining the upstream `privileged_hello` definition and its
EXECUTE denials. PgRest's executor regression separately uses `auto`, verifies named
generic plans on one connection, and checks alternating roles after promotion.

## JavaScript client end-to-end tests

Requires Node 22 or newer and the compose services above, including `postgrest_supabase`
on 54323. Install the locked test client without lifecycle scripts:

```bash
npm ci --ignore-scripts --prefix test/js
mix test --only js
```

The harness runs the same client assertions against PgRest and PostgREST in both engine
orders. Each run resets the existing fixture sequence baseline; rollback alone still
advances sequences. `mix test` excludes `:js` by default. The dual-tagged JS tests also
run under `mix test --only differential`, which therefore needs the npm install above.
Never run an independent Node suite while Mix tests recreate the fixture databases.

For an independent Node run, set `PGREST_COMPAT_JWT_SECRET` to the local fixture secret,
then start `MIX_ENV=test mix pgrest.compat.serve`. It rebuilds the existing fixtures and
binds to `127.0.0.1:54328`; `PGREST_JS_PORT` or `--port` overrides the port. In another
terminal run `BASE_URL=http://127.0.0.1:54328 npm test --prefix test/js`.

## Scenario isolation

Run the full `mix test`, then `mix test --only differential`, then
`mix test --only js`, serially. Do not probe live PostgREST while a suite runs:
each invocation rebuilds the fixture and reloads the schema cache.

`MIX_ENV=test mix pgrest.compat.record <area>` records v14.18 expectations.
RPC POSTs roll back by default. A commit-path regression must explicitly set
`stateful: true` and `Prefer: tx=commit`, leave committed fixture rows unchanged,
and verify side effects separately. The runner resets sequences before and after
each engine, including on failure; it does not restore committed rows.
