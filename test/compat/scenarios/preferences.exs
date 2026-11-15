# Prefer: handling=strict (PGRST122), max-affected (PGRST124/PGRST128) and timezone (Phase 2
# Task 10). Ported from PostgREST's PreferencesSpec (HD, 03 §8c/§12) and the timezone cases of
# the same spec against the `timestamps` fixture table, plus the supabase-js max-affected cases
# (update, delete and `rpc('set_users_offline')`) against the Supabase fixture. The
# "05 §8" gap-analysis doc is not in the repository, so those are written from postgrest-js's
# max-affected usage (`Prefer: handling=strict, max-affected=N`). Every mutation rolls back.
rb = {"prefer", "tx=rollback"}
strict_unknown = {"prefer", "handling=strict, anything"}
lenient_unknown = {"prefer", "handling=lenient, anything"}
strict = fn n -> {"prefer", "handling=strict, max-affected=#{n}"} end
lenient = fn n -> {"prefer", "handling=lenient, max-affected=#{n}"} end
tz = fn value -> {"prefer", value} end
org = %{"id" => 7, "name" => "John", "referee" => nil, "auditor" => nil, "manager_id" => 6}

[
  # --- handling=strict ----------------------------------------------------------------------
  %{id: "preferences/strict-unknown-get", path: "/items", headers: [strict_unknown]},
  %{
    id: "preferences/strict-unknown-separate-headers",
    path: "/items",
    headers: [{"prefer", "handling=strict"}, {"prefer", "something, else"}]
  },
  %{
    id: "preferences/strict-unknown-post",
    method: "POST",
    path: "/organizations?select=*",
    headers: [{"prefer", "return=representation, handling=strict, anything"}, rb],
    body: org,
    stateful: true
  },
  %{
    id: "preferences/strict-unknown-rpc",
    method: "POST",
    path: "/rpc/overloaded_unnamed_param",
    headers: [strict_unknown],
    body: %{}
  },
  %{
    id: "preferences/strict-unknown-value",
    path: "/items",
    headers: [{"prefer", "handling=strict, return=foo, count=bogus"}]
  },
  %{
    id: "preferences/strict-known-only",
    path: "/items?limit=1",
    headers: [{"prefer", "handling=strict, count=exact"}]
  },

  # --- handling=lenient ---------------------------------------------------------------------
  %{id: "preferences/lenient-unknown-get", path: "/items", headers: [lenient_unknown]},
  %{
    id: "preferences/lenient-unknown-separate-headers",
    path: "/items",
    headers: [{"prefer", "handling=lenient"}, {"prefer", "anything"}]
  },
  %{
    id: "preferences/lenient-unknown-post",
    method: "POST",
    path: "/organizations?select=*",
    headers: [{"prefer", "return=representation, handling=lenient, anything"}, rb],
    body: org,
    stateful: true
  },
  %{
    id: "preferences/lenient-unknown-rpc",
    method: "POST",
    path: "/rpc/overloaded_unnamed_param",
    headers: [lenient_unknown],
    body: %{}
  },

  # --- timezone -----------------------------------------------------------------------------
  %{
    id: "preferences/timezone-strict",
    path: "/timestamps",
    headers: [tz.("handling=strict, timezone=America/Los_Angeles")]
  },
  %{
    id: "preferences/timezone-lenient-default",
    path: "/timestamps",
    headers: [tz.("timezone=America/Los_Angeles")]
  },
  %{
    id: "preferences/timezone-invalid-strict",
    path: "/timestamps",
    headers: [tz.("handling=strict, timezone=Invalid/Timezone")]
  },
  %{
    id: "preferences/timezone-invalid-default",
    path: "/timestamps",
    headers: [tz.("timezone=Invalid/Timezone")]
  },
  %{
    id: "preferences/timezone-invalid-lenient",
    path: "/timestamps",
    headers: [tz.("handling=lenient, timezone=Invalid/Timezone")]
  },
  %{
    id: "preferences/timezone-invalid-strict-mixed",
    path: "/timestamps",
    headers: [tz.("handling=strict, nope, timezone=Invalid/Timezone, later")]
  },
  %{
    id: "preferences/timezone-first-wins",
    path: "/timestamps",
    headers: [tz.("handling=strict, timezone=UTC, timezone=Invalid/Timezone")]
  },
  %{
    id: "preferences/timezone-first-invalid",
    path: "/timestamps",
    headers: [tz.("handling=strict, timezone=Invalid/Timezone, timezone=UTC")]
  },
  %{
    id: "preferences/timezone-rpc",
    path: "/rpc/getitemrange?min=0&max=1",
    headers: [tz.("timezone=Asia/Tokyo")]
  },
  %{
    id: "preferences/timezone-post-representation",
    method: "POST",
    path: "/organizations?select=*",
    headers: [tz.("return=representation, timezone=Asia/Tokyo"), rb],
    body: org,
    stateful: true
  },

  # --- max-affected, handling=strict ----------------------------------------------------------
  %{
    id: "preferences/max-affected-delete-over",
    method: "DELETE",
    path: "/items?id=lt.15",
    headers: [strict.(10), rb],
    stateful: true
  },
  %{
    id: "preferences/max-affected-delete-within",
    method: "DELETE",
    path: "/items?id=lt.10",
    headers: [strict.(10), rb],
    stateful: true
  },
  %{
    id: "preferences/max-affected-delete-exact",
    method: "DELETE",
    path: "/items?id=lt.11",
    headers: [strict.(10), rb],
    stateful: true
  },
  %{
    id: "preferences/max-affected-patch-zero",
    method: "PATCH",
    path: "/tiobe_pls?name=eq.Java",
    headers: [strict.(0), rb],
    body: [%{"name" => "Java", "rank" => 19}],
    stateful: true
  },
  %{
    id: "preferences/max-affected-delete-one",
    method: "DELETE",
    path: "/tiobe_pls?name=eq.Java",
    headers: [strict.(1), rb],
    body: [%{"name" => "Java", "rank" => 19}],
    stateful: true
  },
  %{
    id: "preferences/max-affected-patch-no-match",
    method: "PATCH",
    path: "/tiobe_pls?name=eq.Nothing",
    headers: [strict.(0), rb],
    body: %{"rank" => 3},
    stateful: true
  },
  %{
    id: "preferences/max-affected-patch-representation",
    method: "PATCH",
    path: "/tiobe_pls?rank=lt.10",
    headers: [{"prefer", "return=representation, handling=strict, max-affected=2"}, rb],
    body: %{"rank" => 3},
    stateful: true
  },
  %{
    id: "preferences/max-affected-patch-negative",
    method: "PATCH",
    path: "/tiobe_pls?name=eq.Java",
    headers: [{"prefer", "handling=strict, max-affected=-1"}, rb],
    body: %{"rank" => 3},
    stateful: true
  },
  %{
    id: "preferences/max-affected-garbage-strict",
    method: "DELETE",
    path: "/tiobe_pls?name=eq.Java",
    headers: [{"prefer", "handling=strict, max-affected=abc"}, rb],
    stateful: true
  },
  %{
    id: "preferences/max-affected-get-ignored",
    path: "/items?limit=1",
    headers: [strict.(0)]
  },
  %{
    id: "preferences/max-affected-post-ignored",
    method: "POST",
    path: "/organizations?select=*",
    headers: [{"prefer", "return=representation, handling=strict, max-affected=0"}, rb],
    body: org,
    stateful: true
  },

  # --- max-affected, handling=lenient ---------------------------------------------------------
  %{
    id: "preferences/max-affected-lenient-delete-over",
    method: "DELETE",
    path: "/items?id=lt.15",
    headers: [lenient.(10), rb],
    stateful: true
  },
  %{
    id: "preferences/max-affected-lenient-delete-within",
    method: "DELETE",
    path: "/items?id=lt.10",
    headers: [lenient.(10), rb],
    stateful: true
  },
  %{
    id: "preferences/max-affected-lenient-patch-zero",
    method: "PATCH",
    path: "/tiobe_pls?name=eq.Java",
    headers: [lenient.(0), rb],
    body: [%{"name" => "Java", "rank" => 19}],
    stateful: true
  },
  %{
    id: "preferences/max-affected-lenient-delete-one",
    method: "DELETE",
    path: "/tiobe_pls?name=eq.Java",
    headers: [lenient.(1), rb],
    body: [%{"name" => "Java", "rank" => 19}],
    stateful: true
  },
  %{
    id: "preferences/max-affected-default-handling",
    method: "DELETE",
    path: "/items?id=lt.15",
    headers: [{"prefer", "max-affected=1"}, rb],
    stateful: true
  },

  # --- max-affected, RPC ------------------------------------------------------------------------
  %{
    id: "preferences/max-affected-rpc-setof-over",
    method: "POST",
    path: "/rpc/delete_items_returns_setof",
    headers: [strict.(10)]
  },
  %{
    id: "preferences/max-affected-rpc-table-over",
    method: "POST",
    path: "/rpc/delete_items_returns_table",
    headers: [strict.(10)]
  },
  %{
    id: "preferences/max-affected-rpc-setof-within",
    method: "POST",
    path: "/rpc/delete_items_returns_setof",
    headers: [strict.(20)]
  },
  %{
    id: "preferences/max-affected-rpc-table-within",
    method: "POST",
    path: "/rpc/delete_items_returns_table",
    headers: [strict.(20)]
  },
  %{
    id: "preferences/max-affected-rpc-void",
    method: "POST",
    path: "/rpc/delete_items_returns_void",
    headers: [strict.(20)]
  },
  %{
    id: "preferences/max-affected-rpc-scalar",
    method: "POST",
    path: "/rpc/add_them",
    headers: [strict.(5)],
    body: %{"a" => 1, "b" => 2}
  },
  %{
    id: "preferences/max-affected-rpc-scalar-lenient",
    method: "POST",
    path: "/rpc/add_them",
    headers: [lenient.(5)],
    body: %{"a" => 1, "b" => 2}
  },
  %{
    id: "preferences/max-affected-rpc-get-over",
    path: "/rpc/getallprojects",
    headers: [strict.(2)]
  },
  %{
    id: "preferences/max-affected-rpc-get-within",
    path: "/rpc/getallprojects?select=id",
    headers: [strict.(5)]
  },
  %{
    id: "preferences/max-affected-rpc-strict-unknown-first",
    method: "POST",
    path: "/rpc/add_them",
    headers: [{"prefer", "handling=strict, max-affected=5, anything"}],
    body: %{"a" => 1, "b" => 2}
  },
  %{
    id: "preferences/max-affected-rpc-unknown-function",
    method: "POST",
    path: "/rpc/no_such_function",
    headers: [strict.(5)],
    body: %{}
  },

  # --- supabase fixture: update, delete and rpc('set_users_offline') -------------------------------
  %{
    id: "preferences/supabase-update-within",
    fixture: :supabase,
    method: "PATCH",
    path: "/users?username=eq.supabot",
    headers: [strict.(1), rb],
    body: %{"status" => "ONLINE"},
    stateful: true
  },
  %{
    id: "preferences/supabase-update-over",
    fixture: :supabase,
    method: "PATCH",
    path: "/users?status=eq.ONLINE",
    headers: [strict.(1), rb],
    body: %{"status" => "OFFLINE"},
    stateful: true
  },
  %{
    id: "preferences/supabase-update-over-representation",
    fixture: :supabase,
    method: "PATCH",
    path: "/users?status=eq.ONLINE&select=username",
    headers: [{"prefer", "return=representation, handling=strict, max-affected=3"}, rb],
    body: %{"status" => "OFFLINE"},
    stateful: true
  },
  %{
    id: "preferences/supabase-delete-within",
    fixture: :supabase,
    method: "DELETE",
    path: "/users_audit?previous_value=eq.42",
    headers: [strict.(5), rb],
    stateful: true
  },
  %{
    id: "preferences/supabase-delete-over",
    fixture: :supabase,
    method: "DELETE",
    path: "/users_audit?previous_value=eq.42",
    headers: [strict.(4), rb],
    stateful: true
  },
  %{
    id: "preferences/supabase-rpc-set-users-offline-within",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/set_users_offline",
    headers: [strict.(5)],
    body: %{"name_param" => "%"}
  },
  %{
    id: "preferences/supabase-rpc-set-users-offline-over",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/set_users_offline",
    headers: [strict.(2)],
    body: %{"name_param" => "%"}
  },
  %{
    id: "preferences/supabase-rpc-set-users-offline-match-one",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/set_users_offline",
    headers: [strict.(1)],
    body: %{"name_param" => "supabot"}
  },
  %{
    id: "preferences/supabase-rpc-offline-user-scalar",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/offline_user",
    headers: [strict.(1)],
    body: %{"name_param" => "supabot"}
  },
  %{
    id: "preferences/supabase-rpc-void",
    fixture: :supabase,
    method: "POST",
    path: "/rpc/void_func",
    headers: [strict.(1)],
    body: %{}
  }
]
