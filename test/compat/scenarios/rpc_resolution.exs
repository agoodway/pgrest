# RPC resolution errors (PGRST202 / PGRST203). `/rpc` routing lands in Task 6, so these stay
# in pending.txt until then.
[
  # --- test fixture ----------------------------------------------------------------
  %{id: "rpc_resolution/get-unknown-function", path: "/rpc/sayhell"},
  %{id: "rpc_resolution/get-unknown-arg-hint", path: "/rpc/sayhello?nam=Peter"},
  %{id: "rpc_resolution/get-extra-arg", path: "/rpc/add_them?a=1&b=2&smthelse=blabla"},
  %{id: "rpc_resolution/get-missing-arg", path: "/rpc/add_them?a=1"},
  %{id: "rpc_resolution/get-no-params-unknown", path: "/rpc/noparamsprox"},
  %{id: "rpc_resolution/get-overloaded", path: "/rpc/overloaded_same_args?arg=1"},
  %{id: "rpc_resolution/get-overloaded-enum", path: "/rpc/overloaded_enum_arg?arg=draft"},
  %{
    id: "rpc_resolution/post-overloaded",
    method: "POST",
    path: "/rpc/overloaded_same_args",
    body: %{"arg" => 1}
  },
  %{
    id: "rpc_resolution/post-unknown-function",
    method: "POST",
    path: "/rpc/sayhell",
    body: %{"name" => "x"}
  },
  %{
    id: "rpc_resolution/post-named-json-param",
    method: "POST",
    path: "/rpc/named_json_param",
    body: %{"A" => 1, "B" => 2, "C" => 3}
  },
  %{
    id: "rpc_resolution/post-unnamed-json-param",
    method: "POST",
    path: "/rpc/unnamed_json_param",
    body: %{"A" => 1, "B" => 2, "C" => 3}
  },
  %{
    id: "rpc_resolution/get-unnamed-json-param",
    path: "/rpc/unnamed_json_param?a=1"
  },
  # --- non-JSON bodies (single unnamed text/xml/bytea parameter) -----------------------
  %{
    id: "rpc_resolution/post-text-unknown-function",
    method: "POST",
    path: "/rpc/sayhell",
    headers: [{"content-type", "text/plain"}],
    body: "x"
  },
  %{
    id: "rpc_resolution/post-text-no-params-function",
    method: "POST",
    path: "/rpc/noparamsproc",
    headers: [{"content-type", "text/plain"}],
    body: "x"
  },
  %{
    id: "rpc_resolution/post-text-to-json-param",
    method: "POST",
    path: "/rpc/unnamed_json_param",
    headers: [{"content-type", "text/plain"}],
    body: "x"
  },
  %{
    id: "rpc_resolution/post-xml-unknown-function",
    method: "POST",
    path: "/rpc/sayhell",
    headers: [{"content-type", "text/xml"}],
    body: "<a/>"
  },
  %{
    id: "rpc_resolution/post-bytea-unknown-function",
    method: "POST",
    path: "/rpc/sayhell",
    headers: [{"content-type", "application/octet-stream"}],
    body: "x"
  },
  %{
    id: "rpc_resolution/supabase-text-to-unnamed-xml",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/polymorphic_function_with_unnamed_text",
    headers: [{"content-type", "text/xml"}],
    body: "<a/>"
  },
  # --- supabase fixture ------------------------------------------------------------
  %{
    id: "rpc_resolution/supabase-unresolvable-function",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/postgrest_unresolvable_function",
    body: %{"a" => "test"}
  },
  %{
    id: "rpc_resolution/supabase-unnamed-integer",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/polymorphic_function_with_unnamed_integer",
    body: %{"" => 1}
  },
  %{
    id: "rpc_resolution/supabase-blurb-message-no-args",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/blurb_message"
  },
  %{
    id: "rpc_resolution/supabase-blurb-message-unnamed",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/blurb_message",
    body: %{"" => %{"id" => 1}}
  },
  %{
    id: "rpc_resolution/supabase-created-ago",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/created_ago",
    body: %{"id" => 1}
  }
]
