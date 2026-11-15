# Aggregate functions with implicit grouping, ported from upstream
# test/spec/Feature/Query/AggregateFunctionsSpec.hs (AG:15-354; `allowed` against the
# default server, `disallowed` against the limits server, whose PostgREST runs with
# `db-aggregates-enabled = false`), plus the postgrest-js aggregate cases on the Supabase
# fixture. Requests without an `order=` compare order-insensitively (`sort: true`).
get = fn id, path, opts -> Map.merge(%{id: "aggregates/" <> id, path: path}, Map.new(opts)) end

not_allowed = %{
  status: 400,
  headers: %{"content-type" => "application/json; charset=utf-8"},
  body: %{
    "code" => "PGRST123",
    "message" => "Use of aggregate functions is not allowed",
    "details" => nil,
    "hint" => nil
  }
}

pgrest_disabled = fn id, path ->
  %{
    id: "aggregates/" <> id,
    path: path,
    plug_opts: [aggregates: false],
    only: :pgrest,
    expect: not_allowed
  }
end

[
  # --- count() without a field (AG:15-27) ---
  get.("count-all", "/entities?select=count()", []),
  get.("count-alias", "/entities?select=cnt:count()", []),
  get.("count-cast", "/entities?select=count()::text", []),
  get.("count-grouped", "/projects?select=c:count(),client_id&order=client_id.desc", []),

  # --- legacy bare `count` (AG:29-35) ---
  get.("legacy-count", "/entities?select=count", []),
  get.("legacy-count-embedded", "/clients?select=name,projects(count)", sort: true),
  # A bare `count` is no aggregate to PostgREST: it never groups, and it is allowed when
  # aggregates are disabled. Ungrouped, Postgres's 42803 names the generated table alias
  # where PostgREST's names the table (a known difference), so that one is PgRest-only.
  %{
    id: "aggregates/legacy-count-ungrouped",
    path: "/entities?select=count,name",
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "42803",
        "details" => nil,
        "hint" => nil,
        "message" =>
          ~S|column "pgrst_t0.name" must appear in the GROUP BY clause or be used in an aggregate function|
      }
    }
  },
  get.("legacy-count-disabled", "/entities?select=count", server: :limits),

  # --- aggregates on fields (AG:37-91) ---
  get.("sum", "/project_invoices?select=invoice_total.sum()", []),
  get.("avg", "/project_invoices?select=invoice_total.avg()", []),
  get.("min", "/project_invoices?select=invoice_total.min()", []),
  get.("max", "/project_invoices?select=invoice_total.max()", []),
  get.("count-field", "/project_invoices?select=invoice_total.count()", []),
  get.(
    "group-by-field",
    "/project_invoices?select=invoice_total.sum(),invoice_total.max(),invoice_total.min(),project_id&order=project_id.desc",
    []
  ),
  get.(
    "group-by-aliased-field",
    "/project_invoices?select=invoice_total.sum(),invoice_total.max(),invoice_total.min(),pid:project_id&order=project_id.desc",
    []
  ),
  get.(
    "aggregate-alias",
    "/project_invoices?select=total_charged:invoice_total.sum(),project_id&order=project_id.desc",
    []
  ),
  get.(
    "aggregate-cast",
    "/project_invoices?select=total_charged:invoice_total.sum()::text,project_id&order=project_id.desc",
    []
  ),
  get.("input-cast", "/trash_details?select=jsonb_col-%3E%3Ekey::integer.sum()", []),
  get.(
    "alias-input-cast-cast",
    "/trash_details?select=s:jsonb_col-%3E%3Ekey::integer.sum()::text",
    []
  ),
  get.("rpc-table-result", "/rpc/getallprojects?select=id.max()", []),
  get.(
    "rpc-count-exact",
    "/rpc/getallprojects?select=client_id,id.max()&order=client_id",
    headers: [{"prefer", "count=exact"}]
  ),
  get.(
    "group-by-embed",
    "/project_invoices?select=project_id,total:invoice_total.sum(),projects(name)&order=project_id",
    []
  ),

  # --- aggregates inside embeds (AG:99-141) ---
  get.("embed-sum", "/projects?select=name,project_invoices(invoice_total.sum())", sort: true),
  get.("embed-max", "/projects?select=name,project_invoices(invoice_total.max())", sort: true),
  get.("embed-avg", "/projects?select=name,project_invoices(invoice_total.avg())", sort: true),
  get.("embed-min", "/projects?select=name,project_invoices(invoice_total.min())", sort: true),
  get.(
    "embed-all",
    "/projects?select=name,project_invoices(invoice_total.max(),invoice_total.min(),invoice_total.avg(),invoice_total.sum(),invoice_total.count())",
    sort: true
  ),

  # --- to-one spreads (AG:143-295) ---
  get.(
    "spread-grouped",
    "/budget_expenses?select=total_expenses:expense_amount.sum(),...budget_categories(budget_owner,total_budget:budget_amount.sum())&order=budget_categories(budget_owner)",
    []
  ),
  get.(
    "spread-only-aggregates",
    "/budget_expenses?select=...budget_categories(total_budget:budget_amount.sum())",
    []
  ),
  get.(
    "spread-grouped-by-other-spread",
    "/processes?select=...process_costs(cost.sum()),...process_categories(name)",
    sort: true
  ),
  get.(
    "spread-grouped-by-other-spread-aliased",
    "/processes?select=...process_costs(cost_sum:cost.sum()),...process_categories(category:name)",
    sort: true
  ),
  get.(
    "spread-nested",
    "/process_supervisor?select=...processes(factory_id,...process_costs(cost.sum()))",
    sort: true
  ),
  get.(
    "spread-nested-aliased",
    "/process_supervisor?select=...processes(factory_id,...process_costs(cost_sum:cost.sum()))",
    sort: true
  ),
  get.(
    "spread-nested-grouped-by-embed",
    "/process_supervisor?select=...processes(factories(name),...process_costs(cost.sum()))",
    sort: true
  ),
  get.(
    "spread-nested-grouped-by-embed-aliased",
    "/process_supervisor?select=...processes(factory:factories(name),...process_costs(cost_sum:cost.sum()))",
    sort: true
  ),
  get.(
    "spread-nested-grouped-by-spread",
    "/process_supervisor?select=supervisor_id,...processes(...process_costs(cost.sum()),...process_categories(name))&order=supervisor_id",
    sort: true
  ),
  get.(
    "spread-nested-grouped-by-spread-aliased",
    "/process_supervisor?select=supervisor_id,...processes(...process_costs(cost_sum:cost.sum()),...process_categories(category:name))&order=supervisor_id",
    sort: true
  ),
  get.(
    "spread-nested-in-embed",
    "/supervisors?select=name,process_supervisor(...processes(...process_costs(cost.sum()),...process_categories(name)))&order=id",
    []
  ),
  get.(
    "spread-nested-in-embed-aliased",
    "/supervisors?select=name,process_supervisor(...processes(...process_costs(cost_sum:cost.sum()),...process_categories(category:name)))&order=id",
    []
  ),
  get.(
    "spread-count",
    "/process_supervisor?select=supervisor_id,...processes(count())&order=supervisor_id",
    []
  ),
  get.(
    "spread-count-aliased",
    "/process_supervisor?select=supervisor_id,...processes(processes_count:count())&order=supervisor_id",
    []
  ),
  get.(
    "spread-count-with-columns",
    "/process_supervisor?select=...supervisors(id,count())&order=supervisors(id)",
    []
  ),
  get.(
    "spread-count-with-columns-aliased",
    "/process_supervisor?select=...supervisors(supervisor:id,supervisor_count:count())&order=supervisors(supervisor)",
    []
  ),
  get.(
    "spread-count-nested",
    "/process_supervisor?select=supervisor_id,...processes(...process_costs(count()))&order=supervisor_id",
    []
  ),
  get.(
    "spread-count-nested-aliased",
    "/process_supervisor?select=supervisor:supervisor_id,...processes(...process_costs(process_costs_count:count()))&order=supervisor_id",
    []
  ),
  get.(
    "spread-count-nested-grouped",
    "/process_supervisor?select=...processes(factory_id,...process_costs(count()))&order=processes(factory_id)",
    []
  ),
  get.(
    "spread-count-nested-grouped-aliased",
    "/process_supervisor?select=...processes(factory:factory_id,...process_costs(process_costs_count:count()))&order=processes(factory)",
    []
  ),
  get.(
    "spread-count-levels",
    "/process_supervisor?select=...processes(factory:factory_id,processes_count:count(),...process_costs(process_costs_count:count()))&order=processes(factory)",
    []
  ),

  # --- PgRest additions: aggregates with other request features ---
  # `count=exact` counts the aggregated rows, not the groups.
  get.(
    "count-exact-limited",
    "/project_invoices?select=project_id,invoice_total.sum()&limit=2&order=project_id",
    headers: [{"prefer", "count=exact"}]
  ),
  get.(
    "count-exact-spread",
    "/projects?select=client_id,...clients(cname:name),c:count()&order=client_id",
    headers: [{"prefer", "count=exact"}]
  ),
  get.("count-exact-legacy", "/entities?select=count", headers: [{"prefer", "count=exact"}]),
  # A JSON-path key is bound once: the group term is the select item, not a second binding.
  get.("group-by-json-path", "/trash_details?select=jsonb_col-%3E%3Ekey,c:count()", sort: true),
  get.("star-and-aggregate", "/projects?select=*,id.count()&order=id", []),
  get.(
    "embed-filtered",
    "/projects?select=name,project_invoices(invoice_total.sum())&project_invoices.invoice_total=gt.150&order=id",
    []
  ),
  get.(
    "inner-spread-filtered",
    "/project_invoices?select=...projects!inner(name),total:invoice_total.sum()&projects.name=like.W*",
    sort: true,
    headers: [{"prefer", "count=exact"}]
  ),
  get.(
    "object",
    "/entities?select=count()",
    headers: [{"accept", "application/vnd.pgrst.object+json"}]
  ),
  %{
    id: "aggregates/patch-representation",
    method: "PATCH",
    path: "/projects?id=lte.3&select=client_id,c:count()&order=client_id",
    body: %{"name" => "Renamed"},
    headers: [{"prefer", "return=representation, tx=rollback"}],
    stateful: true
  },
  get.("head", "/project_invoices?select=project_id,invoice_total.sum()", method: "HEAD"),

  # --- to-many spreads (AG:297-307) ---
  get.("to-many-spread", "/factories?select=name,...factory_buildings(type,size.sum())", []),

  # --- aggregates disabled (AG:309-354) ---
  get.("disabled", "/project_invoices?select=invoice_total.sum()", server: :limits),
  get.(
    "disabled-embed",
    "/projects?select=name,project_invoices(invoice_total.sum())",
    server: :limits
  ),
  get.("disabled-to-one-spread", "/project_invoices?select=...projects(id.count())",
    server: :limits
  ),
  get.("disabled-to-many-spread", "/factories?select=...processes(id.count())", server: :limits),
  pgrest_disabled.("plug-disabled", "/project_invoices?select=invoice_total.sum()"),
  pgrest_disabled.(
    "plug-disabled-embed",
    "/projects?select=name,project_invoices(invoice_total.sum())"
  ),
  pgrest_disabled.(
    "plug-disabled-to-one-spread",
    "/project_invoices?select=...projects(id.count())"
  ),
  pgrest_disabled.("plug-disabled-to-many-spread", "/factories?select=...processes(id.count())"),

  # --- postgrest-js (Supabase fixture) ---
  get.("supabase-embed-count", "/channels?select=id,messages(count)&order=id",
    fixture: :supabase
  ),
  get.(
    "supabase-embed-field-count",
    "/channels?select=id,messages(id.count())&order=id",
    fixture: :supabase
  ),
  get.(
    "supabase-embed-count-alias",
    "/channels?select=id,messages(message_count:count())&order=id",
    fixture: :supabase
  ),
  get.(
    "supabase-nested-count",
    "/users?select=username,messages(channels(count))&order=username",
    fixture: :supabase
  ),
  get.(
    "supabase-embed-sum",
    "/channels?select=id,messages(id.sum())&order=id",
    fixture: :supabase
  ),
  get.(
    "supabase-rpc",
    "/rpc/get_username_and_status?name_param=supabot&select=username.count(),status",
    fixture: :supabase
  ),
  get.(
    "supabase-missing-column",
    "/users?select=alias:missing_column.count()",
    fixture: :supabase
  )
]
