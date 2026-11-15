# Response GUCs (Phase 2 Task 6b): `response.headers` / `response.status` set by functions,
# triggers and `pre_request`. Ported from PostgREST's RpcSpec "GUC headers on function calls" and
# the `stuff` trigger scenarios. `response_headers` names the custom headers each one asserts.
rb = {"prefer", "tx=rollback"}
guc = ["x-test", "x-test-2"]

[
  # --- GUC headers on function calls --------------------------------------------------
  %{
    id: "response_gucs/projects-get",
    path: "/rpc/get_projects_and_guc_headers?id=eq.2&select=id",
    response_headers: guc
  },
  %{
    id: "response_gucs/projects-head",
    method: "HEAD",
    path: "/rpc/get_projects_and_guc_headers?id=eq.2&select=id",
    response_headers: guc
  },
  %{
    id: "response_gucs/int-get",
    path: "/rpc/get_int_and_guc_headers?num=1",
    response_headers: guc
  },
  %{
    id: "response_gucs/int-post",
    method: "POST",
    path: "/rpc/get_int_and_guc_headers",
    body: %{"num" => 1},
    response_headers: guc
  },
  %{
    id: "response_gucs/projects-object-media",
    path: "/rpc/get_projects_and_guc_headers?id=eq.2&select=id",
    headers: [{"accept", "application/vnd.pgrst.object+json"}],
    response_headers: guc
  },

  # --- malformed response.headers -------------------------------------------------------
  %{id: "response_gucs/bad-headers-1-get", path: "/rpc/bad_guc_headers_1"},
  %{id: "response_gucs/bad-headers-2-get", path: "/rpc/bad_guc_headers_2"},
  %{id: "response_gucs/bad-headers-3-get", path: "/rpc/bad_guc_headers_3"},
  %{
    id: "response_gucs/bad-headers-1-post",
    method: "POST",
    path: "/rpc/bad_guc_headers_1",
    body: %{}
  },
  # Both GUCs malformed: PostgREST decodes the status first (Response.hs overrideStatusHeaders).
  %{id: "response_gucs/both-bad-get", path: "/rpc/guc_both_bad"},

  # --- repeated headers, trigger overrides ------------------------------------------------
  %{
    id: "response_gucs/set-cookie-twice",
    method: "POST",
    path: "/rpc/set_cookie_twice",
    response_headers: ["set-cookie"]
  },
  %{
    id: "response_gucs/set-cookie-twice-get",
    path: "/rpc/set_cookie_twice",
    response_headers: ["set-cookie"]
  },
  %{
    id: "response_gucs/insert-location-override",
    method: "POST",
    path: "/stuff",
    headers: [{"prefer", "return=headers-only, tx=rollback"}],
    body: [%{"id" => 2, "name" => "stuff 2"}],
    stateful: true
  },
  %{
    id: "response_gucs/insert-location-override-minimal",
    method: "POST",
    path: "/stuff",
    headers: [rb],
    body: [%{"id" => 2, "name" => "stuff 2"}],
    stateful: true
  },
  %{
    id: "response_gucs/insert-location-override-representation",
    method: "POST",
    path: "/stuff",
    headers: [{"prefer", "return=representation, tx=rollback"}],
    body: [%{"id" => 2, "name" => "stuff 2"}],
    stateful: true
  },
  # An AFTER trigger fires after the statement's own select list is evaluated, so PostgREST
  # (and PgRest, which reads the GUCs the same way) answers the generated Location.
  %{
    id: "response_gucs/insert-after-trigger-location-not-visible",
    method: "POST",
    path: "/pgrest_after_loc",
    headers: [{"prefer", "return=headers-only, tx=rollback"}],
    body: %{"id" => 2, "c" => "b"},
    stateful: true
  },

  # --- no blank headers (RpcSpec "Blank headers bug"; `loc_test` has no trigger) -------------
  %{
    id: "response_gucs/blank-headers-post",
    method: "POST",
    path: "/loc_test",
    headers: [rb],
    body: %{"id" => "1", "c" => "c1"},
    stateful: true
  },
  %{
    id: "response_gucs/blank-headers-patch",
    method: "PATCH",
    path: "/loc_test?id=eq.1",
    headers: [rb],
    body: %{"c" => "c2"},
    stateful: true
  },
  %{id: "response_gucs/blank-headers-get", path: "/loc_test"},
  %{
    id: "response_gucs/blank-headers-delete",
    method: "DELETE",
    path: "/loc_test?id=eq.1",
    headers: [rb],
    stateful: true
  },

  # --- response.status ------------------------------------------------------------------
  %{id: "response_gucs/status-403-get", path: "/rpc/send_body_status_403"},
  %{id: "response_gucs/status-403-post", method: "POST", path: "/rpc/send_body_status_403"},
  %{id: "response_gucs/status-403-head", method: "HEAD", path: "/rpc/send_body_status_403"},
  %{
    id: "response_gucs/status-trigger-205",
    method: "PATCH",
    path: "/stuff?id=eq.1",
    headers: [rb],
    body: [%{"name" => "updated stuff 1"}],
    stateful: true
  },
  %{
    id: "response_gucs/status-trigger-205-representation",
    method: "PATCH",
    path: "/stuff?id=eq.1",
    headers: [{"prefer", "return=representation, tx=rollback"}],
    body: [%{"name" => "updated stuff 1"}],
    stateful: true
  },
  %{id: "response_gucs/bad-status", path: "/rpc/send_bad_status"},
  %{id: "response_gucs/status-then-raise", method: "POST", path: "/rpc/status_then_raise"},

  # --- edge forms of response.status (PostgREST's reading is the recording) -----------------
  # PostgREST takes the leading digits (`403abc` is 403, ` 403`, `+403` and `-403` are PGRST112)
  # and sends any number, but a status outside 200..999 (`0`, `99`, `1000`) is a malformed status
  # line no client parses and `100` never completes, so those are unit-tested, not recorded.
  %{
    id: "response_gucs/status-form-403abc",
    method: "POST",
    path: "/rpc/guc_status",
    body: %{"code" => "403abc"}
  },
  %{
    id: "response_gucs/status-form-999",
    method: "POST",
    path: "/rpc/guc_status",
    body: %{"code" => "999"}
  },
  %{
    id: "response_gucs/status-form-leading-space",
    method: "POST",
    path: "/rpc/guc_status",
    body: %{"code" => " 403"}
  },
  %{
    id: "response_gucs/status-form-trailing-space",
    method: "POST",
    path: "/rpc/guc_status",
    body: %{"code" => "403 "}
  },
  %{
    id: "response_gucs/status-form-plus",
    method: "POST",
    path: "/rpc/guc_status",
    body: %{"code" => "+403"}
  },
  %{
    id: "response_gucs/status-form-leading-zero",
    method: "POST",
    path: "/rpc/guc_status",
    body: %{"code" => "0403"}
  },
  %{
    id: "response_gucs/status-form-negative",
    method: "POST",
    path: "/rpc/guc_status",
    body: %{"code" => "-403"}
  },
  %{
    id: "response_gucs/status-form-empty",
    method: "POST",
    path: "/rpc/guc_status",
    body: %{"code" => ""}
  },
  %{
    id: "response_gucs/status-form-200",
    method: "POST",
    path: "/rpc/guc_status",
    body: %{"code" => "200"}
  },
  %{
    id: "response_gucs/status-form-418",
    method: "POST",
    path: "/rpc/guc_status",
    body: %{"code" => "418"}
  },

  # --- pre_request (Task 13) ------------------------------------------------------------
  %{
    id: "response_gucs/pre-request-headers",
    fixture: :supabase,
    path: "/users?select=username&limit=1",
    headers: [{"x-set-guc", "true"}],
    response_headers: ["x-pre-request"]
  }
]
