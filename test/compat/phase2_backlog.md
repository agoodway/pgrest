# Phase 2 scenario sweep

Source: the pinned v14.18 `test/spec/Feature/Query/*Spec.hs`, not the removed
03/05 catalogs. Cases are adapted to registered Ecto resources and the two fixtures.
Golden responses come from live v14.18; PgRest-only expectations mark deliberate
differences. `pending.txt` is empty. This is feature-family triage, not a claim that
every upstream test has an identical local test.

## Ported

| Upstream family | Scenario coverage |
|---|---|
| QuerySpec operators, quoting, full text, JSON paths, any/all, order, canonical location | `filters/*`, `filter_syntax/*`, `select*/*`, `ordering/*`, `querystring/*`; sorted canonical params → `sweep/content-location-sorted`; negative JSON-path diagnostics → `sweep/bad-negative-json-path` |
| AndOrParams, RelatedQueries, EmbedInnerJoin, EmbedDisambiguation, SpreadQueries | `embedding/*`, `embed_errors/*`, `ordering/*`; computed relationships excluded below |
| AggregateFunctions | `aggregates/*`; after_load spread and root-alias errors are documented differences |
| Range, QueryLimited, Preferences, Singular | `range/*`, `pagination/*`, `counting/*`, `preferences/*`, `media/*` |
| Insert, Update, Delete, Upsert, PgSafeUpdate | `insert/*`, `update_delete/*`, `upsert/*`, `put/*`, `safeupdate/*`; null inferred view-key Location → `sweep/nullable-key-location`; camelCase merge/ignore → `sweep/camel-*`; representation embeds → `sweep/upsert-embed`, `put/embedded-resource-ordered` |
| RpcSpec overloads, defaults, variadics, OUT/INOUT, return shapes, embeds, planned/estimated counts | `rpc/*`, `rpc_resolution/*`; uppercase identifiers → `sweep/uppercase-rpc-*`; boolean/numeric/date/array/JSON GET inputs → `sweep/typed-*` |
| ErrorSpec / RpcSpec custom errors | `errors_custom/*`: PT402, JSON PGRST, optional body fields, malformed/missing payloads, required headers and typed JSON validation; 42P17/54001/PT699 status mapping |
| RpcSpec volatile singularity under commit | `rpc_commit/*` plus `rpc_commit_test.exs`: both engine orders assert rows unchanged, PGRST116 before max-affected |
| NullsStrip, CSV, media negotiation, PlanSpec | `media_types/*`, `plan/*`; structural plans rather than upstream SQL cost/node identity |
| MultipleSchema, JWT, request/response GUCs, privileges and role defaults | `profiles/*`, `rls/*`, `response_gucs/*`, `authorization/*`; Supabase-shaped roles replace upstream test roles |
| UnicodeSpec | `sweep/unicode-*`: encoded table/column identifiers, read/insert/delete |
| QuerySpec foreign tables | `sweep/foreign-*`: regular filters, select/order/limit on a loopback postgres_fdw resource |
| postgrest-js query/filter/transform/relationship/mutation/RPC behavior | Supabase scenarios in the areas above and serial dual-engine `test/js/` assertions |

## Deferred beyond 0.2

- Computed columns/fields and computed relationships: require the future function/relationship adapter (QuerySpec, ComputedRelsSpec).
- CSV and form-urlencoded request bodies: request parsers are outside 0.2; response CSV is covered.
- Raw unnamed text/xml/bytea RPC parameters and bulk RPC arrays: no general raw/bulk request API in 0.2; existing unsupported-resolution cases remain covered.
- OpenAPI root: future schema-document generation (OpenApi specs).
- Proxy-Status and client-error-verbosity: not implemented response/configuration contracts (ErrorSpec).
- db-max-rows-driven estimated view counts: needs view-specific catalog estimation (QueryLimitedSpec).
- PostGIS/GeoJSON, extension operators/types and domain data representations: future syntax/extension adapter (PostGISSpec, QuerySpec data representations).
- Custom media handlers and configurable raw output types: future handler registry (CustomMediaSpec, RawOutputTypesSpec).
- Automatic relationship inference through views/materialized views and partitions: resources declare relationships; no table/view introspection (QuerySpec view/partition sections).
- Plan costs, exact SQL nodes, index choices and PostgreSQL-version-specific settings: engine-specific performance assertions belong to Phase 3; supported plan responses are recorded.
- Server-Timing/Proxy transport diagnostics and custom HTTP reason phrases: host-server transport surface, not the Plug error-body contract.
- Role temp-file-limit exhaustion and duplicate pg_description OID catalog corruption: server-administration fixtures, not new REST behavior; status mapping is covered.
- Multi-parameter signatures with an unnamed parameter: deliberately uncached; live v14.18 empty-name POST gives 42601 and GET gives PGRST100. `sweep/partially-unnamed-post` pins PgRest's PGRST202; see compatibility guide.

The old “legacy target-name Warning header” catalog entry has no corresponding
Warning assertion in the pinned v14.18 Query specs and is not a remaining port.
