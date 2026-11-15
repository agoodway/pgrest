# Execution plans (Phase 2 Task 9): `Accept: application/vnd.pgrst.plan[+json|+text]`.
# Ported from upstream v14.18 PlanSpec (the shape and Content-Type cases; cost thresholds are
# planner numbers and are not compared), plus postgrest-js's `.explain()` on the Supabase
# fixture. Plans carry costs and timings, so every successful scenario compares with
# `compare: :plan` (status, headers and plan shape); error bodies are compared exactly.
# Writes run with `Prefer: tx=rollback` (`analyze` executes them).
plan_json = ~s(application/vnd.pgrst.plan+json)
plan_text = ~s(application/vnd.pgrst.plan+text)
rb = {"prefer", "tx=rollback"}

plan_for = fn target, options ->
  options = if options == "", do: "", else: "; options=" <> options
  {"accept", ~s(application/vnd.pgrst.plan+json; for="#{target}") <> options}
end

# What postgrest-js sends for `.explain(...)`: the original Accept as `for`, a trailing `;`.
js = fn format, options ->
  {"accept",
   ~s(application/vnd.pgrst.plan+#{format}; for="application/json"; options=#{options};)}
end

reads = [
  # --- PlanSpec: read table plan ---------------------------------------------------------
  {"single-filter-json", "/projects?id=in.(1,2,3)", [{"accept", plan_json}]},
  {"single-filter-text", "/projects?id=in.(1,2,3)", [{"accept", plan_text}]},
  {"default-is-text", "/projects?id=in.(1,2,3)", [{"accept", "application/vnd.pgrst.plan"}]},
  {"options-buffers", "/projects", [{"accept", plan_json <> "; options=buffers"}]},
  {"options-settings", "/projects", [{"accept", plan_json <> "; options=settings"}]},
  {"options-analyze-wal", "/projects", [{"accept", plan_json <> "; options=analyze|wal"}]},
  {"options-verbose", "/projects", [{"accept", plan_json <> "; options=verbose"}]},
  {"options-all-reordered", "/projects",
   [{"accept", plan_json <> "; options=wal|buffers|settings|verbose|analyze"}]},
  {"options-text-verbose", "/projects", [{"accept", plan_text <> "; options=verbose"}]},
  {"options-unknown-ignored", "/projects", [{"accept", plan_json <> "; options=foo|verbose"}]},
  {"options-empty-value", "/projects", [{"accept", plan_json <> "; options=;"}]},
  {"options-wrong-case-ignored", "/projects", [{"accept", plan_json <> "; options=Verbose"}]},
  {"for-json-verbose", "/projects", [plan_for.("application/json", "verbose")]},
  {"for-object-verbose", "/projects?id=eq.1",
   [plan_for.("application/vnd.pgrst.object", "verbose")]},
  {"for-object-many-rows", "/projects", [plan_for.("application/vnd.pgrst.object", "")]},
  {"for-object-json-name", "/projects?id=eq.1",
   [plan_for.("application/vnd.pgrst.object+json", "")]},
  {"for-array-stripped", "/projects?id=eq.1",
   [plan_for.("application/vnd.pgrst.array+json;nulls=stripped", "")]},
  {"for-object-stripped", "/projects?id=eq.1",
   [plan_for.("application/vnd.pgrst.object+json;nulls=stripped", "")]},
  {"for-array-plain", "/projects?id=eq.1", [plan_for.("application/vnd.pgrst.array+json", "")]},
  {"for-any", "/projects?id=eq.1", [plan_for.("*/*", "")]},
  {"for-csv", "/projects?select=id,name&id=eq.1", [plan_for.("text/csv", "verbose")]},
  {"for-csv-text", "/projects?select=id,name&id=eq.1",
   [{"accept", ~s(application/vnd.pgrst.plan; for="text/csv")}]},
  {"for-uppercase-type", "/projects?id=eq.1", [plan_for.("APPLICATION/JSON", "")]},
  # --- the plan is the statement's: window, count, embeds, aggregates ----------------------
  {"count-exact", "/projects?limit=1", [{"accept", plan_json}, {"prefer", "count=exact"}]},
  {"count-planned", "/projects?limit=1", [{"accept", plan_json}, {"prefer", "count=planned"}]},
  {"order-limit-offset", "/projects?order=name.desc&limit=2&offset=1", [{"accept", plan_json}]},
  {"range-header", "/projects?order=id", [{"accept", plan_json}, {"range", "0-1"}]},
  {"aggregate", "/projects?select=count()", [{"accept", plan_json}]},
  {"max-affected-not-enforced", "/projects",
   [{"accept", plan_json}, {"prefer", "handling=strict, max-affected=1"}]},
  # --- PlanSpec: resource embedding ------------------------------------------------------
  {"embed-one-to-many", "/clients?select=*,projects(*)&id=eq.1", [{"accept", plan_json}]},
  {"embed-many-to-one", "/projects?select=*,clients(*)&id=eq.1", [{"accept", plan_json}]},
  {"embed-many-to-many", "/users?select=*,tasks(*)&id=eq.1", [{"accept", plan_json}]},
  {"embed-inner-o2m", "/clients?select=*,projects!inner(*)&id=eq.1", [{"accept", plan_json}]},
  {"embed-not-null-o2m", "/clients?select=*,projects(*)&projects=not.is.null&id=eq.1",
   [{"accept", plan_json}]},
  {"embed-inner-m2o", "/projects?select=*,clients!inner(*)&id=eq.1", [{"accept", plan_json}]},
  {"embed-inner-m2m", "/users?select=*,tasks!inner(*)&tasks.id=eq.1", [{"accept", plan_json}]},
  {"embed-spread", "/projects?select=name,...clients(client:name)&id=eq.1",
   [{"accept", plan_json}]},
  # --- Accept negotiation around the plan type -------------------------------------------
  {"accept-q-below-json", "/projects?id=eq.1",
   [{"accept", "application/vnd.pgrst.plan;q=0.5, application/json"}]},
  {"accept-csv-before-plan", "/projects?select=id&id=eq.1",
   [{"accept", "text/csv, application/vnd.pgrst.plan"}]},
  {"accept-plan-before-json", "/projects?id=eq.1",
   [{"accept", "application/vnd.pgrst.plan, application/json"}]},
  {"accept-unknown-for-falls-back", "/projects?id=eq.1",
   [{"accept", ~s(application/vnd.pgrst.plan; for="text/xml", application/json)}]}
]

# --- PlanSpec: function plans and index usage ----------------------------------------------
rpc = [
  {"rpc-setof", "/rpc/getallprojects?id=in.(1,2,3)", [{"accept", plan_json}]},
  {"rpc-setof-text", "/rpc/getallprojects", [{"accept", "application/vnd.pgrst.plan"}]},
  {"rpc-setof-args", "/rpc/getproject?id=3", [{"accept", plan_json}]},
  {"rpc-scalar", "/rpc/add_them?a=3&b=4", [{"accept", plan_json}]},
  {"rpc-inlined-sql-function", "/rpc/getitemrange?min=10&max=15",
   [{"accept", "application/vnd.pgrst.plan"}]},
  {"rpc-void", "/rpc/ret_void", [{"accept", plan_json}]},
  {"rpc-for-csv", "/rpc/getallprojects?select=name", [plan_for.("text/csv", "")]},
  {"rpc-for-object", "/rpc/getproject?id=1", [plan_for.("application/vnd.pgrst.object", "")]},
  {"rpc-count-exact", "/rpc/getallprojects?limit=1",
   [{"accept", plan_json}, {"prefer", "count=exact"}]},
  {"rpc-analyze-stable", "/rpc/getallprojects?id=eq.1",
   [{"accept", plan_json <> "; options=analyze"}]}
]

errors = [
  {"wal-without-analyze", "/projects", [{"accept", plan_json <> "; options=wal"}]},
  {"unknown-table", "/nosuchtable", [{"accept", plan_json}]},
  {"unknown-column", "/projects?select=nope", [{"accept", plan_json}]},
  {"bad-filter", "/projects?id=eq.", [{"accept", plan_json}]},
  {"for-text-xml", "/projects", [plan_for.("text/xml", "")]},
  {"for-octet-stream", "/projects", [plan_for.("application/octet-stream", "")]},
  {"for-text-plain-with-options", "/projects", [plan_for.("text/plain", "verbose|buffers")]},
  {"for-plan-nested", "/projects",
   [{"accept", ~s(application/vnd.pgrst.plan; for="application/vnd.pgrst.plan")}]}
]

# --- writes: every one rolls back, `analyze` really executes it --------------------------
insert = %{"id" => 100, "name" => "Project 100", "client_id" => 1}

writes = [
  {"insert", "POST", "/projects", [{"accept", plan_json}, rb], insert},
  {"insert-analyze", "POST", "/projects", [{"accept", plan_json <> "; options=analyze"}, rb],
   insert},
  {"insert-representation-object-verbose", "POST", "/projects",
   [
     plan_for.("application/vnd.pgrst.object", "verbose"),
     {"prefer", "return=representation, tx=rollback"}
   ], insert},
  {"insert-bulk-analyze", "POST", "/projects", [{"accept", plan_json <> "; options=analyze"}, rb],
   for(i <- 100..109, do: %{"id" => i, "name" => "P#{i}", "client_id" => 1})},
  {"insert-text", "POST", "/projects", [{"accept", "application/vnd.pgrst.plan"}, rb], insert},
  {"insert-bad-column", "POST", "/projects", [{"accept", plan_json}, rb],
   %{"id" => 100, "nope" => 1}},
  {"insert-keys-differ", "POST", "/projects", [{"accept", plan_json}, rb],
   [%{"id" => 100, "name" => "a"}, %{"id" => 101}]},
  {"update", "PATCH", "/projects?id=eq.3", [{"accept", plan_json}, rb], %{"name" => "Patched"}},
  {"update-analyze", "PATCH", "/projects?id=eq.3",
   [{"accept", plan_json <> "; options=analyze"}, rb], %{"name" => "Patched"}},
  {"delete", "DELETE", "/projects?id=in.(1,2,3)", [{"accept", plan_json}, rb], nil},
  {"delete-analyze", "DELETE", "/items?id=in.(1,2,3)",
   [{"accept", plan_json <> "; options=analyze"}, rb], nil},
  {"delete-object-verbose", "DELETE", "/projects?id=eq.6",
   [
     plan_for.("application/vnd.pgrst.object", "verbose"),
     {"prefer", "return=representation, tx=rollback"}
   ], nil},
  {"upsert-merge", "POST", "/tiobe_pls",
   [{"accept", plan_json}, {"prefer", "resolution=merge-duplicates, tx=rollback"}],
   [%{"name" => "Python", "rank" => 19}, %{"name" => "Go", "rank" => 20}]},
  {"upsert-merge-analyze", "POST", "/tiobe_pls",
   [
     {"accept", plan_json <> "; options=analyze"},
     {"prefer", "resolution=merge-duplicates, tx=rollback"}
   ], for(i <- 1..10, do: %{"name" => "L#{i}", "rank" => i})},
  {"upsert-ignore", "POST", "/tiobe_pls",
   [{"accept", plan_json}, {"prefer", "resolution=ignore-duplicates, tx=rollback"}],
   %{"name" => "Go", "rank" => 20}},
  {"rpc-post-volatile", "POST", "/rpc/getproject", [{"accept", plan_json}, rb], %{"id" => 1}},
  {"rpc-post-volatile-analyze", "POST", "/rpc/setprojects",
   [{"accept", plan_json <> "; options=analyze"}, rb],
   %{"id_l" => 1, "id_h" => 2, "name" => "x"}},
  {"rpc-post-scalar", "POST", "/rpc/add_them", [{"accept", plan_json}, rb], %{"a" => 1, "b" => 2}}
]

# These fall back to another type, so their body is no plan: compared exactly.
not_plans = ~w(accept-csv-before-plan accept-q-below-json accept-unknown-for-falls-back)

read_scenarios =
  for {name, path, headers} <- reads ++ rpc do
    %{
      id: "plan/" <> name,
      path: path,
      headers: headers,
      compare: if(name in not_plans, do: :exact, else: :plan)
    }
  end

error_scenarios =
  for {name, path, headers} <- errors do
    %{id: "plan/" <> name, path: path, headers: headers, compare: :plan}
  end

write_scenarios =
  for {name, method, path, headers, body} <- writes do
    %{
      id: "plan/" <> name,
      method: method,
      path: path,
      headers: headers,
      body: body,
      stateful: true,
      compare: :plan
    }
  end

# --- postgrest-js `.explain()` (Supabase fixture) ------------------------------------------
supabase =
  for {name, path, headers} <- [
        {"supabase-explain-default", "/users?select=*", [js.(:text, "")]},
        {"supabase-explain-analyze", "/users?select=*", [js.(:text, "analyze")]},
        {"supabase-explain-json", "/users?select=*", [js.(:json, "")]},
        {"supabase-explain-json-analyze", "/users?select=*&status=eq.ONLINE",
         [js.(:json, "analyze")]},
        {"supabase-explain-verbose-settings-buffers", "/users?select=*",
         [js.(:json, "verbose|settings|buffers")]},
        {"supabase-explain-all-options", "/users?select=*",
         [js.(:json, "analyze|verbose|settings|buffers|wal")]},
        {"supabase-explain-wal-without-analyze", "/users?select=*",
         [js.(:json, "verbose|settings|buffers|wal")]},
        {"supabase-explain-single", "/users?select=*&username=eq.supabot",
         [
           {"accept",
            ~s(application/vnd.pgrst.plan+text; for="application/vnd.pgrst.object+json"; options=;)}
         ]},
        {"supabase-explain-embed", "/channels?select=id,messages(id)&limit=1",
         [js.(:json, "verbose")]},
        {"supabase-explain-csv", "/users?select=*",
         [{"accept", ~s(application/vnd.pgrst.plan+text; for="text/csv"; options=;)}]},
        {"supabase-explain-accept-profile", "/users?select=username",
         [{"accept-profile", "personal"}, js.(:text, "")]},
        {"supabase-explain-rpc", "/rpc/get_status?name_param=supabot", [js.(:json, "")]}
      ] do
    %{id: "plan/" <> name, fixture: :supabase, path: path, headers: headers, compare: :plan}
  end

supabase_writes = [
  %{
    id: "plan/supabase-explain-insert-analyze",
    fixture: :supabase,
    method: "POST",
    path: "/users",
    headers: [js.(:json, "analyze"), rb],
    body: %{"username" => "plan_user"},
    stateful: true,
    compare: :plan
  },
  %{
    id: "plan/supabase-explain-insert-content-profile",
    fixture: :supabase,
    method: "POST",
    path: "/users",
    headers: [{"content-profile", "personal"}, js.(:json, ""), rb],
    body: %{"username" => "plan_user"},
    stateful: true,
    compare: :plan
  },
  %{
    id: "plan/supabase-explain-update",
    fixture: :supabase,
    method: "PATCH",
    path: "/users?username=eq.supabot",
    headers: [js.(:json, "analyze"), rb],
    body: %{"status" => "OFFLINE"},
    stateful: true,
    compare: :plan
  },
  %{
    id: "plan/supabase-explain-delete",
    fixture: :supabase,
    method: "DELETE",
    path: "/messages?id=eq.1",
    headers: [js.(:json, "analyze"), rb],
    stateful: true,
    compare: :plan
  }
]

# --- not offered: `plan_enabled: false` is PGRST107 (PostgREST's db-plan-enabled default) ---
disabled_body = fn type ->
  %{
    "code" => "PGRST107",
    "details" => nil,
    "hint" => nil,
    "message" => "None of these media types are available: " <> type
  }
end

disabled = fn id, method, path, headers, body ->
  %{
    id: "plan/" <> id,
    method: method,
    path: path,
    headers: headers,
    body: body,
    stateful: method != "GET",
    plug_opts: [plan_enabled: false],
    only: :pgrest,
    expect: %{
      status: 406,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: disabled_body.(~s(application/vnd.pgrst.plan+text; for="application/json"))
    }
  }
end

disabled_scenarios = [
  disabled.(
    "disabled-table",
    "GET",
    "/projects?id=in.(1,2,3)",
    [{"accept", "application/vnd.pgrst.plan"}],
    nil
  ),
  disabled.(
    "disabled-rpc",
    "GET",
    "/rpc/getallprojects?id=in.(1,2,3)",
    [{"accept", "application/vnd.pgrst.plan"}],
    nil
  ),
  disabled.(
    "disabled-delete",
    "DELETE",
    "/projects?id=in.(1,2,3)",
    [{"accept", "application/vnd.pgrst.plan"}, rb],
    nil
  ),
  disabled.(
    "disabled-insert",
    "POST",
    "/projects",
    [{"accept", "application/vnd.pgrst.plan"}, rb],
    insert
  )
]

# PostgREST also serves `for="application/geo+json"` (its PostGIS aggregate; a 404 `42883`
# without PostGIS): never offered here (`PgRest.Negotiate`).
geo = %{
  id: "plan/for-geo-json",
  path: "/projects",
  headers: [plan_for.("application/geo+json", "")],
  only: :pgrest,
  expect: %{
    status: 406,
    headers: %{"content-type" => "application/json; charset=utf-8"},
    body: disabled_body.(~s(application/vnd.pgrst.plan+json; for="application/geo+json"))
  }
}

read_scenarios ++
  error_scenarios ++
  write_scenarios ++ supabase ++ supabase_writes ++ disabled_scenarios ++ [geo]
