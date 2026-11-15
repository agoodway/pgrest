# Upgrading from 0.1 to 0.2

## Security note: review every resource before upgrading

0.2 changes what a resource exposes by default. The default `changeset/3` now casts **every
writable field** (0.1 cast nothing), and **every non-redacted field is readable, filterable
and orderable**. Before upgrading, review each resource and either set `readable:` /
`writable:` or mark secrets `redact: true` in the Ecto schema:

```elixir
defmodule MyApp.API.Accounts do
  use Ecto.Schema
  use PgRest.Resource,
    readable: [:id, :email, :plan],
    writable: [:email]

  schema "accounts" do
    field :email, :string
    field :plan, :string
    field :password_hash, :string, redact: true
    field :api_token, :string, redact: true
  end
end
```

Redacted fields are hidden from read, filter and order and left out of the default changeset
unless you list them. Columns outside `readable:` / `writable:` fail with `42501`.
`after_load/2` is a transformation hook, not a confidentiality control: use `readable:`,
`writable:` and `scope/2` instead.

## Function and authorization security

Function introspection in application mode requires `only:`/`except:` or an
`authorize/4` module: calls otherwise execute with the repo role's privileges.
Configured authorization modules now deny unimplemented operations. Every touched
resource is checked, RPC functions need `:execute`, and plans need `:explain`;
`42501` denials split 401/403 by anonymity. RLS configuration requires `roles:`.
Review the [authorization guide](authorization-and-rls.md) before enabling it.

Hook queries follow the predicate-only `scope/2` contract; `limit:` is a separate
per-parent permission. Aggregates and plan media are off by default; enable with
`aggregates: true` and `plan_enabled:` only for callers permitted to use them.
See [RPC](rpc.md) for function result scoping and introspection migration.

## Removed routes: `/:resource/:id`

Before:

```
GET    /api/tasks/42
PATCH  /api/tasks/42
DELETE /api/tasks/42
```

After, with filters like every other PostgREST client:

```
GET    /api/tasks?id=eq.42
PATCH  /api/tasks?id=eq.42
DELETE /api/tasks?id=eq.42
```

Singular responses come from `Accept: application/vnd.pgrst.object+json`.

## Removed negation key form: `?not.col=`

Before: `GET /api/tasks?not.status=eq.done`
After: `GET /api/tasks?status=not.eq.done`

## Error shape

Errors are PostgREST-shaped with all four keys, and the HTTP status follows the SQLSTATE or
`PGRST` code:

```json
{"code": "42703", "message": "column tasks.nope does not exist", "details": null, "hint": null}
```

Before, bodies were `{"error": "..."}`. Update clients that read `error`. Changeset
validation errors are a 400 `23514` with string `details`.

## `after_load/2` signature and order

`after_load/2` takes and returns a string-keyed map (not an Ecto struct), sees output keys
(aliases rename columns), runs children first, and must be enabled:

```elixir
# 0.1
def after_load(%__MODULE__{} = task, _context), do: %{task | title: String.trim(task.title)}

# 0.2
use PgRest.Resource, after_load: true

@impl PgRest.Resource
def after_load(%{"title" => title} = row, _context), do: %{row | "title" => String.trim(title)}
def after_load(row, _context), do: row
```

## Custom params must be declared

0.1 passed any unrecognized key to `handle_param/4`. 0.2 only routes the names you declare:

```elixir
use PgRest.Resource, custom_params: ["search", "within_miles"]
```

An undeclared key is treated as a column filter (unknown column: 400). On `PATCH` and `DELETE`
a declared custom param narrows the rows, so it needs `:read` from the authorization hook and
`allow:`. It does not satisfy `require_filters_for_mutations` (only column filters do, since
`handle_param/4` may narrow nothing), and the write check applies `scope/2` alone.

## `allow:` covers every resource a request touches

An operation outside `allow:` is a `42501` wherever the resource appears, not only on its own
route. A resource without `:read` cannot be embedded, spread or used as a many-to-many
junction, and its writes cannot read rows back: filters, `return=representation`,
`Prefer: count=` and the `Location` of `return=headers-only` are refused. `allow: [:create]`
accepts only `return=minimal` inserts. `return=headers-only` also needs every primary key
column in `readable:`.

