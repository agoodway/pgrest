# Changelog

## 0.2.0 (2026-11-18)

PostgREST v14 compatibility pipeline. Read `docs/guides/upgrading-0.1-to-0.2.md` before upgrading:
the defaults for column exposure changed.

### Breaking changes

- The default `changeset/3` casts every writable field (0.1 cast nothing) and every
  non-redacted field is readable, filterable and orderable. Set `readable:` / `writable:` or
  mark secrets `redact: true`.
- A custom `changeset/3` decides what is written: only its final changes (keys in
  `changeset.changes`, including `put_change/3`) are written, once per row. A value equal to
  the struct default is not a change unless you cast with `force_changes: true` (the default
  changeset does); a `cast_embed/3` clear to an equal default is omitted. Changes the callback
  generates for persisted fields are written regardless of `writable:` / `redact: true`, which
  gate only keys the client supplies.
- Removed the `/:resource/:id` routes. Use `/<table>?id=eq.<id>`.
- Removed the `?not.col=` negation form. Use `?col=not.<op>.<value>`.
- Error bodies are PostgREST-shaped (`code`, `message`, `details`, `hint`), not `{"error": ...}`.
- `after_load/2` takes and returns a string-keyed map (it was an Ecto struct), runs children
  first and needs `use PgRest.Resource, after_load: true`.
- Custom query parameters must be declared with `custom_params: ["search"]`; undeclared keys
  are treated as column filters (an unknown column is a 400).
- `scope/2` is a predicate contract: `where`, `join` and `distinct` only.
- `PgRest.Resource` no longer makes `scope/2` or `changeset/3` `defoverridable`; calling
  `super` in them does not compile.
- `PgRest.Parser`, `PgRest.TypeCaster`, `PgRest.Filter`, `PgRest.Order`, `PgRest.Select`,
  `PgRest.QueryPipeline` and `PgRest.Utils` are removed (reads are one SQL statement built from
  an AST).
- `PATCH` and `DELETE` without a filter fail with 400 `21000` unless the plug sets
  `require_filters_for_mutations: false`.
- `Prefer: tx=rollback` is ignored unless the plug sets `tx_end: :commit_allow_override`.
- Telemetry events moved to the `[:pgrest, ...]` prefix.
- `allow:` is enforced on every resource a request touches, like a missing Postgres grant
  (`42501`): a resource without `:read` cannot be embedded, spread or used as a junction, and
  its writes cannot read rows back (filters, `return=representation`, counts, `Location`).
- A request for a resource whose `allow:` excludes the operation parses the query string (filter and order grammar) before it is denied, as PostgREST does: `?id=foo.1` is a `400` `PGRST100`, not a `401`. A denied request still reads a bounded request body (at most `max_body_bytes`).
- `return=headers-only` is a `42501` when a primary key column is outside `readable:`.
- Declared custom params on `PATCH`/`DELETE` need `:read` (they narrow rows like a filter),
  but only column filters satisfy `require_filters_for_mutations`, and the write check
  applies the resource scope only, never custom params.
- Writes, catalog lookups and the request `search_path` use the scope's effective schema
  prefix (`put_query_prefix/2` in `scope/2`), as reads do. A per-call Repo `prefix:` is not
  supported.
- Removed the `:json` plug option; bodies are encoded and decoded with `Jason`.
- `PgRest.Registry` publishes an immutable snapshot keyed by `{schema, table}`. It accepts
  `:name` (default `PgRest.Registry`; several registries run side by side, and `PgRest.Plug`
  picks one with `registry:`), `:otp_app`, `:modules` and `:schemas`. Resources spanning
  several schemas need `:schemas`, and two resources for the same `schema.table` raise. Its ETS
  tables are gone: the shared caches belong to `PgRest.Cache`, started by the `:pgrest`
  application. `get_resource/1`, `list_resources/0` and `graph/0` read the default registry.
- A request whose registry is not running is a 503 `PGRST002`, not a 500.
- Authorization modules receive `:execute`/`:explain` and `%PgRest.Function{}` targets
  (`module: nil` for introspected functions); handle these or deny via a catch-all.
  Missing callbacks deny; table operations may use `authorize_query/5` alone, but
  function execution needs `authorize/4`. A bare query grant does not grant EXPLAIN.
- The plug overrides builder keys including `graph`, `authenticated?`, repo and planner
  options; RLS also overrides `jwt_claims` and `db_role`.
- Permission errors (`42501`) return 401 for anonymous requests and 403 otherwise.
- RPC `result_scope: :none` skips row matching only; result query-hook denials,
  columns, count/aggregate grants and permission limits still apply.

### Added

