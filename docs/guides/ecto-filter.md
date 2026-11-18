# Filtering Ecto queries

`PgRest.Plug` turns a request into one SQL statement. When you only want PostgREST's
filter syntax on top of your own Ecto queries (a LiveView list, a JSON endpoint you
already have), parse the filters with `PgRest.Grammar.Filter` and apply them with
`PgRest.Ecto.Filter`.

```elixir
alias PgRest.Ecto.Filter
alias PgRest.Grammar.Filter, as: Grammar

with {:ok, status} <- Grammar.parse_condition("status", "in.(active,draft)"),
     {:ok, either} <- Grammar.parse_logic("or", "(price.lt.10,qty.gte.100)"),
     {:ok, query} <- Filter.where(Product, [status, either]) do
  Repo.all(query)
end
```

`where/3` adds one `where` per node. `to_dynamic/2` returns the `Ecto.Query.dynamic/2`
expression for one node, to combine with your own conditions:

```elixir
{:ok, dynamic} = Filter.to_dynamic(condition, schema: Product)
from(p in Product, where: p.archived == false and ^dynamic)
```

Both return `{:error, %PgRest.Error{}}` instead of a query when a filter cannot be
applied, so the same error can go back to the client.

## Field names and casting

Field names resolve against an allowlist; request text never becomes an atom.

- `schema:` makes every schema field filterable and casts each value with
  `Ecto.Type.cast/2` against the field type: `qty=eq.10` binds the integer `10`,
  `status=eq.active` binds `:active` for an `Ecto.Enum`, and `qty=eq.abc` is a 400
  `22P02` before the query runs. `where/3` takes the schema from the query when you leave
  it out; pass `schema: nil` to skip casting.
- `fields:` narrows the filterable fields (`fields: [:status, :qty]`). Without a schema it
  is required, and values bind uncast as strings. Postgrex encodes parameters in binary,
  so an uncast string only matches a text-like column (`text`, `varchar`, `citext`, an
  enum); filter other columns through a schema.

A field outside the allowlist is a 400 `42703`. Passing neither option raises
`ArgumentError`.

Nodes can also be built by hand with already-typed values:

```elixir
%PgRest.AST.Condition{field: %PgRest.AST.Field{name: "due"}, op: :gte, value: ~D[2026-01-01]}
```

## Operators

| Operator               | Ecto expression                                | Value cast   |
| ---------------------- | ---------------------------------------------- | ------------ |
| `eq neq gt gte lt lte` | `== != > >= < <=`                              | field type   |
| `isdistinct`           | `!= or is_nil/1` (`IS DISTINCT FROM`)          | field type   |
| `in`                   | `in ^list`                                     | each element |
| `like ilike`           | `like/2`, `ilike/2`, with `*` as `%`           | none         |
| `match imatch`         | `~`, `~*`                                      | none         |
| `is`                   | `is_nil/1`, `IS TRUE/FALSE/UNKNOWN`            | none         |
| `cs cd ov`             | `@>`, `<@`, `&&` on array columns              | field type   |
| `fts plfts phfts wfts` | `to_tsvector(col) @@ to_tsquery(...)` and kin  | none         |

`not.` negates a condition and `not.and` / `not.or` negate a logic tree, as `NOT (...)`.
`in.()` and `in.("")` are the empty list and match no rows, as in PostgREST.
`cs`, `cd` and `ov` take a PostgreSQL array literal (`{a,b}`) or a list. A full-text
config (`fts(english).cats`) binds as `regconfig` for both `to_tsvector` and the query
function.

## Not supported

These return a 400 `PGRST100` naming what is unsupported:

- JSON paths (`data->a=eq.1`)
- `any` / `all` modifiers (`eq(any).{1,2}`)
- range operators (`sl`, `sr`, `nxr`, `nxl`, `adj`)
- an empty `and` / `or`, or an operator the compiler does not know
- a hand-built node whose value has the wrong shape for its operator: an `is` value
  other than `:null`, `:not_null`, `true`, `false` or `:unknown`, an `in` value that is
  not a list, a non-string pattern, full-text query or full-text config, `nil` with
  `eq`, `neq`, `gt`, `gte`, `lt` or `lte` (use `is.null`), or a list or map compared
  without a schema type

`cs`, `cd` and `ov` with a range or JSON literal, or a value that is neither a list nor
a string, are a `22P02`. The full-text operators
wrap the column in `to_tsvector`, so they do not apply to `tsvector` columns. Embedded
resource filters (`client.name=eq.x`) are a `PgRest.Plug` feature: parse them with
`PgRest.Grammar.Filter.parse_filter/2` and join yourself.
