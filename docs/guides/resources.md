# Resources

A resource is an Ecto schema that uses `PgRest.Resource`:

```elixir
use PgRest.Resource,
  allow: [:read, :create],          # default :all
  custom_params: ["search"],        # names routed to handle_param/4 (default [])
  after_load: true,                 # after_load/2 is overridden (default false)
  unique_key: [:org_id, :slug],     # scoped writes on tables without a primary key
  readable: [:id, :title],          # default :all
  writable: [:title],               # default :all
  relationships: []                 # overrides and explicit declarations, see PgRest.SchemaGraph
```

| Callback | Purpose | Default |
|---|---|---|
| `scope/2` | Always-applied row filter (tenancy, soft deletes), applied to the root and every embed. A predicate: `where`, `join` and `distinct` only; anything else raises `ArgumentError` naming the resource | Identity |
| `handle_param/4` | Handles the query parameters declared in `custom_params` (search, geo-queries, any app-specific filter) | No-op |
| `changeset/3` | Changeset for writes; its final changes are what is written | Casts the writable set with `force_changes: true` |
| `after_load/2` | Transforms a row map after loading (needs `after_load: true`) | Identity |

PgRest never discovers tables from the database: schemas define the resources, and it reads column types and defaults of registered tables only.

## Operations (`allow:`)

`allow:` lists the operations a resource exposes. An excluded operation is a missing grant: `42501`, on every resource the request touches. A resource without `:read` cannot be embedded, spread or used as a many-to-many junction, and a write to it cannot read rows back: filters on `PATCH`/`DELETE` (custom params included), `return=representation`, `Prefer: count=` and the `Location` of `return=headers-only` are all `42501`. `allow: [:create]` therefore accepts only `return=minimal` inserts, as a Postgres role with `INSERT` but no `SELECT` would.

## Schema prefixes

A resource is read and written in one effective schema: the scope's `from` prefix, then its query prefix (`put_query_prefix/2` in `scope/2`, for schema-per-tenant), then the schema's `@schema_prefix`. The catalog lookups and the request `search_path` use the same schema. With none set the table is unqualified and resolves through `search_path`. A per-call Repo `prefix:` option is not supported: set the prefix in `scope/2`.

## Column exposure

Every registered field is readable, filterable, orderable and writable by default. Narrow it:

- `readable:` / `writable:` list the exposed fields. A column outside the list fails the way a Postgres column privilege does: `42501`. `return=headers-only` needs every primary key column to be readable, because the `Location` header shows the key.
- Fields declared with `redact: true` in the Ecto schema are hidden from read, filter and order, and left out of the default changeset, unless you list them in `readable:` / `writable:`.
- Constraint `details` are dropped (as Postgres does under RLS) when the effective source is scoped or a column allowlist is set.

## Unsupported table names

PgRest generates SQL with its own CTE and alias names, all starting with `pgrst_` (`pgrst_source`, `pgrst_source_count`, `pgrst_e1`, `pgrst_t0`, ...). Do not register a table whose name starts with `pgrst_`: it would collide. The same prefix is rejected for request output names (select aliases).

## Security notes

- With `after_load/2`, the response body is decoded and re-encoded with plain `Jason`, so a non-integer number goes through a float: `1.50` becomes `1.5`, and digits past double precision are rounded. Integers stay exact. Keep money and exact decimals as strings (cast in the select, `amount::text`) on those resources.
- `after_load/2` is a transformation hook, **not a confidentiality control**. Filters, ordering, counts and `!inner` can still reveal values of fields it removes, and it does not run on the implicit junction rows of many-to-many embeds. Use `readable:` / `writable:` for columns and `scope/2` for rows.
- Scoped `PATCH` and `DELETE` take their rows `FOR UPDATE`, so a concurrent change of ownership is waited for. Limits remain (snapshot races): an upsert (`POST` with `merge-duplicates`, and `PUT`) whose owner column comes from the payload can race with a concurrent ownership change (an upsert relies on `ON CONFLICT`'s own row lock and the write check), and `DELETE` under a scope with a join or `distinct` has a weaker guarantee because the scope predicate is not re-evaluated after the lock wait. `PATCH` is covered by the write check.
- `unique_key:` must be truly unique and its columns `NOT NULL`; the write check and the scope semijoin trust it.
- A custom `changeset/3` runs once per row (keep it pure), on `struct(resource)` (also for `PATCH`, not the stored row: a `put_change` derived from struct fields uses their defaults), and its **final changes express write intent**: only keys in `changeset.changes` (plus changes it adds with `put_change/3`) are written. `writable:` (and `redact: true`) gate only keys the client supplies (`42501`), so a change the callback generates is written even for a non-writable or redacted field. A supplied key it does not cast is not written. `cast/4` drops a value equal to the struct default (`nil`, `0`, `false`, `""`, `[]`), so to write one cast with `force_changes: true` before your validations (they then validate it). Ecto does not force embeds: a `cast_embed/3` clearing an embed to an equal struct default (`nil` / `[]`) is omitted. An upsert whose rows differ only by a default-equal value that a changeset without `force_changes` dropped is a 400 `PGRST102` (the rows are no longer uniform).
- Request values are bind parameters and identifiers go through `PgRest.SQL.Builder` quoting; filter and payload casts use the column's catalog type.