## Schema prefixes and the Registry

A scope that sets the schema (`put_query_prefix/2`) now applies to writes, catalog lookups and
the request `search_path` too, not only to reads. A per-call Repo `prefix:` option is not
supported; set the prefix in `scope/2`.

`PgRest.Registry` keys resources by `{schema, table}`, so the same table name may be
registered in two schemas. Resources spanning several schemas need `schemas: ["public",
"other"]` (the first is the default; requests pick another with `Accept-Profile` or
`Content-Profile`), and two resources for the same `schema.table` raise at start. `:name` is
supported (default `PgRest.Registry`); a plug serving another registry passes `registry:
MyApp.OtherRegistry`. Embeds only reach tables in the request's schema, as in PostgREST.

## Removed plug option: `:json`

Bodies are encoded and decoded with `Jason`; remove `json:` from the plug options (an unknown
option raises).

## `scope/2` is a predicate

`scope/2` may add `where`, `join` and `distinct` only. `limit`, `offset`, `order_by`,
`group_by`, `select` and preloads raise `ArgumentError` naming the resource on first use. A
scope that joins is spliced as a primary-key semijoin, so it cannot duplicate rows.

## No `defoverridable` / `super` in `scope/2` and `changeset/3`

0.1 resources calling `super` in `scope/2` or `changeset/3` no longer compile. The identity
scope and the default changeset are injected only when you do not define your own, so
call the pieces you need directly:

```elixir
# 0.1
def changeset(struct, attrs, ctx), do: super(struct, attrs, ctx) |> validate_required([:title])

# 0.2
def changeset(struct, attrs, _ctx) do
  struct
  |> Ecto.Changeset.cast(attrs, [:title, :status])
  |> Ecto.Changeset.validate_required([:title])
end
```

A custom `changeset/3` runs once per row, on `struct(resource)` (also for `PATCH`, not the stored row); keep it pure. **Its final changes express write
intent** (breaking): only keys in `changeset.changes` are written (plus anything it adds with
`put_change/3`); a supplied key it does not cast is not written. Ecto's `cast/4` drops a value
equal to the struct default (`nil`, `0`, `false`, `""`, `[]`), so a client sending
`{"count": 0}` with a struct default of `0` writes nothing. To write such values, and have your
validations see them, cast with `force_changes: true` (the default changeset does):

```elixir
def changeset(struct, attrs, _ctx) do
  struct
  |> Ecto.Changeset.cast(attrs, [:title, :count], force_changes: true)
  |> Ecto.Changeset.validate_number(:count, greater_than: 0)
end
```

`writable:` (and `redact: true`) gate only keys the client supplies, so a change your changeset generates with `put_change/3` is written even for a non-writable or redacted field. An upsert whose rows differ only by a default-equal value dropped without `force_changes` is a 400 `PGRST102`.

Ecto does not force embeds: a `cast_embed/3` that clears an embed to a struct default that is
the same (`nil` for `embeds_one`, `[]` for `embeds_many`) is omitted.

## Mutations without a filter

`PATCH` and `DELETE` without a filter fail with 400 `21000` (`UPDATE requires a WHERE clause`
/ `DELETE requires a WHERE clause`), matching Supabase. To get plain PostgREST behaviour set
`require_filters_for_mutations: false` on the plug.

## `Prefer: tx=rollback` needs `tx_end`

Under the default `tx_end: :commit`, `Prefer: tx=rollback` is ignored and not echoed. To honour
it:

```elixir
forward "/api", PgRest.Plug, repo: MyApp.Repo, tx_end: :commit_allow_override
```

## Telemetry

Event names are `[:pgrest, ...]`, not `[:pg_rest, ...]`: `[:pgrest, :request]`,
`[:pgrest, :query]` (one span per statement; it replaces the repo query log, which PgRest
turns off with `log: false`) and `[:pgrest, :scope_cache]`. Update any handlers.

## Removed modules

`PgRest.Parser`, `PgRest.TypeCaster`, `PgRest.Filter`, `PgRest.Order`, `PgRest.Select`,
`PgRest.QueryPipeline` and `PgRest.Utils` are gone. If you called them directly, drive
`PgRest.Plug` instead.
