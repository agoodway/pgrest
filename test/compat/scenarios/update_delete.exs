rb = {"prefer", "tx=rollback"}
rep = {"prefer", "return=representation, tx=rollback"}
min = {"prefer", "return=minimal, tx=rollback"}
cnt = {"prefer", "count=exact, tx=rollback"}
repcnt = {"prefer", "return=representation, count=exact, tx=rollback"}
dflt = {"prefer", "missing=default, return=representation, tx=rollback"}
single = {"accept", "application/vnd.pgrst.object+json"}
unsafe = [require_filters_for_mutations: false]

[
  # --- PATCH -----------------------------------------------------------------------
  %{
    id: "update_delete/patch-default-prefs",
    method: "PATCH",
    path: "/complex_items?id=eq.1",
    headers: [rb],
    body: %{"name" => "Renamed"},
    stateful: true
  },
  %{
    id: "update_delete/patch-no-match",
    method: "PATCH",
    path: "/complex_items?id=eq.999",
    headers: [rb],
    body: %{"name" => "Renamed"},
    stateful: true
  },
  %{
    id: "update_delete/patch-multiple-rows-pk-less",
    method: "PATCH",
    path: "/no_pk?b=eq.0",
    headers: [rb],
    body: %{"b" => "1"},
    stateful: true
  },
  %{
    id: "update_delete/patch-pk-less-representation",
    method: "PATCH",
    path: "/no_pk?b=eq.0&order=a",
    headers: [rep],
    body: %{"b" => "1"},
    stateful: true
  },
  %{
    id: "update_delete/patch-representation",
    method: "PATCH",
    path: "/complex_items?id=eq.2&select=id",
    headers: [rep],
    body: %{"name" => "Renamed"},
    stateful: true
  },
  %{
    id: "update_delete/patch-representation-no-match",
    method: "PATCH",
    path: "/complex_items?id=eq.999",
    headers: [rep],
    body: %{"name" => "Renamed"},
    stateful: true
  },
  %{
    id: "update_delete/patch-null",
    method: "PATCH",
    path: "/complex_items?id=eq.1&select=id,name",
    headers: [rep],
    body: %{"name" => nil},
    stateful: true
  },
  %{
    id: "update_delete/patch-jsonb-column",
    method: "PATCH",
    path: "/complex_items?id=eq.1&select=id,settings",
    headers: [rep],
    body: %{"settings" => %{"a" => [1, 2]}},
    stateful: true
  },
  %{
    id: "update_delete/patch-no-filter-all-rows",
    method: "PATCH",
    path: "/no_pk",
    headers: [rep],
    body: %{"b" => "1"},
    plug_opts: unsafe,
    sort: true,
    stateful: true
  },
  %{
    id: "update_delete/patch-empty-object",
    method: "PATCH",
    path: "/complex_items?id=eq.1",
    headers: [rb],
    body: %{},
    stateful: true
  },
  %{
    id: "update_delete/patch-empty-object-representation",
    method: "PATCH",
    path: "/complex_items?id=eq.1",
    headers: [rep],
    body: %{},
    stateful: true
  },
  %{
    id: "update_delete/patch-empty-array",
    method: "PATCH",
    path: "/complex_items?id=eq.1",
    headers: [rb],
    body: [],
    stateful: true
  },
  %{
    id: "update_delete/patch-empty-array-representation",
    method: "PATCH",
    path: "/complex_items?id=eq.1",
    headers: [rep],
    body: [],
    stateful: true
  },
  %{
    id: "update_delete/patch-filter-on-modified-column",
    method: "PATCH",
    path: "/complex_items?or=(name.is.null,name.like.*One*)&select=id,name",
    headers: [rep],
    body: %{"name" => "updated entity"},
    stateful: true
  },
  %{
    id: "update_delete/patch-logic-tree",
    method: "PATCH",
    path: "/complex_items?and=(id.gt.1,id.lt.3)&select=id",
    headers: [rep],
    body: %{"name" => "x"},
    stateful: true
  },
  %{
    id: "update_delete/patch-columns",
    method: "PATCH",
    path: "/complex_items?id=eq.1&columns=name&select=id,name,tags",
    headers: [rep],
    body: %{"name" => "Only", "tags" => ["zz"]},
    stateful: true
  },
  %{
    id: "update_delete/patch-columns-no-match",
    method: "PATCH",
    path: "/complex_items?id=eq.999&columns=name",
    headers: [rep],
    body: %{"name" => "Only"},
    stateful: true
  },
  %{
    id: "update_delete/patch-columns-unknown",
    method: "PATCH",
    path: "/complex_items?id=eq.1&columns=helicopter",
    headers: [rb],
    body: %{"name" => "Only"},
    stateful: true
  },
  %{
    id: "update_delete/patch-unknown-payload-column",
    method: "PATCH",
    path: "/complex_items?id=eq.1",
    headers: [rb],
    body: %{"helicopter" => 1},
    stateful: true
  },
  %{
    id: "update_delete/patch-missing-default",
    method: "PATCH",
    path: "/complex_items?id=eq.3&columns=name,field-with_sep&select=id,name,field-with_sep",
    headers: [dflt],
    body: %{"name" => "N"},
    stateful: true
  },
  %{
    id: "update_delete/patch-select-ignored-by-minimal",
    method: "PATCH",
    path: "/complex_items?id=eq.1&select=id",
    headers: [min],
    body: %{"name" => "N"},
    stateful: true
  },
  %{
    id: "update_delete/patch-count-exact",
    method: "PATCH",
    path: "/complex_items?id=gt.0",
    headers: [cnt],
    body: %{"name" => "N"},
    stateful: true
  },
  %{
    id: "update_delete/patch-count-exact-representation",
    method: "PATCH",
    path: "/complex_items?id=gt.1&select=id&order=id",
    headers: [repcnt],
    body: %{"name" => "N"},
    stateful: true
  },
  %{
    id: "update_delete/patch-invalid-json",
    method: "PATCH",
    path: "/complex_items?id=eq.1",
    headers: [rb, {"content-type", "application/json"}],
    body: "}{ x = 2",
    stateful: true
  },
  %{
    id: "update_delete/patch-empty-body",
    method: "PATCH",
    path: "/complex_items?id=eq.1",
    headers: [rb, {"content-type", "application/json"}],
    body: "",
    stateful: true
  },
  %{
    id: "update_delete/patch-unknown-table",
    method: "PATCH",
    path: "/fake?id=eq.1",
    headers: [rb],
    body: %{"a" => 1},
    stateful: true
  },
  %{
    id: "update_delete/patch-typo-filter",
    method: "PATCH",
    path: "/complex_items?idd=eq.1",
    headers: [rb],
    body: %{"name" => "x"},
    stateful: true
  },
  %{
    id: "update_delete/patch-enum",
    method: "PATCH",
    path: "/type_cases?id=eq.1&select=id,status",
    headers: [rep],
    body: %{"status" => "archived"},
    stateful: true
  },
  %{
    id: "update_delete/patch-bad-enum-value",
    method: "PATCH",
    path: "/type_cases?id=eq.1",
    headers: [rb],
    body: %{"status" => "OFFLINE"},
    stateful: true
  },
  %{
    id: "update_delete/patch-fk-violation",
    method: "PATCH",
    path: "/projects?id=eq.1",
    headers: [rb],
    body: %{"client_id" => 999},
    stateful: true
  },
  %{
    id: "update_delete/patch-not-null-violation",
    method: "PATCH",
    path: "/clients?id=eq.1",
    headers: [rb],
    body: %{"name" => nil},
    stateful: true
  },
  %{
    id: "update_delete/patch-embed-in-representation",
    method: "PATCH",
    path: "/projects?id=eq.1&select=id,clients(id,name)",
    headers: [rep],
    body: %{"name" => "W"},
    stateful: true
  },
  # --- PATCH, singular Accept ------------------------------------------------------
  %{
    id: "update_delete/patch-singular-one-row",
    method: "PATCH",
    path: "/complex_items?id=eq.1&select=id,name",
    headers: [rep, single],
    body: %{"name" => "S"},
    stateful: true
  },
  %{
    id: "update_delete/patch-singular-minimal",
    method: "PATCH",
    path: "/complex_items?id=eq.1",
    headers: [min, single],
    body: %{"name" => "S"},
    stateful: true
  },
  %{
    id: "update_delete/patch-singular-many-rows",
    method: "PATCH",
    path: "/complex_items?id=gt.0",
    headers: [rep, single],
    body: %{"name" => "S"},
    stateful: true
  },
  %{
    id: "update_delete/patch-singular-no-rows",
    method: "PATCH",
    path: "/complex_items?id=eq.999",
    headers: [rep, single],
    body: %{"name" => "S"},
    stateful: true
  },
  # --- DELETE ----------------------------------------------------------------------
  %{
    id: "update_delete/delete-default-prefs",
    method: "DELETE",
    path: "/items?id=eq.1",
    headers: [rb],
    stateful: true
  },
  %{
    id: "update_delete/delete-representation-count",
    method: "DELETE",
    path: "/items?id=eq.2",
    headers: [repcnt],
    stateful: true
  },
  %{
    id: "update_delete/delete-select-ignored",
    method: "DELETE",
    path: "/items?id=eq.2&select=id",
    headers: [rb],
    stateful: true
  },
  %{
    id: "update_delete/delete-select-rename-cast",
    method: "DELETE",
    path: "/projects?id=eq.5&select=pId:id::text,pName:name",
    headers: [rep],
    stateful: true
  },
  %{
    id: "update_delete/delete-no-match",
    method: "DELETE",
    path: "/items?id=eq.999",
    headers: [rep],
    stateful: true
  },
  %{
    id: "update_delete/delete-no-match-minimal",
    method: "DELETE",
    path: "/items?id=eq.999",
    headers: [min],
    stateful: true
  },
  %{
    id: "update_delete/delete-count-exact",
    method: "DELETE",
    path: "/items?id=lt.4",
    headers: [cnt],
    stateful: true
  },
  %{
    id: "update_delete/delete-no-filter-all-rows",
    method: "DELETE",
    path: "/items",
    headers: [rep],
    plug_opts: unsafe,
    sort: true,
    stateful: true
  },
  %{
    id: "update_delete/delete-pk-less",
    method: "DELETE",
    path: "/no_pk?a=eq.1",
    headers: [rep],
    stateful: true
  },
  %{
    id: "update_delete/delete-logic-tree",
    method: "DELETE",
    path: "/items?or=(id.eq.1,id.eq.2)&select=id",
    headers: [rep],
    sort: true,
    stateful: true
  },
  %{
    id: "update_delete/delete-embed-parent",
    method: "DELETE",
    path: "/projects?id=eq.5&select=id,clients(id)",
    headers: [rep],
    stateful: true
  },
  %{
    id: "update_delete/delete-unknown-table",
    method: "DELETE",
    path: "/fake?id=eq.1",
    headers: [rb],
    stateful: true
  },
  %{
    id: "update_delete/delete-typo-filter",
    method: "DELETE",
    path: "/items?idd=eq.1",
    headers: [rb],
    stateful: true
  },
  %{
    id: "update_delete/delete-fk-violation",
    method: "DELETE",
    path: "/clients?id=eq.1",
    headers: [rb],
    stateful: true
  },
  %{
    id: "update_delete/delete-singular-one-row",
    method: "DELETE",
    path: "/items?id=eq.3&select=id",
    headers: [rep, single],
    stateful: true
  },
  %{
    id: "update_delete/delete-singular-many-rows",
    method: "DELETE",
    path: "/items?id=lt.6",
    headers: [rep, single],
    stateful: true
  },
  %{
    id: "update_delete/delete-singular-no-rows",
    method: "DELETE",
    path: "/items?id=eq.999",
    headers: [rep, single],
    stateful: true
  },
  # --- embedded parameters never select silently (review round 1) ----------------------
  %{
    id: "update_delete/patch-embedded-param-minimal",
    method: "PATCH",
    path: "/projects?clients.id=eq.1",
    headers: [rb],
    body: %{"name" => "x"},
    stateful: true
  },
  %{
    id: "update_delete/patch-embedded-param-with-filter",
    method: "PATCH",
    path: "/projects?id=lt.3&clients.name=eq.Nope",
    headers: [rb],
    body: %{"name" => "x"},
    stateful: true
  },
  %{
    id: "update_delete/delete-embedded-param-count",
    method: "DELETE",
    path: "/projects?id=gt.4&clients.id=eq.1",
    headers: [cnt],
    stateful: true
  },
  %{
    id: "update_delete/patch-embedded-param-minimal-unsafe",
    method: "PATCH",
    path: "/projects?clients.id=eq.1",
    headers: [rb],
    body: %{"name" => "x"},
    plug_opts: unsafe,
    stateful: true
  },
  %{
    id: "update_delete/patch-embedded-param-with-filter-unsafe",
    method: "PATCH",
    path: "/projects?id=lt.3&clients.name=eq.Nope",
    headers: [rb],
    body: %{"name" => "x"},
    plug_opts: unsafe,
    stateful: true
  },
  %{
    id: "update_delete/delete-embedded-param-count-unsafe",
    method: "DELETE",
    path: "/projects?id=gt.4&clients.id=eq.1",
    headers: [cnt],
    plug_opts: unsafe,
    stateful: true
  },
  %{
    id: "update_delete/patch-embed-is-null-representation",
    method: "PATCH",
    path: "/projects?id=eq.1&select=id,clients(id)&clients=is.null",
    headers: [rep],
    body: %{"name" => "x"},
    stateful: true
  },
  %{
    id: "update_delete/patch-limit-offset-order",
    method: "PATCH",
    path: "/complex_items?id=gt.0&limit=1&offset=1&order=id.desc&select=id",
    headers: [rep],
    body: %{"name" => "x"},
    stateful: true
  },
  %{
    id: "update_delete/patch-limit-offset-minimal",
    method: "PATCH",
    path: "/complex_items?id=gt.0&limit=1&offset=1&order=id.desc",
    headers: [cnt],
    body: %{"name" => "x"},
    stateful: true
  },
  %{
    id: "update_delete/delete-limit-offset-order",
    method: "DELETE",
    path: "/items?id=gt.0&limit=2&offset=1&order=id.desc&select=id",
    headers: [repcnt],
    stateful: true
  },
  %{
    id: "update_delete/delete-limit-offset-minimal",
    method: "DELETE",
    path: "/items?id=gt.0&limit=2&offset=1&order=id.desc",
    headers: [cnt],
    stateful: true
  },
  # PgRest deviation: PostgREST applies one object of the array arbitrarily.
  %{
    id: "update_delete/patch-array-of-two-objects",
    method: "PATCH",
    path: "/complex_items?id=eq.1",
    headers: [rb],
    body: [%{"name" => "a"}, %{"name" => "b"}],
    stateful: true,
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST102",
        "details" => nil,
        "hint" => nil,
        "message" => "PATCH takes one object, not an array of several"
      }
    }
  },
  %{
    id: "update_delete/patch-dotted-json-key",
    method: "PATCH",
    path: "/complex_items?settings-%3E%3E%22a.b%22=eq.zzz",
    headers: [rep],
    body: %{"name" => "mass"},
    stateful: true
  },
  %{
    id: "update_delete/patch-dotted-json-key-unsafe",
    method: "PATCH",
    path: "/complex_items?settings-%3E%3E%22a.b%22=eq.zzz",
    headers: [rep],
    body: %{"name" => "mass"},
    plug_opts: unsafe,
    stateful: true
  },
  %{
    id: "update_delete/delete-dotted-json-key",
    method: "DELETE",
    path: "/complex_items?settings-%3E%3E%22a.b%22=eq.zzz",
    headers: [rep],
    stateful: true
  },
  %{
    id: "update_delete/delete-dotted-json-key-unsafe",
    method: "DELETE",
    path: "/complex_items?settings-%3E%3E%22a.b%22=eq.zzz",
    headers: [rep],
    plug_opts: unsafe,
    stateful: true
  },
  %{
    id: "update_delete/patch-dotted-column",
    method: "PATCH",
    path: "/complex_items?%22a.b%22=eq.x",
    headers: [rep],
    body: %{"name" => "mass"},
    stateful: true
  },
  %{
    id: "update_delete/patch-dotted-column-unsafe",
    method: "PATCH",
    path: "/complex_items?%22a.b%22=eq.x",
    headers: [rep],
    body: %{"name" => "mass"},
    plug_opts: unsafe,
    stateful: true
  },
  %{
    id: "update_delete/delete-dotted-column",
    method: "DELETE",
    path: "/complex_items?%22a.b%22=eq.x",
    headers: [rep],
    stateful: true
  },
  %{
    id: "update_delete/delete-dotted-column-unsafe",
    method: "DELETE",
    path: "/complex_items?%22a.b%22=eq.x",
    headers: [rep],
    plug_opts: unsafe,
    stateful: true
  },
  %{
    id: "update_delete/patch-embedded-logic",
    method: "PATCH",
    path: "/projects?id=eq.1&clients.or=(id.eq.1)",
    headers: [rb],
    body: %{"name" => "x"},
    stateful: true,
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST100",
        "details" => nil,
        "hint" => nil,
        "message" => "embedded logic trees are not supported on mutations"
      }
    }
  },
  %{
    id: "update_delete/patch-embedded-not-logic",
    method: "PATCH",
    path: "/projects?id=eq.1&clients.not.or=(id.eq.1)",
    headers: [rb],
    body: %{"name" => "x"},
    stateful: true,
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST100",
        "details" => nil,
        "hint" => nil,
        "message" => "embedded logic trees are not supported on mutations"
      }
    }
  },
  %{
    id: "update_delete/patch-embedded-limit-minimal",
    method: "PATCH",
    path: "/projects?id=lt.3&clients.limit=1",
    headers: [rb],
    body: %{"name" => "x"},
    stateful: true,
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST108",
        "details" => nil,
        "hint" => "Verify that 'clients' is included in the 'select' query parameter.",
        "message" => "'clients' is not an embedded resource in this request"
      }
    }
  },
  %{
    id: "update_delete/delete-embedded-offset-minimal",
    method: "DELETE",
    path: "/projects?id=gt.4&clients.offset=1",
    headers: [rb],
    stateful: true,
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST108",
        "details" => nil,
        "hint" => "Verify that 'clients' is included in the 'select' query parameter.",
        "message" => "'clients' is not an embedded resource in this request"
      }
    }
  },

  # The 21000 "requires a WHERE clause" cases live in scenarios/safeupdate.exs.
  %{
    id: "update_delete/patch-empty-object-needs-no-where",
    method: "PATCH",
    path: "/no_pk",
    headers: [rb],
    body: %{},
    stateful: true,
    only: :pgrest,
    expect: %{
      status: 204,
      headers: %{"content-range" => "*/*", "preference-applied" => "tx=rollback"}
    }
  },
  %{
    id: "update_delete/patch-logic-tree-satisfies-where",
    method: "PATCH",
    path: "/no_pk?or=(a.eq.1,a.eq.2)",
    headers: [rb],
    body: %{"b" => "1"},
    stateful: true,
    only: :pgrest,
    expect: %{
      status: 204,
      headers: %{"content-range" => "0-1/*", "preference-applied" => "tx=rollback"}
    }
  }
]
