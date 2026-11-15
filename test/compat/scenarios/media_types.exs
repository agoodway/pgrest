# Media types (Phase 2 Task 8): Accept negotiation, text/csv, `nulls=stripped` and PGRST107.
# Ported from upstream v14.18 QuerySpec (the Accept/CSV cases), RpcSpec ("returns CSV") and
# NullsStripSpec, plus postgrest-js's csv() and stripNulls() cases. The CSV edge rows are the
# committed `csv_edge_cases` fixture table, so a later GET sees the same bytes on both engines.
csv = {"accept", "text/csv"}
rep = {"prefer", "return=representation, tx=rollback"}
array_strip = {"accept", "application/vnd.pgrst.array+json;nulls=stripped"}
object_strip = {"accept", "application/vnd.pgrst.object+json;nulls=stripped"}

org = %{"id" => 7, "name" => "John", "referee" => nil, "auditor" => nil, "manager_id" => 6}

edge_rows =
  for id <- 1..9 do
    %{
      id: "media_types/csv-edge-case-#{id}",
      path: "/csv_edge_cases?select=id,txt,js,arr&id=eq.#{id}",
      headers: [csv]
    }
  end

[
  # --- Accept negotiation on a table (QuerySpec) ---------------------------------------
  %{
    id: "media_types/accept-any",
    path: "/clients?select=id&order=id",
    headers: [{"accept", "*/*"}]
  },
  %{
    id: "media_types/accept-unknown-rescued-by-any",
    path: "/clients?select=id&order=id",
    headers: [{"accept", "text/unknowntype, */*"}]
  },
  %{
    id: "media_types/accept-csv-overrides-any",
    path: "/clients?select=id,name&order=id",
    headers: [{"accept", "text/csv, */*"}]
  },
  %{
    id: "media_types/accept-csv-before-json",
    path: "/clients?select=id,name&order=id",
    headers: [{"accept", "text/csv, application/json"}]
  },
  %{
    id: "media_types/accept-json-q-over-csv",
    path: "/clients?select=id,name&order=id",
    headers: [{"accept", "text/csv;q=0.5, application/json"}]
  },
  %{
    id: "media_types/accept-unknown-then-csv",
    path: "/clients?select=id,name&order=id",
    headers: [{"accept", "text/unknowntype, text/csv"}]
  },
  %{
    id: "media_types/accept-csv-version-param",
    path: "/clients?select=id,name&order=id",
    headers: [{"accept", "text/csv; version=1"}]
  },
  %{
    id: "media_types/accept-csv-uppercase",
    path: "/clients?select=id,name&order=id",
    headers: [{"accept", "TEXT/CSV"}]
  },
  %{
    id: "media_types/accept-unknown-only",
    path: "/clients?select=id",
    headers: [{"accept", "text/unknowntype"}]
  },
  %{
    id: "media_types/accept-two-unknown-request-order",
    path: "/clients?select=id",
    headers: [{"accept", "text/unknowntype, text/other"}]
  },
  %{
    id: "media_types/accept-geo-json",
    path: "/projects?select=id",
    headers: [{"accept", "application/geo+json"}],
    only: :pgrest,
    expect: %{
      status: 406,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST107",
        "details" => nil,
        "hint" => nil,
        "message" => "None of these media types are available: application/geo+json"
      }
    }
  },
  %{
    id: "media_types/accept-array-json-plain",
    path: "/organizations?select=id,referee,auditor&order=id",
    headers: [{"accept", "application/vnd.pgrst.array+json"}]
  },
  %{
    id: "media_types/accept-array-without-json-suffix",
    path: "/organizations?select=id,referee&order=id",
    headers: [{"accept", "application/vnd.pgrst.array"}]
  },
  # --- CSV on a table: the committed edge rows -----------------------------------------
  %{
    id: "media_types/csv-edge-all",
    path: "/csv_edge_cases?select=id,txt,js,arr&order=id",
    headers: [csv]
  },
  %{
    id: "media_types/csv-edge-subset",
    path: "/csv_edge_cases?select=txt&order=id",
    headers: [csv]
  },
  %{
    id: "media_types/csv-edge-empty",
    path: "/csv_edge_cases?select=id,txt&id=eq.0",
    headers: [csv]
  },
  %{
    id: "media_types/csv-edge-head",
    method: "HEAD",
    path: "/csv_edge_cases?select=id,txt",
    headers: [csv]
  },
  %{
    id: "media_types/csv-edge-count-range",
    path: "/csv_edge_cases?select=id,txt&order=id",
    headers: [csv, {"prefer", "count=exact"}, {"range", "1-3"}]
  },
  %{
    id: "media_types/csv-embed",
    path: "/clients?select=id,projects(id,name)&id=eq.1&projects.order=id",
    headers: [csv]
  },
  %{
    id: "media_types/csv-spread",
    path: "/projects?select=id,...clients(client:name)&order=id",
    headers: [csv]
  },
  %{
    id: "media_types/csv-aggregate",
    path: "/projects?select=client_id,n:count()&order=client_id",
    headers: [csv]
  },
  %{
    id: "media_types/csv-unknown-column",
    path: "/clients?select=nope",
    headers: [csv]
  }
  | edge_rows
] ++
  [
    # --- CSV on RPC (RpcSpec "returns CSV", the Task 6 pending id) ------------------------
    %{
      id: "media_types/rpc-getitemrange-csv-post",
      method: "POST",
      path: "/rpc/getitemrange",
      headers: [csv],
      body: %{"min" => 2, "max" => 4}
    },
    %{
      id: "media_types/rpc-getitemrange-csv-get",
      path: "/rpc/getitemrange?min=2&max=4",
      headers: [csv]
    },
    %{
      id: "media_types/rpc-getitemrange-csv-head",
      method: "HEAD",
      path: "/rpc/getitemrange?min=2&max=4",
      headers: [csv]
    },
    %{
      id: "media_types/rpc-getallprojects-csv",
      path: "/rpc/getallprojects?select=id,name&order=id",
      headers: [csv]
    },
    %{id: "media_types/rpc-many-out-params-csv", path: "/rpc/many_out_params", headers: [csv]},
    %{id: "media_types/rpc-add-them-csv", path: "/rpc/add_them?a=1&b=2", headers: [csv]},
    %{id: "media_types/rpc-ret-void-csv", method: "POST", path: "/rpc/ret_void", headers: [csv]},
    %{
      id: "media_types/rpc-getallprojects-array-json",
      path: "/rpc/getallprojects?select=id&order=id&limit=2",
      headers: [{"accept", "application/vnd.pgrst.array+json"}]
    },
    %{
      id: "media_types/rpc-getallprojects-array-stripped",
      path: "/rpc/getallprojects?select=id,client_id&order=id",
      headers: [array_strip]
    },
    %{
      id: "media_types/rpc-getproject-object-stripped",
      path: "/rpc/getproject?id=4&select=id,client_id",
      headers: [object_strip]
    },
    %{
      id: "media_types/rpc-add-them-array-json",
      path: "/rpc/add_them?a=1&b=2",
      headers: [{"accept", "application/vnd.pgrst.array+json"}]
    },
    %{
      id: "media_types/rpc-add-them-object-stripped",
      path: "/rpc/add_them?a=1&b=2",
      headers: [object_strip]
    },
    # --- Accept ties are broken by specificity (parameters count for, `*` against) ----------
    %{
      id: "media_types/accept-any-then-csv",
      path: "/clients?select=id,name&order=id",
      headers: [{"accept", "*/*, text/csv"}]
    },
    %{
      id: "media_types/accept-json-then-csv-with-param",
      path: "/clients?select=id,name&order=id",
      headers: [{"accept", "application/json, text/csv;version=1"}]
    },
    %{
      id: "media_types/accept-unknown-list-specificity-order",
      path: "/clients?select=id",
      headers: [{"accept", "text/foo, text/bar;a=b, text/baz;q=0.5"}]
    },
    # --- the CSV header of reads: empty results, aliases, embeds ---------------------------
    %{
      id: "media_types/csv-rpc-empty-filter",
      path: "/rpc/getallprojects?id=eq.999",
      headers: [csv]
    },
    %{
      id: "media_types/csv-rpc-empty-filter-select",
      path: "/rpc/getallprojects?id=eq.999&select=name",
      headers: [csv],
      only: :pgrest,
      expect: %{
        status: 200,
        headers: %{"content-type" => "text/csv; charset=utf-8", "content-range" => "*/*"},
        body: "name\n"
      }
    },
    %{
      id: "media_types/csv-rpc-limit-zero",
      path: "/rpc/getallprojects?limit=0",
      headers: [csv]
    },
    %{
      id: "media_types/csv-rpc-alias-limit-zero",
      path: "/rpc/getallprojects?select=n:name&limit=0",
      headers: [csv],
      only: :pgrest,
      expect: %{
        status: 200,
        headers: %{"content-type" => "text/csv; charset=utf-8", "content-range" => "*/*"},
        body: "n\n"
      }
    },
    %{
      id: "media_types/csv-rpc-embed-empty",
      path: "/rpc/getallprojects?select=name,clients(name)&id=eq.999",
      headers: [csv],
      only: :pgrest,
      expect: %{
        status: 200,
        headers: %{"content-type" => "text/csv; charset=utf-8", "content-range" => "*/*"},
        body: "name,clients\n"
      }
    },
    %{
      id: "media_types/csv-rpc-filter-column-in-header",
      path: "/rpc/getallprojects?select=name&id=eq.1",
      headers: [csv],
      only: :pgrest,
      expect: %{
        status: 200,
        headers: %{"content-type" => "text/csv; charset=utf-8", "content-range" => "0-0/*"},
        body: "name\n\"Windows 7\""
      }
    },
    %{
      id: "media_types/csv-rpc-composite-empty",
      path: "/rpc/getitemrange?min=2&max=4&select=id&id=eq.99",
      headers: [csv]
    },
    %{
      id: "media_types/csv-table-limit-zero",
      path: "/clients?select=id,name&limit=0",
      headers: [csv]
    },
    %{
      id: "media_types/csv-table-alias",
      path: "/clients?select=n:name,id&order=id&limit=2",
      headers: [csv]
    },
    %{
      id: "media_types/csv-table-embed-empty",
      path: "/clients?select=id,projects(id)&id=eq.999",
      headers: [csv]
    },
    # PgRest's header matches the body columns on writes; PostgREST's is the RETURNING set
    # (`id,name` for `select=name`), a known difference (docs/guides/compatibility.md).
    %{
      id: "media_types/post-csv-select-subset",
      method: "POST",
      path: "/projects?select=name",
      headers: [csv, rep],
      body: %{"id" => 100, "name" => "new", "client_id" => 1},
      stateful: true,
      only: :pgrest,
      expect: %{
        status: 201,
        headers: %{
          "content-type" => "text/csv; charset=utf-8",
          "content-range" => "*/*",
          "preference-applied" => "return=representation, tx=rollback"
        },
        body: "name\nnew"
      }
    },
    %{
      id: "media_types/post-csv-alias-and-embed",
      method: "POST",
      path: "/projects?select=n:name,clients(name)",
      headers: [csv, rep],
      body: %{"id" => 100, "name" => "new", "client_id" => 1},
      stateful: true,
      only: :pgrest,
      expect: %{
        status: 201,
        headers: %{
          "content-type" => "text/csv; charset=utf-8",
          "content-range" => "*/*",
          "preference-applied" => "return=representation, tx=rollback"
        },
        body: "n,clients\nnew,\"{\"\"name\"\": \"\"Microsoft\"\"}\""
      }
    },
    # --- CSV on writes ---------------------------------------------------------------------
    %{
      id: "media_types/post-csv-representation",
      method: "POST",
      path: "/projects?select=id,name",
      headers: [csv, rep],
      body: %{"id" => 100, "name" => "new", "client_id" => 1},
      stateful: true
    },
    %{
      id: "media_types/post-csv-bulk-representation",
      method: "POST",
      path: "/projects?select=id,name",
      headers: [csv, rep],
      body: [
        %{"id" => 100, "name" => "a,b", "client_id" => 1},
        %{"id" => 101, "name" => "say \"hi\"", "client_id" => 1}
      ],
      stateful: true
    },
    %{
      id: "media_types/post-csv-minimal",
      method: "POST",
      path: "/projects",
      headers: [csv, {"prefer", "tx=rollback"}],
      body: %{"id" => 100, "name" => "new", "client_id" => 1},
      stateful: true
    },
    %{
      id: "media_types/patch-csv-representation",
      method: "PATCH",
      path: "/projects?id=eq.1&select=id,name",
      headers: [csv, rep],
      body: %{"name" => "renamed"},
      stateful: true
    },
    %{
      id: "media_types/delete-csv-representation",
      method: "DELETE",
      path: "/tasks?id=eq.1&select=id,name",
      headers: [csv, rep],
      stateful: true
    },
    # --- nulls=stripped (NullsStripSpec) ---------------------------------------------------
    %{
      id: "media_types/stripped-array-get",
      path: "/organizations?select=*&order=id",
      headers: [array_strip]
    },
    %{
      id: "media_types/stripped-array-post",
      method: "POST",
      path: "/organizations?select=*",
      headers: [array_strip, rep],
      body: org,
      stateful: true
    },
    %{
      id: "media_types/stripped-array-patch",
      method: "PATCH",
      path: "/organizations?id=eq.3&select=*",
      headers: [array_strip, rep],
      body: %{"name" => "John", "referee" => nil},
      stateful: true
    },
    %{
      id: "media_types/stripped-name-uppercase",
      path: "/organizations?select=id,referee&order=id&limit=3",
      headers: [{"accept", "application/vnd.pgrst.array+json;NULLS=stripped"}]
    },
    %{
      id: "media_types/stripped-value-quoted",
      path: "/organizations?select=id,referee&order=id&limit=3",
      headers: [{"accept", ~S|application/vnd.pgrst.array+json;nulls="stripped"|}]
    },
    %{
      id: "media_types/stripped-array-without-json-suffix",
      path: "/organizations?select=*&order=id",
      headers: [{"accept", "application/vnd.pgrst.array;nulls=stripped"}]
    },
    %{
      id: "media_types/stripped-object-get",
      path: "/organizations?limit=1&order=id",
      headers: [object_strip]
    },
    %{
      id: "media_types/stripped-object-not-singular",
      path: "/organizations?select=*",
      headers: [object_strip]
    },
    %{
      id: "media_types/stripped-explicit-array-get",
      path: "/organizations?select=id,referee,auditor&order=id",
      headers: [array_strip]
    },
    %{
      id: "media_types/stripped-explicit-array-post",
      method: "POST",
      path: "/organizations?select=id,referee,auditor",
      headers: [array_strip, rep],
      body: org,
      stateful: true
    },
    %{
      id: "media_types/stripped-explicit-array-patch",
      method: "PATCH",
      path: "/organizations?id=eq.3&select=id,name,referee,auditor",
      headers: [array_strip, rep],
      body: %{"name" => "John", "referee" => nil},
      stateful: true
    },
    %{
      id: "media_types/stripped-explicit-object-get",
      path: "/organizations?select=id,referee,auditor&limit=1&order=id",
      headers: [object_strip]
    },
    %{
      id: "media_types/stripped-object-post",
      method: "POST",
      path: "/organizations?select=id,referee",
      headers: [object_strip, rep],
      body: org,
      stateful: true
    },
    %{
      id: "media_types/stripped-object-patch-no-match",
      method: "PATCH",
      path: "/organizations?id=eq.999&select=id",
      headers: [object_strip, rep],
      body: %{"name" => "John"},
      stateful: true
    },
    %{
      id: "media_types/stripped-embed",
      path: "/organizations?select=id,referee(id,name),auditor(id)&id=in.(1,3)&order=id",
      headers: [array_strip]
    },
    %{
      id: "media_types/stripped-json-column",
      path: "/csv_edge_cases?select=id,js&id=in.(8,9)&order=id",
      headers: [array_strip]
    },
    # --- postgrest-js (supabase fixture): csv() and stripNulls() ---------------------------
    %{
      id: "media_types/supabase-csv-users",
      fixture: :supabase,
      path: "/users?select=*&order=username",
      headers: [csv]
    },
    %{
      id: "media_types/supabase-strip-nulls",
      fixture: :supabase,
      path: "/users?select=*&order=username",
      headers: [array_strip]
    },
    %{
      id: "media_types/supabase-strip-nulls-single",
      fixture: :supabase,
      path: "/users?select=*&username=eq.supabot",
      headers: [object_strip]
    },
    %{
      id: "media_types/supabase-single",
      fixture: :supabase,
      path: "/users?select=*&username=eq.supabot",
      headers: [{"accept", "application/vnd.pgrst.object+json"}]
    }
  ]