- `PgRest.Function` declarations and filtered function introspection; RPC overloads,
  typed arguments, scoped result rows and EXECUTE authorization.
- Scoped RPC result rows (`result_scope: :stored_rows`) keep the function's own output
  order when the request has no `order`: the call runs `WITH ORDINALITY` and the read sorts
  by it, so `limit`/`offset` pages follow the function's order. An explicit `order` wins, and
  the number never appears in the response. Unscoped calls keep PostgREST's statement. A
  scoped row type with a column named `ordinality` needs `result_scope: :none`.
- Application query policies, per-parent permission limits, JWT/RLS role switching
  and fail-closed callback rules. RLS requires an explicit role allowlist.
- Aggregates, CSV and null-stripped JSON, execution plans, PUT, OPTIONS,
  strict preferences, max-affected, timezone and transaction-local response GUCs.
- Custom PT SQLSTATE statuses and JSON PGRST errors with response headers.
- NimbleParsec grammar for select, filters (logic trees, `not`, `any`/`all`, JSON paths, casts),
  and order (including related order).
- Resource embedding: m2o, o2m, o2o, m2m, self references, hints, `!inner`/`!left`, spreads,
  aliases, embedded filters, order, limit and offset, empty embeds.
- Writes: bulk insert, `columns=`, `missing=default`, upsert (`merge-duplicates`,
  `ignore-duplicates`, `on_conflict`), `return=` modes, `Location`, counts, singular responses,
  `Prefer: tx=`, scoped writes with a write check.
- `Range` header and `limit`/`offset` handling, `count=exact|planned|estimated`, `HEAD`,
  `Content-Range`, `Content-Location`, `Preference-Applied`.
- Schema profiles: `Accept-Profile` (reads) and `Content-Profile` (writes) pick one of the
  registry's `:schemas` (406 `PGRST106` otherwise), and responses carry `Content-Profile`
  when the schema was negotiated. Embeds stay within the request's schema, as in PostgREST.
- `PgRest.Catalog.facts/1`: the server's timezone names, version and whether the login role
  bypasses RLS, read once per repo.
- Plug options: `require_filters_for_mutations`, `max_limit` (every embed too),
  `max_embed_depth`, `max_body_bytes`, `max_bulk_rows`, `count_modes`, `tx_end`,
  `statement_cache`, `statement_timeout`, `authorization`, `aggregates`, `plan_enabled`,
  `rls`, `anonymous?`.
- Resource options: `readable:`, `writable:`, `relationships:`, `unique_key:`, `custom_params:`.
- `PgRest.BodyReader` keeps the raw JSON body for the fast write path.
- `PgRest.Catalog` reads column types and defaults of registered tables only.
- Differential test harness against a pinned PostgREST (`docker compose`, test harness only).
- `PgRest.Ecto.Filter`: compiles filter and logic-tree AST nodes into `Ecto.Query.dynamic/2`
  expressions (`to_dynamic/2`) or `where` clauses (`where/3`) for your own Ecto queries.
  Fields resolve against `schema:` / `fields:` allowlists (`42703` otherwise), values cast
  with the Ecto field type (`22P02` on failure; `:binary_id` and `{:array, :binary_id}` values must be
  valid UUIDs, normalised to lowercase), and JSON paths, `any`/`all` and range
  operators are refused with `PGRST100`, as is a hand-built node whose value has the wrong
  shape for its operator (an `is` value other than `null`, `not_null`, `true`, `false` or
  `unknown`, an `in` value that is not a list, `nil` with a comparison operator); it never
  raises on a malformed node. It
  replaces 0.1's `PgRest.Filter.apply_all/2` and
  `PgRest.TypeCaster.cast_filters/2`. See `docs/guides/ecto-filter.md`.
- `PgRest.Grammar.Filter.parse_array_literal/1` splits a PostgreSQL array literal.
- `PgRest.Grammar.Filter.operator_prefix?/1` tells a malformed filter (`is.maybe`) from a
  value that is not a filter at all (`hello`).
- `PgRest.Error.invalid_input/2` (`22P02`) for a value the column type rejects.

### Telemetry

- `[:pgrest, :request]` span per request.
- `[:pgrest, :query]` span per statement (metadata `sql`, `params_count`, `prepared`, and on
  stop `rows` and `error_kind`). It replaces the repo query log, which PgRest turns off with
  `log: false`.
- `[:pgrest, :scope_cache]` for the compiled scope SQL cache.
- Any raised `PgRest.Error` is classified `error_kind: :database`; stop metadata carries
  `error_kind` (`nil`, `:database`, `:connection`, `:internal`).

### Known differences from PostgREST

See [Compatibility](docs/guides/compatibility.md#known-differences-from-postgrest).
