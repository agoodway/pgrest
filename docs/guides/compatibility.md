# Compatibility

PgRest targets PostgREST v14 and is differential-tested against it: a suite replays scenarios against a pinned PostgREST and compares status, body and the semantic headers. See [Testing](testing.md) for the harness.

## Supported operations

| HTTP Method                            | PostgREST Equivalent  | Description                                  |
|----------------------------------------|-----------------------|----------------------------------------------|
| `GET /resource`                        | `GET /table`          | List with filters, ordering, pagination      |
| `GET /resource?select=a,b,rel(c)`      | Resource embedding    | Embed related rows (lateral subqueries)      |
| `GET /resource?rel.field=eq.x`         | Embedded filters      | Filter on associated records                 |
| `GET /resource?select=*,rel!inner(*)`  | Inner join            | Only return rows with matching associations  |
| `POST /resource`                       | `POST /table`         | Create (single or bulk)                      |
| `PATCH /resource?filters`              | `PATCH /table?filters` | Update matching rows                        |
| `DELETE /resource?filters`             | `DELETE /table?filters` | Delete matching rows                       |
| `PUT /resource?pk=eq.x`                | `PUT /table?pk=eq.x`   | Upsert one row by primary key                |
| `GET/HEAD/POST /rpc/fn` | `GET/HEAD/POST /rpc/fn` | Call a registered function |
| `OPTIONS /`, `/resource`, `/rpc/fn` | Same routes | Discover allowed methods |

The grammar covers the PostgREST operator set (`eq`, `neq`, `gt`, `gte`, `lt`, `lte`, `like`, `ilike`, `match`, `imatch`, `in`, `is`, `isdistinct`, `cs`, `cd`, `ov`, `sl`, `sr`, `nxl`, `nxr`, `adj`, full-text `fts`/`plfts`/`phfts`/`wfts`, `any`/`all` quantifiers, `not`), logic trees (`and`, `or`, nested, depth capped at 16), JSON paths (`->`, `->>`), casts, aliases, and embedding (`!hint`, `!inner`, `!left`, spreads `...rel(...)`).

Aggregate functions (`count()`, `col.sum()`, `avg`, `min`, `max`, with implicit grouping, in embeds and hoisted from to-one spreads) need the plug option `aggregates: true`; otherwise `PGRST123`.

`Accept` negotiation serves `application/json`, `application/vnd.pgrst.object+json`, `application/vnd.pgrst.array+json`, the `;nulls=stripped` variants of those two, and `text/csv`. Anything else is a 406 `PGRST107`.

`application/vnd.pgrst.plan[+json|+text]` answers with the execution plan of the statement the request would run (`for="<type>"`, default `application/json`; `options=analyze|verbose|settings|buffers|wal`). It needs the plug option `plan_enabled` (default `false`, like `db-plan-enabled`) and, with an `:authorization` module, the `:explain` operation on every resource and function it touches. Otherwise it is a 406 `PGRST107`, as if the type did not exist.

`OPTIONS /table` answers with an `Allow` header and no body (the methods `allow:` permits; `PUT` needs a primary key), `OPTIONS /` with `OPTIONS,GET,HEAD`, and `OPTIONS /rpc/fn` with `OPTIONS,POST` for a volatile function, else `OPTIONS,GET,HEAD,POST`. Any other method is a 405 `PGRST117`.

## Request pipeline

A read (`GET`, `HEAD`) flows through five stages and runs as one SQL statement in one short transaction (plus `EXPLAIN` for planned or estimated counts, and one setup statement that always sets the transaction-local `search_path`):

```
PgRest.Request    query string, headers, Prefer and Range parsed by the NimbleParsec grammar into an AST
    |
PgRest.Planner    AST resolved against the registered resources and the relationship graph
    |
PgRest.SQL.Read   one statement: scope/2 spliced in at every node, filters, embeds as lateral subqueries
    |
PgRest.Executor   Repo call with log: false, [:pgrest, :query] span, optional statement cache
    |
PgRest.Responder  JSON, Content-Range, status, errors translated to PostgREST shapes
```

`POST` and `PUT` go through `PgRest.Write.Insert` (`PUT` via `PgRest.Write.Put`), `PATCH` and `DELETE` through `PgRest.Write.Modify`. Filters, embeds, ordering and paging never issue per-row or per-embed queries.

## Known differences from PostgREST

Everything else is compared against the pinned PostgREST by the differential suite. These differences are deliberate:

