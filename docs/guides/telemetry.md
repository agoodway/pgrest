# Telemetry

PgRest emits `:telemetry` spans under the `[:pgrest, ...]` prefix. See `PgRest.Telemetry`.

```
[:pgrest, :request, :start | :stop]               %{resource: table, method: "GET"}, :status on stop
[:pgrest, :query, :start | :stop | :exception]     %{sql, params_count, prepared}, :rows and :error_kind on stop
[:pgrest, :scope_cache]                            %{resource: module, cached: boolean}
```

Errors are translated into responses, so the request span emits no `:exception` for a failure PgRest handles. Bind values never appear in the metadata.
