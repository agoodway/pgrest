# Functions and RPC

`/rpc/name` calls a registered database function. GET and HEAD bind query-string
arguments and run read-only; POST binds a JSON object's named arguments. Volatile
functions that write fail with `25006` on GET. Resource returns support filters,
embeds, counts, JSON, singular JSON and CSV, subject to normal media negotiation.

Declare a function module and pass it in the registry's `functions:` list:

```elixir
defmodule MyApp.API.Add do
  use PgRest.Function,
    schema: "public",
    name: "add_them",
    params: [{"a", "integer"}, {"b", "integer", default: true}],
    returns: {:scalar, "integer"},
    volatility: :immutable
end

{PgRest.Registry, modules: [MyApp.API.Tasks], functions: [MyApp.API.Add]}
```

`returns:` also accepts `:void`, `{:setof_scalar, type}`,
`{:composite, resource_module}` and `{:setof, resource_module}`; composite shapes
can instead list `{column, postgres_type}` pairs. Declare each overload separately.
See `PgRest.Function` for parameter defaults and variadic arguments.

## Introspection and exposure

```elixir
{PgRest.Registry,
  modules: [MyApp.API.Tasks],
  introspect: [repo: MyApp.Repo, only: ["add_them"], as_role: "api_user"]}
```

In default application mode, calls run as the repo role. Introspection requires
`only:`/`except:` or an `authorization:` module exporting `authorize/4`; use an
explicit allowlist for a small public API. `as_role:` filters functions by EXECUTE
privilege; it does not change the role executing calls. Extension-owned functions
and trigger, event_trigger and internal returns are never exposed. A declared
function replaces an introspected signature with the same schema, name and inputs.

For an RLS plug, use `introspect: [repo: MyApp.AuthenticatorRepo, mode: :rls]`.
The plug checks registry mode and authorization settings; Postgres enforces EXECUTE
as the request's role. `as_role:` defaults to `nil`: no EXECUTE catalog filter is
applied, matching PostgREST's schema cache. Functions unavailable to the request
role remain cached and fail with `42501` when called. Set `as_role:` explicitly
when you also want to filter the catalog.

## Scoped results

`result_scope: :stored_rows` is the default: a returned resource row survives only
when an in-scope stored row matches its key and every mapped column, using
`IS NOT DISTINCT FROM`. Fabricated rows and altered attributes are dropped.
Custom-scoped resources need a primary key or `unique_key:`. VOLATILE functions
returning custom-scoped resources must explicitly declare `result_scope: :none`:
this trusts the function to enforce row visibility. The result resource still needs
`:read`; its query hook may deny and still restricts columns, count, aggregates and
permission limits. Only row matching is skipped, without requiring a key. Introspected functions set options
through `function_opts: %{{"public", "function_name"} => [result_scope: :none]}`.
Types without equality operators also need `:none` for scoped result matching.

Scoped result rows keep the function's own output order. Without an `order`
parameter, a call whose rows are matched against the stored rows reads the function
`WITH ORDINALITY` and sorts by that number, so the response and every `limit`/`offset`
page follow the order the function returned its rows in. An explicit `order` replaces
it, and an aggregating `select` groups the rows without it. The number is never part
of the response. Calls without row matching (`result_scope: :none`, or a scope that
is the identity for the request) keep PostgREST's statement, which has no `ORDER BY`.
Postgres names the number `ordinality`, so a row type with a column of that name
needs `result_scope: :none`.

Function authorization receives `%PgRest.Function{}`. Match `schema` and `name`
(and `params` for overloads); `module` is `nil` for introspected functions.

## Errors and response overrides

`RAISE SQLSTATE 'PT402'` returns 402 with the database message, detail and hint.
`RAISE SQLSTATE 'PGRST'` reads MESSAGE JSON (`code`, `message`, optional `details`,
`hint`) and DETAIL JSON (`status`, `headers`, optional `status_text`). Invalid
payloads return 500 `PGRST121`. HTTP reason phrases are supplied by the host server.

Functions and triggers can set transaction-local `response.status` and
`response.headers` GUCs. Headers are a JSON array of single-key string objects;
repeated headers survive and replace generated headers of the same name. Status
must be in 200..999. Overrides are read in the main statement; any error rolls
back its side effects. Singular set-returning calls also roll back if the result
is not exactly one row, even with `tx=commit`.