- `select=` with trailing junk is a 400; PostgREST silently ignores it.
- A request with both a malformed select and invalid preferences under `handling=strict` is a 400 `PGRST122`; PostgREST answers `PGRST100` (it validates preferences after planning).
- Output keys longer than 63 bytes, or starting with `...`, `pgrst_` or `_postgrest_`, are a 400 (generated alias names).
- Duplicate embed output keys in one select node are a 400.
- `PATCH` with a JSON array of two or more objects is a 400 `PGRST102`; PostgREST applies one arbitrarily.
- Embedded logic trees (`rel.or=`) on mutations are a 400, and embedded `limit`/`offset` on minimal mutations is `PGRST108` (PostgREST ignores them, which would turn into a mass update).
- `require_filters_for_mutations` defaults to `true` (Supabase `pg-safeupdate`, `21000`). Set `false` for plain PostgREST.
- `Prefer: tx=rollback` is honoured only with `tx_end: :commit_allow_override`; this matches PostgREST's default `db-tx-end`.
- Malformed `%` escapes in the query string are a 400 `PGRST100`.
- Changeset validation errors are a 400 `23514` with string `details`.
- Tables named `pgrst_source` or `pgrst_*` are unsupported (generated CTE and alias names).
- A `response.status` GUC outside 200..999 is a 500 `PGRST112`. PostgREST sends 1xx statuses it never completes, and 0, 99 and 1000+ as a malformed status line.
- A `response.headers` GUC header with an empty or non-token name, or a CR, LF, NUL or other control character in its name or value, is a 500 `PGRST111`. PgRest writes these headers itself, so this keeps a value built from request data from splitting the response.
- An aggregate inside a to-one spread over a resource with `after_load/2` is a 400 `PGRST127` (that spread's columns are merged after the query, so it cannot hoist the aggregate).
- `Prefer: handling=strict, max-affected=n` on `PATCH`/`DELETE` bounds the rows written. PostgREST compares the rows the response returns, which an aggregating `select=` (`count()`) collapses.
- A Postgres error that names a column of a read names the generated table alias (`pgrst_t0`), where PostgREST names the table: for example `42803` for the legacy bare `count` selected next to an ungrouped column.
- `text/csv` and `nulls=stripped` are not offered for a request that reads a resource with `after_load/2`: a client that also accepts JSON gets JSON, any other a 406 `PGRST107`. See `PgRest.Negotiate`.
- `application/geo+json` is never offered (no PostGIS): 406 `PGRST107`, where PostgREST serves it. See `PgRest.Negotiate`.
- A call's or write's CSV header lists exactly the columns the body carries. PostgREST also adds unselected filter and key columns, sorts the names and names the column behind an alias (`select=name&id=eq.1` on an RPC gives `id,name` over one column). See `PgRest.SQL.Format`.
- `options=analyze` on a write, or on a call to a function that may write, is offered only with `Prefer: tx=rollback` honoured (`tx_end: :commit_allow_override`); PostgREST runs and commits it. See `PgRest.Negotiate`.
- A plan is also a 406 `PGRST107` when the authorization hook denies `:explain` (PostgREST has no such operation); a plan `for=` a custom media handler (`text/xml`, `application/vnd.twkb`) or `application/geo+json` is never offered. See `PgRest.Negotiate`.
- A plan explains PgRest's own statement, so its nodes differ from PostgREST's in places (a write adds an aggregate over the written rows, a call reads a `pgrst_rpc` CTE). See `PgRest.SQL.Explain`.
- `PUT` with a payload that lacks a primary key column (or `[]`) is a 400 `PGRST115`; PostgREST answers `42703`. See `PgRest.Write.Put`.
- `PUT` with several array elements matching the URL is a 400 `PGRST102` and writes nothing; PostgREST fails with a 500 `21000`. See `PgRest.Write.Put`.
- `OPTIONS` sends no CORS headers (PostgREST sends `Access-Control-Allow-Origin: *`); serve CORS from the host app. Its `Allow` is narrowed by `allow:`. See `PgRest.Plug`.
- In RLS mode, `roles:` is an allowlist: a token's role outside it (`none`, `postgres`, the authenticator) is a 401 `22023`, where PostgREST switches to any role the authenticator may assume. A superuser or `BYPASSRLS` login raises unless `allow_privileged_login: true`. See `PgRest.Auth`.
- `request.path` is relative to the plug's mount; PostgREST's is the full path. See `PgRest.Auth`.
- `pre_request` runs after PgRest plans the request, so a planning error (an unknown column) answers before the function's. See `PgRest.Auth`.
- A missing or short JWT secret is a 500 `PGRSTX00`; PostgREST answers `PGRST300`. See `PgRest.JWT.HS256`.
- `OPTIONS /rpc/<f>?select=...` skips embed resolution and path checks: `select=*,nope(*)` returns 200 instead of `PGRST200`; `select=id&clients.id=eq.1` or `select=&a.b=eq.1` returns 200 instead of `PGRST108`. See `PgRest.Plug`.
- A role's `default_transaction_isolation` (`ALTER ROLE ... SET`) is not applied in RLS mode; PostgREST uses it as the transaction's isolation level. See `PgRest.Auth`.
- Query policies extend privileges with column-limited stars, separate read/write grants and keyed source narrowing; `result_scope: :none` retains column/count/aggregate grants and limits but trusts the function for rows. See `PgRest.Authorization`.
- Permission limits cap aggregate inputs and return exact capped totals for every count mode. See `PgRest.Authorization.Apply`.
- Explicit virtual `writable:` fields are changeset-only inputs; PostgREST accepts database columns only. See `PgRest.Resource`.
- Custom parameter callbacks cannot widen resource scopes or query policies, even with `or_where`; identity sources need no key, while changed restricted sources require one. See `PgRest.SQL.ScopedSource`.
- Write permission caps bound response counts; singularity and transactional checks retain the uncapped written count. See `PgRest.Write`.
- Extension-owned functions are never exposed by introspection, even with EXECUTE privileges. See `PgRest.Function.Introspect`.
- Prepared statements are partitioned by database role. PostgREST v14.18 can reuse a privileged role's folded result for anon after plan caching. See `PgRest.StatementCache`.
- A hidden `on_conflict` column returns `42703`, like a nonexistent column. See `PgRest.Write`.
- Query-hook `:explain` requires an explicit `{:ok, query, opts}` grant; a two-tuple denies it. See `PgRest.Authorization`.
- Multi-parameter functions with an unnamed argument are uncached (`PGRST202`); v14.18 attempts an empty-name POST and returns `42601` (GET returns `PGRST100`). See `PgRest.RPC.Resolver`.
- Custom RAISE headers replace same-named generated headers; v14.18 emits two Content-Type values when an error supplies one. See `PgRest.Responder`.
- Custom RAISE `status_text` is validated but the HTTP reason phrase comes from the host server; PostgREST sends the supplied phrase. See `PgRest.Error.Translate`.
