# PUT single-row upsert, ported from UpsertSpec.hs "with PUT" (UP:385-661) and the web_content
# PUT case. Every scenario rolls back.
rep = {"prefer", "return=representation, tx=rollback"}
min = {"prefer", "return=minimal, tx=rollback"}
roll = {"prefer", "tx=rollback"}
single = {"accept", "application/vnd.pgrst.object+json"}

javascript = fn qs -> "/tiobe_pls?name=eq.Javascript" <> qs end

[
  # --- restrictions ----------------------------------------------------------------
  %{
    id: "put/limit",
    method: "PUT",
    path: javascript.("&limit=1"),
    headers: [roll],
    body: [%{"name" => "Javascript", "rank" => 1}],
    stateful: true
  },
  %{
    id: "put/offset",
    method: "PUT",
    path: javascript.("&offset=1"),
    headers: [roll],
    body: [%{"name" => "Javascript", "rank" => 1}],
    stateful: true
  },
  %{
    id: "put/filter-not-pk",
    method: "PUT",
    path: "/tiobe_pls?rank=eq.19",
    headers: [roll],
    body: [%{"name" => "Go", "rank" => 19}],
    stateful: true
  },
  %{
    id: "put/filter-negated",
    method: "PUT",
    path: "/tiobe_pls?id=not.eq.Java",
    headers: [roll],
    body: [%{"name" => "Go", "rank" => 19}],
    stateful: true
  },
  %{
    id: "put/filter-in",
    method: "PUT",
    path: "/tiobe_pls?id=in.(Go)",
    headers: [roll],
    body: [%{"name" => "Go", "rank" => 19}],
    stateful: true
  },
  %{
    id: "put/filter-logic",
    method: "PUT",
    path: "/tiobe_pls?and=(id.eq.Go)",
    headers: [roll],
    body: [%{"name" => "Go", "rank" => 19}],
    stateful: true
  },
  %{
    id: "put/filter-pk-plus-other",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go&rank=eq.19",
    headers: [roll],
    body: [%{"name" => "Go", "rank" => 19}],
    stateful: true
  },
  %{
    id: "put/filter-pk-neq",
    method: "PUT",
    path: "/tiobe_pls?name=neq.Go",
    headers: [roll],
    body: [%{"name" => "Go", "rank" => 19}],
    stateful: true
  },
  %{
    id: "put/filter-none",
    method: "PUT",
    path: "/tiobe_pls",
    headers: [roll],
    body: [%{"name" => "Go", "rank" => 19}],
    stateful: true
  },
  %{
    id: "put/composite-first-only",
    method: "PUT",
    path: "/employees?first_name=eq.Susan",
    headers: [roll],
    body: [
      %{
        "first_name" => "Susan",
        "last_name" => "Heidt",
        "salary" => "48000",
        "company" => "GEX",
        "occupation" => "Railroad engineer"
      }
    ],
    stateful: true
  },
  %{
    id: "put/composite-last-only",
    method: "PUT",
    path: "/employees?last_name=eq.Heidt",
    headers: [roll],
    body: [
      %{
        "first_name" => "Susan",
        "last_name" => "Heidt",
        "salary" => "48000",
        "company" => "GEX",
        "occupation" => "Railroad engineer"
      }
    ],
    stateful: true
  },
  %{
    id: "put/no-pk-table",
    method: "PUT",
    path: "/no_pk?a=eq.one&b=eq.two",
    headers: [roll],
    body: [%{"a" => "one", "b" => "two"}],
    stateful: true
  },
  %{
    id: "put/compound-pk-payload-missing-key",
    method: "PUT",
    path: "/compound_pk?k1=eq.1&k2=eq.2",
    headers: [roll],
    body: %{"k1" => 1},
    stateful: true,
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST115",
        "details" => nil,
        "hint" => nil,
        "message" => "Payload values do not match URL in primary key column(s)"
      }
    }
  },

  # --- payload must match the URL --------------------------------------------------
  %{
    id: "put/pk-mismatch",
    method: "PUT",
    path: "/tiobe_pls?name=eq.MATLAB",
    headers: [roll],
    body: [%{"name" => "Perl", "rank" => 17}],
    stateful: true
  },
  %{
    id: "put/pk-mismatch-composite",
    method: "PUT",
    path: "/employees?first_name=eq.Wendy&last_name=eq.Anderson",
    headers: [roll],
    body: [
      %{
        "first_name" => "Susan",
        "last_name" => "Heidt",
        "salary" => "48000",
        "company" => "GEX",
        "occupation" => "Railroad engineer"
      }
    ],
    stateful: true
  },
  %{
    id: "put/pk-missing-in-payload",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [roll],
    body: %{"rank" => 19},
    stateful: true,
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST115",
        "details" => nil,
        "hint" => nil,
        "message" => "Payload values do not match URL in primary key column(s)"
      }
    }
  },
  %{
    id: "put/pk-null-in-payload",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [roll],
    body: %{"name" => nil, "rank" => 19},
    stateful: true
  },
  %{
    id: "put/pk-number-vs-text",
    method: "PUT",
    path: "/only_pk?id=eq.10",
    headers: [rep],
    body: %{"id" => "10"},
    stateful: true
  },
  %{
    id: "put/empty-array",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [roll],
    body: [],
    stateful: true,
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST115",
        "details" => nil,
        "hint" => nil,
        "message" => "Payload values do not match URL in primary key column(s)"
      }
    }
  },
  %{
    id: "put/duplicate-pk-filter-equal",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go&name=eq.Go",
    headers: [rep],
    body: %{"name" => "Go", "rank" => 19},
    stateful: true
  },
  %{
    id: "put/duplicate-pk-filter-different",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go&name=eq.Rust",
    headers: [rep],
    body: %{"name" => "Go", "rank" => 19},
    stateful: true
  },

  # --- inserting -------------------------------------------------------------------
  %{
    id: "put/insert-single-pk",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [rep],
    body: [%{"name" => "Go", "rank" => 19}],
    stateful: true
  },
  %{
    id: "put/insert-single-pk-minimal",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [min],
    body: [%{"name" => "Go", "rank" => 19}],
    stateful: true
  },
  %{
    id: "put/insert-single-pk-default-prefer",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [roll],
    body: %{"name" => "Go", "rank" => 19},
    stateful: true
  },
  %{
    id: "put/insert-headers-only",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [{"prefer", "return=headers-only, tx=rollback"}],
    body: %{"name" => "Go", "rank" => 19},
    stateful: true
  },
  %{
    id: "put/insert-composite-pk",
    method: "PUT",
    path: "/employees?first_name=eq.Susan&last_name=eq.Heidt",
    headers: [rep],
    body: [
      %{
        "first_name" => "Susan",
        "last_name" => "Heidt",
        "salary" => "48000",
        "company" => "GEX",
        "occupation" => "Railroad engineer"
      }
    ],
    stateful: true
  },
  %{
    id: "put/insert-partitioned-composite-pk",
    method: "PUT",
    path: "/car_models?name=eq.Supra&year=eq.2021",
    headers: [rep],
    body: [%{"name" => "Supra", "year" => 2021}],
    stateful: true
  },
  %{
    id: "put/insert-only-pk-cols",
    method: "PUT",
    path: "/only_pk?id=eq.10",
    headers: [rep],
    body: [%{"id" => 10}],
    stateful: true
  },
  %{
    id: "put/insert-object-media",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Ruby",
    headers: [rep, single],
    body: [%{"name" => "Ruby", "rank" => 11}],
    stateful: true
  },
  %{
    id: "put/insert-select",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go&select=rank",
    headers: [rep],
    body: %{"name" => "Go", "rank" => 19},
    stateful: true
  },
  %{
    id: "put/insert-count-exact",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [{"prefer", "return=representation, count=exact, tx=rollback"}],
    body: %{"name" => "Go", "rank" => 19},
    stateful: true
  },
  %{
    id: "put/insert-resolution-ignored",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Java",
    headers: [{"prefer", "resolution=ignore-duplicates, return=representation, tx=rollback"}],
    body: %{"name" => "Java", "rank" => 7},
    stateful: true
  },
  %{
    id: "put/on-conflict-ignored",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Java&on_conflict=rank",
    headers: [rep],
    body: %{"name" => "Java", "rank" => 7},
    stateful: true
  },
  %{
    id: "put/insert-unknown-column",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [roll],
    body: %{"name" => "Go", "nope" => 1},
    stateful: true
  },

  # --- updating --------------------------------------------------------------------
  %{
    id: "put/update-single-pk",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Java",
    headers: [rep],
    body: [%{"name" => "Java", "rank" => 13}],
    stateful: true
  },
  %{
    id: "put/update-single-pk-minimal",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Java",
    headers: [min],
    body: [%{"name" => "Java", "rank" => 13}],
    stateful: true
  },
  %{
    id: "put/update-first-element-only",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Java",
    headers: [rep, single],
    body: [%{"name" => "Java", "rank" => 19}, %{"name" => "Swift", "rank" => 12}],
    stateful: true
  },
  %{
    id: "put/update-second-element-matches",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Java",
    headers: [rep],
    body: [%{"name" => "Swift", "rank" => 12}, %{"name" => "Java", "rank" => 19}],
    stateful: true
  },
  %{
    id: "put/update-two-matching-elements",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Java",
    headers: [rep],
    body: [%{"name" => "Java", "rank" => 19}, %{"name" => "Java", "rank" => 20}],
    stateful: true,
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST102",
        "details" => nil,
        "hint" => nil,
        "message" => "PUT takes one row, but several payload objects match the URL"
      }
    }
  },
  # --- typed key comparison and whole-array validation ------------------------------
  %{
    id: "put/pk-typed-url-leading-zero",
    method: "PUT",
    path: "/only_pk?id=eq.01",
    headers: [rep],
    body: %{"id" => 1},
    stateful: true
  },
  %{
    id: "put/pk-typed-payload-leading-zero",
    method: "PUT",
    path: "/only_pk?id=eq.1",
    headers: [rep],
    body: %{"id" => "01"},
    stateful: true
  },
  %{
    id: "put/pk-payload-float-for-integer",
    method: "PUT",
    path: "/only_pk?id=eq.1",
    headers: [rep],
    body: %{"id" => 1.0},
    stateful: true
  },
  %{
    id: "put/pk-payload-boolean-for-integer",
    method: "PUT",
    path: "/only_pk?id=eq.1",
    headers: [rep],
    body: %{"id" => true},
    stateful: true
  },
  %{
    id: "put/pk-url-not-castable",
    method: "PUT",
    path: "/only_pk?id=eq.x",
    headers: [rep],
    body: %{"id" => "x"},
    stateful: true
  },
  %{
    id: "put/array-other-element-extra-key",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [rep],
    body: [%{"name" => "Go", "rank" => 1}, %{"name" => "Rust", "bogus" => 2}],
    stateful: true
  },
  %{
    id: "put/array-other-element-missing-key",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [rep],
    body: [%{"name" => "Go", "rank" => 1}, %{"name" => "Rust"}],
    stateful: true
  },
  %{
    id: "put/array-other-element-not-an-object",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [rep],
    body: [%{"name" => "Go", "rank" => 1}, 5],
    stateful: true
  },
  %{
    id: "put/array-other-element-type-error",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [rep],
    body: [%{"name" => "Go", "rank" => 1}, %{"name" => "Rust", "rank" => "x"}],
    stateful: true
  },
  %{
    id: "put/array-unknown-column-everywhere",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [rep],
    body: [%{"name" => "Go", "bogus" => 1}, %{"name" => "Rust", "bogus" => 2}],
    stateful: true
  },
  # --- response GUCs set by a trigger of the target ---------------------------------
  %{
    id: "put/response-guc-insert",
    method: "PUT",
    path: "/put_guc?id=eq.9",
    headers: [rep],
    body: %{"id" => 9, "c" => "c9"},
    response_headers: ["x-put"],
    stateful: true
  },
  %{
    id: "put/response-guc-update",
    method: "PUT",
    path: "/put_guc?id=eq.1",
    headers: [rep],
    body: %{"id" => 1, "c" => "c9"},
    response_headers: ["x-put"],
    stateful: true
  },
  # --- numeric key, validation left to the database, columns= ignored ---------------
  %{
    id: "put/pk-decimal-scale",
    method: "PUT",
    path: "/put_numeric?n=eq.1.50",
    headers: [rep],
    body: %{"n" => 1.5, "v" => "b"},
    stateful: true
  },
  %{
    id: "put/pk-whitespace",
    method: "PUT",
    path: "/only_pk?id=eq.1",
    headers: [rep],
    body: %{"id" => " 1"},
    stateful: true
  },
  %{
    id: "put/array-other-element-jsonb-scalar",
    method: "PUT",
    path: "/grandchild_entities?id=eq.100",
    headers: [rep],
    body: [%{"id" => 100, "jsonb_col" => nil}, %{"id" => 101, "jsonb_col" => 5}],
    stateful: true
  },
  %{
    id: "put/array-other-element-jsonb-array",
    method: "PUT",
    path: "/grandchild_entities?id=eq.100",
    headers: [rep],
    body: [%{"id" => 100, "jsonb_col" => nil}, %{"id" => 101, "jsonb_col" => [1, 2]}],
    stateful: true
  },
  %{
    id: "put/array-other-element-text-object",
    method: "PUT",
    path: "/grandchild_entities?id=eq.100",
    headers: [rep],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => %{"x" => 1}}],
    stateful: true
  },
  %{
    id: "put/array-other-element-text-array",
    method: "PUT",
    path: "/grandchild_entities?id=eq.100",
    headers: [rep],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => [1]}],
    stateful: true
  },
  %{
    id: "put/columns-ignored",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Java&columns=name",
    headers: [rep],
    body: %{"name" => "Java", "rank" => 5},
    stateful: true
  },
  %{
    id: "put/columns-unknown-ignored",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Java&columns=name,bogus",
    headers: [rep],
    body: %{"name" => "Java", "rank" => 5},
    stateful: true
  },
  %{
    id: "put/columns-non-uniform-keys",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go&columns=name,rank",
    headers: [rep],
    body: [%{"name" => "Go", "rank" => 1}, %{"name" => "Rust"}],
    stateful: true
  },
  %{
    id: "put/non-uniform-keys-before-filters",
    method: "PUT",
    path: "/tiobe_pls?rank=eq.1",
    headers: [rep],
    body: [%{"name" => "Go", "rank" => 1}, %{"name" => "Rust"}],
    stateful: true
  },
  %{
    id: "put/array-no-match-bad-other-element",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Zig",
    headers: [rep],
    body: [%{"name" => "Go", "rank" => 1}, %{"name" => "Rust", "rank" => "x"}],
    stateful: true
  },
  %{
    id: "put/array-no-match-persists-nothing",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Zig",
    headers: [rep],
    body: [%{"name" => "Go", "rank" => 1}, %{"name" => "Rust", "rank" => 2}],
    stateful: true
  },
  %{
    id: "put/update-composite-pk",
    method: "PUT",
    path: "/employees?first_name=eq.Frances%20M.&last_name=eq.Roe",
    headers: [rep],
    body: [
      %{
        "first_name" => "Frances M.",
        "last_name" => "Roe",
        "salary" => "60000",
        "company" => "Gamma Gas",
        "occupation" => "Railroad engineer"
      }
    ],
    stateful: true
  },
  %{
    id: "put/update-partitioned-composite-pk",
    method: "PUT",
    path: "/car_models?name=eq.DeLorean&year=eq.1981",
    headers: [rep],
    body: [%{"name" => "DeLorean", "year" => 1981, "car_brand_name" => nil}],
    stateful: true
  },
  %{
    id: "put/update-only-pk-cols",
    method: "PUT",
    path: "/only_pk?id=eq.1",
    headers: [rep],
    body: [%{"id" => 1}],
    stateful: true
  },
  %{
    id: "put/update-ignores-range",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Java",
    headers: [rep, {"range", "1-1"}],
    body: [%{"name" => "Java", "rank" => 5}],
    stateful: true
  },
  %{
    id: "put/update-partial-payload-keeps-other-columns",
    method: "PUT",
    path: "/projects?id=eq.3",
    headers: [rep],
    body: %{"id" => 3, "name" => "Renamed"},
    stateful: true
  },
  %{
    id: "put/update-explicit-null",
    method: "PUT",
    path: "/projects?id=eq.3",
    headers: [rep],
    body: %{"id" => 3, "name" => "Renamed", "client_id" => nil},
    stateful: true
  },
  %{
    id: "put/update-not-null-violation",
    method: "PUT",
    path: "/projects?id=eq.3",
    headers: [rep],
    body: %{"id" => 3, "name" => nil},
    stateful: true
  },
  %{
    id: "put/update-check-violation",
    method: "PUT",
    path: "/projects?id=eq.3",
    headers: [rep],
    body: %{"id" => 3, "name" => String.duplicate("x", 101)},
    stateful: true
  },
  %{
    id: "put/update-fk-violation",
    method: "PUT",
    path: "/projects?id=eq.3",
    headers: [rep],
    body: %{"id" => 3, "name" => "Renamed", "client_id" => 999},
    stateful: true
  },
  %{
    id: "put/update-no-max-affected-bound",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Java",
    headers: [{"prefer", "return=representation, handling=strict, max-affected=0, tx=rollback"}],
    body: %{"name" => "Java", "rank" => 5},
    stateful: true
  },
  %{
    id: "put/update-missing-default-ignored",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Java",
    headers: [{"prefer", "missing=default, return=representation, tx=rollback"}],
    body: %{"name" => "Java"},
    stateful: true
  },

  # --- insert then update, in one scenario each ------------------------------------
  %{
    id: "put/camel-case-pk-minimal",
    method: "PUT",
    path: "/UnitTest?idUnitTest=eq.1",
    headers: [roll],
    body: [%{"idUnitTest" => 1, "nameUnitTest" => "unit test 1"}],
    stateful: true
  },
  %{
    id: "put/camel-case-pk-return-minimal",
    method: "PUT",
    path: "/UnitTest?idUnitTest=eq.1",
    headers: [min],
    body: [%{"idUnitTest" => 1, "nameUnitTest" => "unit test 1"}],
    stateful: true
  },
  %{
    id: "put/camel-case-pk-insert",
    method: "PUT",
    path: "/UnitTest?idUnitTest=eq.7",
    headers: [rep],
    body: [%{"idUnitTest" => 7, "nameUnitTest" => "unit test 7"}],
    stateful: true
  },

  # --- embedding in the representation ---------------------------------------------
  %{
    id: "put/embedded-resource-ordered",
    method: "PUT",
    path: "/web_content?id=eq.0&select=id,name,web_content(name)&web_content.order=name.asc",
    headers: [rep],
    body: %{"id" => 0, "name" => "tardis-upserted", "p_web_id" => 5},
    stateful: true
  },

  # --- errors on the request itself ------------------------------------------------
  %{
    id: "put/unknown-table",
    method: "PUT",
    path: "/nope?id=eq.1",
    headers: [roll],
    body: %{"id" => 1},
    stateful: true
  },
  %{
    id: "put/invalid-json",
    method: "PUT",
    path: "/tiobe_pls?name=eq.Go",
    headers: [roll, {"content-type", "application/json"}],
    body: "{not json",
    stateful: true
  }
]
