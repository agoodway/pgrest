# RPC execution (Phase 2 Task 6): GET/POST/HEAD /rpc/<fn>, return shapes, volatility, embeds,
# counts and argument binding. Ported from PostgREST's RpcSpec (03 §9) and supabase-js's RPC
# tests (05 §9). Every POST /rpc scenario rolls back (`Scenario` adds `Prefer: tx=rollback`).
count = {"prefer", "count=exact"}
json = {"content-type", "application/json"}

[
  # --- test fixture: resource returns ------------------------------------------------
  %{id: "rpc/getproject-get", path: "/rpc/getproject?id=1"},
  %{id: "rpc/getproject-post", method: "POST", path: "/rpc/getproject", body: %{"id" => 1}},
  %{id: "rpc/getallprojects-filters", path: "/rpc/getallprojects?id=gt.1&id=lt.5&select=id"},
  %{
    id: "rpc/getallprojects-filters-window",
    path: "/rpc/getallprojects?id=gt.1&id=lt.5&select=id&limit=2&offset=1"
  },
  %{
    id: "rpc/getallprojects-count-window",
    path: "/rpc/getallprojects?select=id,clients(id)&limit=2&offset=1",
    headers: [count]
  },
  %{
    id: "rpc/getallprojects-head-count",
    method: "HEAD",
    path: "/rpc/getallprojects",
    headers: [count]
  },
  %{
    id: "rpc/getallprojects-count-planned",
    path: "/rpc/getallprojects?limit=1",
    headers: [{"prefer", "count=planned"}]
  },
  %{
    id: "rpc/getallprojects-count-estimated",
    path: "/rpc/getallprojects?limit=1",
    headers: [{"prefer", "count=estimated"}]
  },
  %{
    id: "rpc/getproject-post-array",
    method: "POST",
    path: "/rpc/getproject",
    body: [%{"id" => 1}, %{"id" => 2}]
  },
  %{id: "rpc/getproject-arg-and-filter", path: "/rpc/getproject?id=1&id=eq.1"},
  %{
    id: "rpc/getallprojects-inner-embed",
    path: "/rpc/getallprojects?select=id,clients!inner(id)&clients.id=eq.1"
  },
  %{
    id: "rpc/getproject-embeds-post",
    method: "POST",
    path: "/rpc/getproject?select=id,name,client:clients(id),tasks(id)",
    body: %{"id" => 1}
  },
  %{id: "rpc/getallprojects-unknown-column", path: "/rpc/getallprojects?select=nope"},
  %{
    id: "rpc/getitemrange-range-count",
    path: "/rpc/getitemrange?min=2&max=10&select=id",
    headers: [{"range", "1-3"}, count]
  },
  %{
    id: "rpc/getitemrange-alias",
    path: "/rpc/getitemrange?min=2&max=4&select=id,foo:id"
  },
  %{
    id: "rpc/getproject-object",
    path: "/rpc/getproject?id=1",
    headers: [{"accept", "application/vnd.pgrst.object+json"}]
  },
  # --- scalar and void returns -------------------------------------------------------
  %{id: "rpc/add-them-get", path: "/rpc/add_them?a=1&b=2"},
  %{id: "rpc/add-them-post", method: "POST", path: "/rpc/add_them", body: %{"a" => 1, "b" => 2}},
  %{id: "rpc/add-them-count", path: "/rpc/add_them?a=3&b=4", headers: [count]},
  %{id: "rpc/add-them-head", method: "HEAD", path: "/rpc/add_them?a=1&b=2"},
  %{id: "rpc/add-them-filter", path: "/rpc/add_them?a=1&b=2&x=eq.1"},
  %{id: "rpc/add-them-select", path: "/rpc/add_them?a=1&b=2&select=x"},
  %{id: "rpc/add-them-order", path: "/rpc/add_them?a=1&b=2&order=x"},
  %{id: "rpc/add-them-limit-zero", path: "/rpc/add_them?a=1&b=2&limit=0"},
  %{
    id: "rpc/add-them-null-arg",
    method: "POST",
    path: "/rpc/add_them",
    body: %{"a" => 1, "b" => nil}
  },
  %{
    id: "rpc/add-them-columns",
    method: "POST",
    path: "/rpc/add_them?columns=a,b",
    body: %{"a" => 1, "b" => 2, "c" => 3}
  },
  %{
    id: "rpc/add-them-array-body",
    method: "POST",
    path: "/rpc/add_them",
    body: [%{"a" => 1, "b" => 2}, %{"a" => 3, "b" => 4}]
  },
  %{
    id: "rpc/add-them-non-object-array",
    method: "POST",
    path: "/rpc/add_them",
    body: [1, 2]
  },
  %{
    id: "rpc/add-them-object",
    path: "/rpc/add_them?a=1&b=2",
    headers: [{"accept", "application/vnd.pgrst.object+json"}]
  },
  %{id: "rpc/add-them-malformed-get", path: "/rpc/add_them?a=abc&b=2"},
  %{
    id: "rpc/add-them-malformed-post",
    method: "POST",
    path: "/rpc/add_them",
    body: %{"a" => "abc", "b" => 2}
  },
  %{id: "rpc/sayhello-text", path: "/rpc/sayhello?name=world"},
  %{id: "rpc/sayhello-repeated", path: "/rpc/sayhello?name=ignored&name=world"},
  %{id: "rpc/noparamsproc-get", path: "/rpc/noparamsproc"},
  %{id: "rpc/noparamsproc-post-empty", method: "POST", path: "/rpc/noparamsproc"},
  %{id: "rpc/ret-void-get", path: "/rpc/ret_void"},
  %{id: "rpc/ret-void-post", method: "POST", path: "/rpc/ret_void", body: %{}},
  %{id: "rpc/ret-void-filter", path: "/rpc/ret_void?x=eq.1"},
  # --- methods -----------------------------------------------------------------------
  %{
    id: "rpc/delete-not-allowed",
    method: "DELETE",
    path: "/rpc/add_them",
    headers: [{"prefer", "tx=rollback"}],
    stateful: true
  },
  %{
    id: "rpc/patch-not-allowed",
    method: "PATCH",
    path: "/rpc/add_them",
    headers: [{"prefer", "tx=rollback"}],
    body: %{"a" => 1},
    stateful: true
  },
  %{
    id: "rpc/put-not-allowed",
    method: "PUT",
    path: "/rpc/add_them",
    headers: [{"prefer", "tx=rollback"}],
    body: %{"a" => 1},
    stateful: true
  },
  # --- json params -------------------------------------------------------------------
  %{
    id: "rpc/unnamed-json-echo",
    method: "POST",
    path: "/rpc/unnamed_json_param",
    body: %{"A" => 1, "B" => [2]}
  },
  %{
    id: "rpc/unnamed-json-array",
    method: "POST",
    path: "/rpc/unnamed_json_param",
    body: [%{"a" => 1}]
  },
  %{
    id: "rpc/unnamed-json-scalar",
    method: "POST",
    path: "/rpc/unnamed_json_param",
    headers: [json],
    body: "\"x\""
  },
  %{
    id: "rpc/named-json-param",
    method: "POST",
    path: "/rpc/named_json_param",
    body: %{"data" => %{"a" => [1, 2]}}
  },
  # --- variadic ----------------------------------------------------------------------
  %{id: "rpc/variadic-get", path: "/rpc/variadic_param?v=hi&v=there"},
  %{id: "rpc/variadic-none", path: "/rpc/variadic_param"},
  %{id: "rpc/variadic-one", path: "/rpc/variadic_param?v=hi"},
  %{
    id: "rpc/variadic-post",
    method: "POST",
    path: "/rpc/variadic_param",
    body: %{"v" => ["hi", "there"]}
  },
  # --- OUT params --------------------------------------------------------------------
  %{id: "rpc/single-out-param", path: "/rpc/single_out_param?num=5"},
  %{id: "rpc/single-out-param-filter", path: "/rpc/single_out_param?num=5&num_plus_one=eq.1"},
  %{id: "rpc/single-inout-param", path: "/rpc/single_inout_param?num=2"},
  %{id: "rpc/many-out-params", path: "/rpc/many_out_params"},
  %{id: "rpc/many-out-params-select", path: "/rpc/many_out_params?select=num,str"},
  %{id: "rpc/many-out-params-unknown-column", path: "/rpc/many_out_params?select=nope"},
  %{id: "rpc/many-out-params-embed", path: "/rpc/many_out_params?select=num,clients(id)"},
  %{
    id: "rpc/many-out-params-csv",
    path: "/rpc/many_out_params",
    headers: [{"accept", "text/csv"}]
  },
  # --- volatility --------------------------------------------------------------------
  %{id: "rpc/volatile-write-get", path: "/rpc/callcounter"},
  %{id: "rpc/volatile-update-get", path: "/rpc/setprojects?id_l=1&id_h=2&name=x"},
  %{id: "rpc/volatile-read-get", path: "/rpc/getallprojects?select=id&id=eq.1"},
  %{
    id: "rpc/volatile-write-post",
    method: "POST",
    path: "/rpc/setprojects?select=id,name",
    headers: [{"prefer", "tx=rollback"}],
    body: %{"id_l" => 1, "id_h" => 2, "name" => "renamed"},
    stateful: true
  },
  # --- supabase fixture ----------------------------------------------------------------
  %{
    id: "rpc/supabase-get-status-post",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/get_status",
    body: %{"name_param" => "supabot"}
  },
  %{
    id: "rpc/supabase-get-status-get-count",
    fixture: :supabase,
    path: "/rpc/get_status?name_param=supabot",
    headers: [count]
  },
  %{
    id: "rpc/supabase-get-status-head-count",
    fixture: :supabase,
    method: "HEAD",
    path: "/rpc/get_status?name_param=supabot",
    headers: [count]
  },
  %{
    id: "rpc/supabase-get-status-personal",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/get_status",
    headers: [{"content-profile", "personal"}],
    body: %{"name_param" => "leroyjenkins"}
  },
  %{
    id: "rpc/supabase-username-and-status",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/get_username_and_status",
    body: %{"name_param" => "supabot"}
  },
  %{
    id: "rpc/supabase-username-and-status-select",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/get_username_and_status?select=status",
    body: %{"name_param" => "supabot"}
  },
  %{
    id: "rpc/supabase-username-and-status-neq",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/get_username_and_status?select=status&status=neq.ONLINE",
    body: %{"name_param" => "supabot"}
  },
  %{
    id: "rpc/supabase-get-messages-channel-row",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/get_messages?select=id,message&order=id",
    body: %{"channel_row" => %{"id" => 1, "data" => nil, "slug" => "public"}}
  },
  %{
    id: "rpc/supabase-get-messages-user-row",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/get_messages?select=id,channel_id&order=id",
    body: %{"user_row" => %{"username" => "supabot", "status" => "ONLINE"}}
  },
  %{
    id: "rpc/supabase-get-user-profile",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/get_user_profile",
    body: %{"user_row" => %{"username" => "supabot"}}
  },
  %{
    id: "rpc/supabase-get-user-profile-filtered",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/get_user_profile?username=eq.nope",
    body: %{"user_row" => %{"username" => "supabot"}}
  },
  %{
    id: "rpc/supabase-function-returning-row",
    fixture: :supabase,
    path: "/rpc/function_returning_row?select=username"
  },
  %{
    id: "rpc/supabase-function-returning-set-of-rows",
    fixture: :supabase,
    path: "/rpc/function_returning_set_of_rows?select=username&order=username"
  },
  %{
    id: "rpc/supabase-setof-rows-one",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/function_using_setof_rows_one",
    body: %{"user_row" => %{"username" => "supabot"}}
  },
  %{
    id: "rpc/supabase-echo-bigint",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/echo_bigint_as_text",
    body: %{"bigint_param" => "9223372036854775807"}
  },
  %{
    id: "rpc/supabase-optional-param",
    fixture: :supabase,
    path: "/rpc/function_with_optional_param"
  },
  %{
    id: "rpc/supabase-array-param",
    fixture: :supabase,
    path: "/rpc/function_with_array_param?param=%7B00000000-0000-0000-0000-000000000000%7D"
  },
  %{
    id: "rpc/supabase-recent-messages-embed",
    fixture: :supabase,
    path:
      "/rpc/get_recent_messages_by_username?search_username=supabot" <>
        "&select=channel_id,message,users(username,catchphrase)&order=message"
  },
  %{id: "rpc/supabase-void-func", fixture: :supabase, method: "POST", path: "/rpc/void_func"}
]
