# OPTIONS answers with an Allow header and no query, ported from OptionsSpec.hs (OS:14-45)
# and applied to the fixture: a writable table, a table without a primary key, a composite
# key, the root, a volatile, a stable and an immutable function. TRACE cannot be replayed by
# the harness client, so `plug_options_test.exs` covers the unsupported methods.
[
  %{id: "options/table", method: "OPTIONS", path: "/items"},
  %{id: "options/table-no-pk", method: "OPTIONS", path: "/no_pk"},
  %{id: "options/table-compound-pk", method: "OPTIONS", path: "/compound_pk"},
  %{id: "options/partitioned-table", method: "OPTIONS", path: "/car_models"},
  %{id: "options/unknown-table", method: "OPTIONS", path: "/unknown"},
  %{id: "options/rpc-prefix-is-a-table", method: "OPTIONS", path: "/rpc"},
  %{id: "options/invalid-path", method: "OPTIONS", path: "/a/b"},
  %{id: "options/root", method: "OPTIONS", path: "/"},
  %{id: "options/root-bad-filter", method: "OPTIONS", path: "/?x=1"},
  %{
    id: "options/root-unknown-profile",
    method: "OPTIONS",
    path: "/",
    headers: [{"accept-profile", "nope"}]
  },
  %{id: "options/root-select-ignored", method: "OPTIONS", path: "/?select=("},
  %{id: "options/table-bad-filter", method: "OPTIONS", path: "/items?x=1"},
  %{id: "options/table-bad-order", method: "OPTIONS", path: "/items?order=x.foo"},
  %{id: "options/unknown-table-bad-filter", method: "OPTIONS", path: "/unknown?x=1"},
  %{
    id: "options/content-profile-ignored",
    method: "OPTIONS",
    path: "/items",
    headers: [{"content-profile", "nope"}]
  },
  %{id: "options/query-string-ignored", method: "OPTIONS", path: "/items?select=(&limit=abc"},
  %{
    id: "options/unknown-profile",
    method: "OPTIONS",
    path: "/items",
    headers: [{"accept-profile", "nope"}]
  },
  %{id: "options/rpc-volatile", method: "OPTIONS", path: "/rpc/getallprojects"},
  %{
    id: "options/rpc-volatile-with-filter",
    method: "OPTIONS",
    path: "/rpc/getallprojects?id=eq.1"
  },
  %{id: "options/rpc-stable", method: "OPTIONS", path: "/rpc/scoped_projects"},
  %{id: "options/rpc-immutable", method: "OPTIONS", path: "/rpc/noparamsproc"},
  %{id: "options/rpc-unknown", method: "OPTIONS", path: "/rpc/nonexistent"},
  %{id: "options/rpc-bad-filter", method: "OPTIONS", path: "/rpc/getallprojects?x=1"},
  %{id: "options/rpc-bad-order", method: "OPTIONS", path: "/rpc/getallprojects?order=x.foo"},
  %{id: "options/rpc-with-argument", method: "OPTIONS", path: "/rpc/sayhello?name=eq.Ann"},
  %{id: "options/rpc-embed-filter", method: "OPTIONS", path: "/rpc/getallprojects?a.b=eq.1"},
  %{id: "options/rpc-embed-order", method: "OPTIONS", path: "/rpc/getallprojects?a.order=id"},
  %{id: "options/rpc-embed-or", method: "OPTIONS", path: "/rpc/getallprojects?a.or=(id.eq.1)"},
  # An explicit select plans its embeds, so their filters are valid.
  %{
    id: "options/rpc-select-embed-filter",
    method: "OPTIONS",
    path: "/rpc/getallprojects?select=id,clients(id)&clients.id=eq.1"
  },
  %{id: "options/rpc-unknown-embed-filter", method: "OPTIONS", path: "/rpc/nonexistent?a.b=eq.1"},
  %{id: "options/table-embed-filter", method: "OPTIONS", path: "/items?a.b=eq.1"},

  # An unsupported method on an RPC: the profile (Content-Profile for DELETE, PATCH and PUT,
  # Accept-Profile for the rest) is resolved before the method is rejected.
  %{
    id: "options/rpc-delete-unknown-profile",
    method: "DELETE",
    path: "/rpc/getallprojects",
    headers: [{"content-profile", "nope"}, {"prefer", "tx=rollback"}],
    stateful: true
  },
  %{
    id: "options/rpc-delete-accept-profile-ignored",
    method: "DELETE",
    path: "/rpc/getallprojects",
    headers: [{"accept-profile", "nope"}, {"prefer", "tx=rollback"}],
    stateful: true
  },
  %{
    id: "options/rpc-patch-unknown-profile",
    method: "PATCH",
    path: "/rpc/getallprojects",
    headers: [{"content-profile", "nope"}, {"prefer", "tx=rollback"}],
    stateful: true
  },

  # A method PgRest does not serve: the profile is resolved first, the method decides after it.
  # TRACE cannot be replayed by the harness client, so `plug_options_test.exs` covers it.
  %{
    id: "options/write-method-on-root-post",
    method: "POST",
    path: "/",
    headers: [{"prefer", "tx=rollback"}],
    stateful: true
  },
  %{
    id: "options/write-method-on-root-delete",
    method: "DELETE",
    path: "/",
    headers: [{"prefer", "tx=rollback"}],
    stateful: true
  },
  %{
    id: "options/write-method-on-root-unknown-profile",
    method: "POST",
    path: "/",
    headers: [{"content-profile", "nope"}, {"prefer", "tx=rollback"}],
    stateful: true
  }
]
