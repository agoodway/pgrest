defmodule PgRest.Telemetry do
  @moduledoc """
  Telemetry events emitted by PgRest.

  PgRest uses `:telemetry.span/3` to instrument requests and statements. Each span emits
  start, stop, and exception events.

  ## Events

  ### `[:pgrest, :request]`

  A `:telemetry.span/3` around each `PgRest.Plug` request to `/<table>`. Metadata:
  `%{resource: table, method: "GET"}`, plus `:status` on stop. Errors are translated into
  responses, so the span never emits `:exception` for a request that raised inside PgRest.

  ### `[:pgrest, :query]` (statements)

  A span around each statement `PgRest.Executor` runs: the read, count and `EXPLAIN`
  statements, the transaction setup, the write statement (`INSERT`, `UPDATE`, `DELETE`) and
  the write check that follows it over a scope. Metadata: `%{sql: String.t(), params_count:
  non_neg_integer(), prepared: boolean()}`, plus `:rows` and `:error_kind` on stop. The write
  statement also carries `write_path: :fast | :changeset` (whether the payload was bound as
  sent or built through the resource's `changeset/3`).
  `prepared` is `true` once `PgRest.StatementCache` has promoted the text. `error_kind` is
  `nil` on success, otherwise `:database` (Postgres error), `:connection` (connection or
  pool failure) or `:internal` (unexpected exception, logged by module name only). It is
  not the `:kind` of `:exception` events. Parameter values are never included, and
  Ecto's own repo query event is switched off for these statements because it carries them.

  ### `[:pgrest, :scope_cache]`

  Emitted each time a resource's scoped Ecto query is compiled to SQL
  (`PgRest.SQL.ScopedSource.compile/3`).

  **Measurements:** `%{count: 1}`

  **Metadata:**

    * `:resource` - the resource module
    * `:cached` - `true` when the SQL text came from the compiled-SQL cache
  """
end
