rb = {"prefer", "tx=rollback"}
rep = {"prefer", "return=representation, tx=rollback"}
hdr = {"prefer", "return=headers-only, tx=rollback"}
min = {"prefer", "return=minimal, tx=rollback"}
dflt = {"prefer", "missing=default, return=representation, tx=rollback"}
single = {"accept", "application/vnd.pgrst.object+json"}

[
  %{
    id: "insert/js-quoted-columns",
    fixture: :supabase,
    method: "POST",
    path: "/users?columns=%22username%22&select=username,status&order=username",
    headers: [{"prefer", "return=representation,count=exact,tx=rollback"}],
    body: [%{"username" => "js_one"}, %{"username" => "js_two"}],
    stateful: true
  },
  # --- single row, return modes ----------------------------------------------------
  %{
    id: "insert/single-default-prefs",
    method: "POST",
    path: "/projects",
    headers: [rb],
    body: %{"id" => 100, "name" => "new", "client_id" => 1},
    stateful: true
  },
  %{
    id: "insert/single-representation",
    method: "POST",
    path: "/projects",
    headers: [rep],
    body: %{"id" => 100, "name" => "new", "client_id" => 1},
    stateful: true
  },
  %{
    id: "insert/representation-select",
    method: "POST",
    path: "/projects?select=id,name",
    headers: [rep],
    body: %{"id" => 100, "name" => "new", "client_id" => 1},
    stateful: true
  },
  %{
    id: "insert/select-ignored-by-default",
    method: "POST",
    path: "/projects?select=id,name",
    headers: [rb],
    body: %{"id" => 100, "name" => "new", "client_id" => 1},
    stateful: true
  },
  %{
    id: "insert/select-ignored-by-minimal",
    method: "POST",
    path: "/projects?select=id,name",
    headers: [min],
    body: %{"id" => 100, "name" => "new", "client_id" => 1},
    stateful: true
  },
  %{
    id: "insert/representation-rename-cast",
    method: "POST",
    path: "/projects?select=pId:id::text,pName:name,cId:client_id::text",
    headers: [rep],
    body: %{"id" => 100, "name" => "new", "client_id" => 1},
    stateful: true
  },
  %{
    id: "insert/representation-embed",
    method: "POST",
    path: "/clients?select=id,projects(id)",
    headers: [rep],
    body: %{"id" => 100, "name" => "newco"},
    stateful: true
  },
  %{
    id: "insert/representation-embed-parent",
    method: "POST",
    path: "/projects?select=id,clients(id,name)",
    headers: [rep],
    body: %{"id" => 100, "name" => "new", "client_id" => 1},
    stateful: true
  },
  %{
    id: "insert/headers-only",
    method: "POST",
    path: "/projects",
    headers: [hdr],
    body: %{"id" => 100, "name" => "new", "client_id" => 1},
    stateful: true
  },
  %{
    id: "insert/headers-only-composite",
    method: "POST",
    path: "/compound_pk",
    headers: [hdr],
    body: %{"k1" => 1, "k2" => "test"},
    stateful: true
  },
  %{
    id: "insert/headers-only-encoding",
    method: "POST",
    path: "/compound_pk",
    headers: [hdr],
    body: %{"k1" => 1, "k2" => "a b&c"},
    stateful: true
  },
  %{
    id: "insert/headers-only-no-pk",
    method: "POST",
    path: "/no_pk",
    headers: [hdr],
    body: %{"a" => "x", "b" => "y"},
    stateful: true
  },
  %{
    id: "insert/headers-only-bulk",
    method: "POST",
    path: "/projects",
    headers: [hdr],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => "b"}],
    stateful: true
  },
  %{
    id: "insert/headers-only-one-element-array",
    method: "POST",
    path: "/projects",
    headers: [hdr],
    body: [%{"id" => 100, "name" => "a"}],
    stateful: true
  },
  %{
    id: "insert/minimal-no-location",
    method: "POST",
    path: "/projects",
    headers: [min],
    body: %{"id" => 100, "name" => "new"},
    stateful: true
  },
  # --- bulk ------------------------------------------------------------------------
  %{
    id: "insert/bulk-minimal",
    method: "POST",
    path: "/projects",
    headers: [rb],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => "b"}],
    stateful: true
  },
  %{
    id: "insert/bulk-representation",
    method: "POST",
    path: "/projects?select=id,name",
    headers: [rep],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => "b"}],
    stateful: true
  },
  %{
    id: "insert/bulk-empty-array",
    method: "POST",
    path: "/projects",
    headers: [rep],
    body: [],
    stateful: true
  },
  %{
    id: "insert/bulk-non-uniform-keys",
    method: "POST",
    path: "/projects",
    headers: [rep],
    body: [%{"id" => 100, "name" => "a", "client_id" => 1}, %{"id" => 101, "name" => "b"}],
    stateful: true
  },
  %{
    id: "insert/bulk-non-object-element",
    method: "POST",
    path: "/projects",
    headers: [rep],
    body: [%{"id" => 100, "name" => "a"}, 123, "xxxx"],
    stateful: true
  },
  # --- empty objects ---------------------------------------------------------------
  %{
    id: "insert/empty-object-representation",
    method: "POST",
    path: "/items",
    headers: [rep],
    body: %{},
    stateful: true
  },
  %{
    id: "insert/empty-object-array",
    method: "POST",
    path: "/items",
    headers: [rep],
    body: [%{}],
    stateful: true
  },
  %{
    id: "insert/empty-objects-bulk",
    method: "POST",
    path: "/items",
    headers: [rep],
    body: [%{}, %{}],
    stateful: true
  },
  # --- body errors -----------------------------------------------------------------
  %{
    id: "insert/invalid-json",
    method: "POST",
    path: "/projects",
    headers: [rb, {"content-type", "application/json"}],
    body: "}{ x = 2",
    stateful: true
  },
  %{
    id: "insert/empty-body",
    method: "POST",
    path: "/projects",
    headers: [rb, {"content-type", "application/json"}],
    body: "",
    stateful: true
  },
  # --- database errors -------------------------------------------------------------
  %{
    id: "insert/duplicate-pk",
    method: "POST",
    path: "/clients",
    headers: [rb],
    body: %{"id" => 1, "name" => "dup"},
    stateful: true
  },
  %{
    id: "insert/not-null",
    method: "POST",
    path: "/clients",
    headers: [rb],
    body: %{"id" => 100},
    stateful: true
  },
  %{
    id: "insert/not-null-composite",
    method: "POST",
    path: "/compound_pk",
    headers: [rb],
    body: %{"k2" => "x"},
    stateful: true
  },
  %{
    id: "insert/foreign-key-violation",
    method: "POST",
    path: "/projects",
    headers: [rb],
    body: %{"id" => 100, "name" => "x", "client_id" => 999},
    stateful: true
  },
  %{
    id: "insert/invalid-integer",
    method: "POST",
    path: "/items",
    headers: [rb],
    body: %{"id" => "abc"},
    stateful: true
  },
  %{
    id: "insert/generated-always-column",
    method: "POST",
    path: "/defaults_demo",
    headers: [rb],
    body: %{"label" => "x", "double_id" => 5},
    stateful: true
  },
  # --- columns= --------------------------------------------------------------------
  %{
    id: "insert/columns-ignores-extra-keys",
    method: "POST",
    path: "/projects?columns=id,name",
    headers: [rep],
    body: %{"id" => 100, "name" => "new", "client_id" => 1},
    stateful: true
  },
  %{
    id: "insert/columns-blank",
    method: "POST",
    path: "/projects?columns=",
    headers: [rep],
    body: %{"id" => 100, "name" => "new"},
    stateful: true
  },
  %{
    id: "insert/columns-unknown",
    method: "POST",
    path: "/projects?columns=helicopter",
    headers: [rep],
    body: %{"id" => 100, "name" => "new"},
    stateful: true
  },
  %{
    id: "insert/columns-unknown-table",
    method: "POST",
    path: "/helicopter?columns=id",
    headers: [rep],
    body: %{"id" => 100},
    stateful: true
  },
  %{
    id: "insert/unknown-payload-key",
    method: "POST",
    path: "/projects",
    headers: [rep],
    body: %{"id" => 100, "name" => "new", "helicopter" => 1},
    stateful: true
  },
  # --- missing=default -------------------------------------------------------------
  %{
    id: "insert/missing-default-single",
    method: "POST",
    path: "/defaults_demo?select=id,label,note,double_id",
    headers: [dflt],
    body: %{"label" => "x"},
    stateful: true
  },
  %{
    id: "insert/missing-default-columns",
    method: "POST",
    path: "/defaults_demo?columns=label,note&select=id,label,note",
    headers: [dflt],
    body: %{"label" => "x"},
    stateful: true
  },
  %{
    id: "insert/missing-default-bulk-null",
    method: "POST",
    path: "/defaults_demo?select=id,label,note",
    headers: [dflt],
    body: [%{"note" => "n1"}, %{"note" => nil}, %{"label" => "l"}],
    stateful: true
  },
  %{
    id: "insert/missing-null-bulk",
    method: "POST",
    path: "/defaults_demo?select=id,label,note",
    headers: [{"prefer", "missing=null, return=representation, tx=rollback"}],
    body: [%{"label" => "a", "note" => "n1"}, %{"label" => "b"}],
    stateful: true
  },
  %{
    id: "insert/default-absent-key-uses-default",
    method: "POST",
    path: "/defaults_demo?select=id,label,note",
    headers: [rep],
    body: %{"label" => "only"},
    stateful: true
  },
  %{
    id: "insert/explicit-null-stays-null",
    method: "POST",
    path: "/defaults_demo?select=id,label,note",
    headers: [rep],
    body: %{"label" => "x", "note" => nil},
    stateful: true
  },
  %{
    id: "insert/missing-default-columns-bulk-null",
    method: "POST",
    path: "/defaults_demo?columns=label,note&select=id,label,note",
    headers: [dflt],
    body: [%{"note" => "n1"}, %{"label" => "l", "note" => nil}, %{"label" => "m"}],
    stateful: true
  },
  %{
    id: "insert/columns-bulk-absent-is-null",
    method: "POST",
    path: "/defaults_demo?columns=label,note&select=id,label,note",
    headers: [rep],
    body: [%{"label" => "a"}, %{"note" => "b"}],
    stateful: true
  },
  %{
    id: "insert/columns-bulk-non-object-element",
    method: "POST",
    path: "/projects?columns=id,name",
    headers: [rep],
    body: [%{"id" => 100, "name" => "a"}, 123],
    stateful: true
  },
  # --- jsonb / arrays --------------------------------------------------------------
  %{
    id: "insert/jsonb-roundtrip",
    method: "POST",
    path: "/complex_items?select=id,name,settings,arr_data,tags",
    headers: [rep],
    body: %{
      "id" => 100,
      "name" => "j",
      "settings" => %{"a" => [1, %{"b" => nil}], "c" => "d"},
      "arr_data" => [1, 2],
      "tags" => ["x", "y"]
    },
    stateful: true
  },
  # --- singular object -------------------------------------------------------------
  %{
    id: "insert/singular-one-row",
    method: "POST",
    path: "/projects",
    headers: [rep, single],
    body: %{"id" => 100, "name" => "new"},
    stateful: true
  },
  %{
    id: "insert/singular-one-element-array",
    method: "POST",
    path: "/projects",
    headers: [rep, single],
    body: [%{"id" => 100, "name" => "new"}],
    stateful: true
  },
  %{
    id: "insert/singular-two-rows",
    method: "POST",
    path: "/projects",
    headers: [rep, single],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => "b"}],
    stateful: true
  },
  %{
    id: "insert/singular-two-rows-minimal",
    method: "POST",
    path: "/projects",
    headers: [min, single],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => "b"}],
    stateful: true
  },
  %{
    id: "insert/singular-empty-array",
    method: "POST",
    path: "/projects",
    headers: [rep, single],
    body: [],
    stateful: true
  },
  # --- preferences -----------------------------------------------------------------
  %{
    id: "insert/preference-applied-order",
    method: "POST",
    path: "/projects",
    headers: [{"prefer", "tx=rollback, return=representation, missing=default"}],
    body: %{"id" => 100, "name" => "new"},
    stateful: true
  },
  %{
    id: "insert/representation-order",
    method: "POST",
    path: "/projects?select=id,name&order=id.desc",
    headers: [rep],
    body: [
      %{"id" => 100, "name" => "a"},
      %{"id" => 101, "name" => "b"},
      %{"id" => 102, "name" => "c"}
    ],
    stateful: true
  },
  %{
    id: "insert/representation-filter-ignored",
    method: "POST",
    path: "/projects?select=id&id=eq.999&limit=1",
    headers: [rep],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => "b"}],
    stateful: true
  },
  %{
    id: "insert/count-exact-single",
    method: "POST",
    path: "/projects",
    headers: [{"prefer", "count=exact, return=representation, tx=rollback"}],
    body: %{"id" => 100, "name" => "a"},
    stateful: true
  },
  %{
    id: "insert/count-exact-bulk",
    method: "POST",
    path: "/projects?select=id",
    headers: [{"prefer", "count=exact, return=representation, tx=rollback"}],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => "b"}],
    stateful: true
  },
  %{
    id: "insert/count-exact-minimal",
    method: "POST",
    path: "/projects",
    headers: [{"prefer", "count=exact, tx=rollback"}],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => "b"}],
    stateful: true
  },
  %{
    id: "insert/count-exact-headers-only",
    method: "POST",
    path: "/projects",
    headers: [{"prefer", "count=exact, return=headers-only, tx=rollback"}],
    body: %{"id" => 100, "name" => "a"},
    stateful: true
  },
  %{
    id: "insert/count-planned",
    method: "POST",
    path: "/projects",
    headers: [{"prefer", "count=planned, return=representation, tx=rollback"}],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => "b"}],
    stateful: true
  },
  %{
    id: "insert/count-estimated",
    method: "POST",
    path: "/projects",
    headers: [{"prefer", "count=estimated, return=representation, tx=rollback"}],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => "b"}],
    stateful: true
  },
  %{
    id: "insert/missing-default-identity",
    method: "POST",
    path: "/defaults_demo?columns=id,label&select=id,label",
    headers: [dflt],
    body: %{"label" => "x"},
    stateful: true
  },
  %{
    id: "insert/missing-default-identity-bulk",
    method: "POST",
    path: "/defaults_demo?columns=id,label&select=id,label",
    headers: [dflt],
    body: [%{"label" => "x"}, %{"id" => 50, "label" => "y"}, %{"label" => "z"}],
    stateful: true
  },
  # --- PgRest only: writable allowlist and scrubbing (S-M2) --------------------------
  %{
    id: "insert/redact-field-not-writable",
    method: "POST",
    path: "/accounts",
    headers: [rb],
    body: %{"id" => 100, "email" => "a@x", "hashed_password" => "h"},
    stateful: true,
    only: :pgrest,
    expect: %{
      status: 401,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "42501",
        "details" => nil,
        "hint" => nil,
        "message" => "permission denied for table accounts"
      }
    }
  }
]
