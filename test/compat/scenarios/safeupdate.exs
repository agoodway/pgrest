# Ported from PostgREST's PgSafeUpdateSpec (the enabled half): Supabase loads pg-safeupdate,
# so an unfiltered PATCH/DELETE is a 21000 error, mapped to HTTP 400 like PostgREST's
# mapSQLtoHTTP does. There is no PostgREST on the safeupdate server (the port table has no
# port for one), so these are `only: :pgrest` with the upstream bodies inline. The texts are
# pinned to the real extension by test/compat/safeupdate_db_test.exs.
json = %{"content-type" => "application/json; charset=utf-8"}
applied = %{"content-range" => "0-1/*", "preference-applied" => "tx=rollback"}
deleted = %{"content-range" => "*/*", "preference-applied" => "tx=rollback"}
rollback = {"prefer", "tx=rollback"}

error = fn message ->
  %{
    status: 400,
    headers: json,
    body: %{"code" => "21000", "details" => nil, "hint" => nil, "message" => message}
  }
end

[
  %{
    id: "safeupdate/patch-requires-where",
    method: "PATCH",
    path: "/safe_update_items",
    headers: [{"prefer", "count=exact, tx=rollback"}],
    body: %{"name" => "New name"},
    stateful: true,
    only: :pgrest,
    expect: error.("UPDATE requires a WHERE clause")
  },
  %{
    id: "safeupdate/patch-with-filter",
    method: "PATCH",
    path: "/safe_update_items?id=gt.0",
    headers: [rollback],
    body: %{"name" => "updated-item"},
    stateful: true,
    only: :pgrest,
    expect: %{status: 204, headers: applied}
  },
  %{
    id: "safeupdate/delete-requires-where",
    method: "DELETE",
    path: "/safe_delete_items",
    headers: [rollback],
    stateful: true,
    only: :pgrest,
    expect: error.("DELETE requires a WHERE clause")
  },
  %{
    id: "safeupdate/delete-with-filter",
    method: "DELETE",
    path: "/safe_delete_items?id=gt.0",
    headers: [rollback],
    stateful: true,
    only: :pgrest,
    expect: %{status: 204, headers: deleted}
  }
]
