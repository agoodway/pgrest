merge = {"prefer", "resolution=merge-duplicates, return=representation, tx=rollback"}
merge_min = {"prefer", "resolution=merge-duplicates, tx=rollback"}
ignore = {"prefer", "resolution=ignore-duplicates, return=representation, tx=rollback"}
ignore_min = {"prefer", "resolution=ignore-duplicates, tx=rollback"}
single = {"accept", "application/vnd.pgrst.object+json"}

[
  # --- merge-duplicates: status rules ----------------------------------------------
  %{
    id: "upsert/merge-mixed",
    method: "POST",
    path: "/projects?select=id,name,client_id&order=id",
    headers: [merge],
    body: [
      %{"id" => 1, "name" => "Renamed", "client_id" => 2},
      %{"id" => 100, "name" => "new", "client_id" => nil}
    ],
    stateful: true
  },
  %{
    id: "upsert/merge-all-existing",
    method: "POST",
    path: "/projects?select=id,name,client_id&order=id",
    headers: [merge],
    body: [
      %{"id" => 1, "name" => "A", "client_id" => 1},
      %{"id" => 2, "name" => "B", "client_id" => 1}
    ],
    stateful: true
  },
  %{
    id: "upsert/merge-all-new",
    method: "POST",
    path: "/projects?select=id,name&order=id",
    headers: [merge],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => "b"}],
    stateful: true
  },
  %{
    id: "upsert/merge-single-existing",
    method: "POST",
    path: "/projects?select=id,name,client_id",
    headers: [merge],
    body: %{"id" => 1, "name" => "Solo"},
    stateful: true
  },
  %{
    id: "upsert/merge-single-new",
    method: "POST",
    path: "/projects?select=id,name",
    headers: [merge],
    body: %{"id" => 100, "name" => "Solo"},
    stateful: true
  },
  %{
    id: "upsert/merge-empty-array",
    method: "POST",
    path: "/projects",
    headers: [merge],
    body: [],
    stateful: true
  },
  %{
    id: "upsert/merge-empty-object-existing-pk",
    method: "POST",
    path: "/projects",
    headers: [merge],
    body: %{},
    stateful: true
  },
  %{
    id: "upsert/merge-minimal-existing",
    method: "POST",
    path: "/projects",
    headers: [merge_min],
    body: %{"id" => 1, "name" => "Solo"},
    stateful: true
  },
  %{
    id: "upsert/merge-minimal-new",
    method: "POST",
    path: "/projects",
    headers: [merge_min],
    body: %{"id" => 100, "name" => "Solo"},
    stateful: true
  },
  %{
    id: "upsert/merge-headers-only-existing",
    method: "POST",
    path: "/projects",
    headers: [{"prefer", "resolution=merge-duplicates, return=headers-only, tx=rollback"}],
    body: %{"id" => 1, "name" => "Solo"},
    stateful: true
  },
  %{
    id: "upsert/merge-count-exact",
    method: "POST",
    path: "/projects",
    headers: [{"prefer", "resolution=merge-duplicates, count=exact, tx=rollback"}],
    body: [%{"id" => 1, "name" => "A"}, %{"id" => 100, "name" => "b"}],
    stateful: true
  },
  %{
    id: "upsert/merge-singular-object",
    method: "POST",
    path: "/projects?select=id,name",
    headers: [merge, single],
    body: %{"id" => 1, "name" => "Solo"},
    stateful: true
  },
  # --- partial payload keeps the other columns ---------------------------------------
  %{
    id: "upsert/merge-partial-columns-retained",
    method: "POST",
    path: "/projects?select=id,name,client_id",
    headers: [merge],
    body: %{"id" => 3, "name" => "Only the name"},
    stateful: true
  },
  %{
    id: "upsert/merge-columns-param",
    method: "POST",
    path: "/projects?select=id,name,client_id&columns=id,name",
    headers: [merge],
    body: %{"id" => 3, "name" => "N", "client_id" => 1},
    stateful: true
  },
  # --- composite primary key ----------------------------------------------------------
  %{
    id: "upsert/merge-composite-pk",
    method: "POST",
    path: "/files?order=project_id,filename",
    headers: [merge],
    body: [
      %{"project_id" => 1, "filename" => "io.sys", "content" => "NEW"},
      %{"project_id" => 1, "filename" => "fresh.txt", "content" => "x"}
    ],
    stateful: true
  },
  %{
    id: "upsert/merge-composite-pk-all-existing",
    method: "POST",
    path: "/files",
    headers: [merge],
    body: [%{"project_id" => 1, "filename" => "io.sys", "content" => "NEW"}],
    stateful: true
  },
  # --- on_conflict ----------------------------------------------------------------------
  %{
    id: "upsert/on-conflict-unique-merge-mixed",
    method: "POST",
    path: "/accounts?on_conflict=email&select=id,email,role&order=id",
    headers: [merge],
    body: [
      %{"id" => 1, "email" => "alice@example.com", "role" => "admin"},
      %{"id" => 50, "email" => "new@example.com", "role" => "user"}
    ],
    stateful: true
  },
  %{
    id: "upsert/on-conflict-unique-merge-existing",
    method: "POST",
    path: "/accounts?on_conflict=email&select=id,email,role",
    headers: [merge],
    body: %{"id" => 1, "email" => "alice@example.com", "role" => "admin"},
    stateful: true
  },
  %{
    id: "upsert/on-conflict-other-key-moves-pk",
    method: "POST",
    path: "/accounts?on_conflict=email&select=id,email,role",
    headers: [merge],
    body: %{"id" => 60, "email" => "alice@example.com", "role" => "admin"},
    stateful: true
  },
  %{
    id: "upsert/on-conflict-compound-merge",
    method: "POST",
    path: "/files?on_conflict=project_id,filename",
    headers: [merge],
    body: [%{"project_id" => 2, "filename" => "README.md", "content" => "C"}],
    stateful: true
  },
  %{
    id: "upsert/on-conflict-no-matching-index",
    method: "POST",
    path: "/projects?on_conflict=name",
    headers: [merge],
    body: %{"id" => 100, "name" => "x"},
    stateful: true
  },
  %{
    id: "upsert/on-conflict-unknown-column",
    method: "POST",
    path: "/projects?on_conflict=nope",
    headers: [merge],
    body: %{"id" => 100, "name" => "x"},
    stateful: true
  },
  %{
    id: "upsert/on-conflict-blank",
    method: "POST",
    path: "/projects?on_conflict=",
    headers: [merge],
    body: %{"id" => 100, "name" => "x"},
    stateful: true
  },
  %{
    id: "upsert/on-conflict-without-resolution",
    method: "POST",
    path: "/capital?on_conflict=country_id",
    headers: [{"prefer", "return=representation, tx=rollback"}],
    body: %{"id" => 70, "name" => "Dup", "country_id" => 1},
    stateful: true
  },
  %{
    id: "upsert/on-conflict-unique-no-pk-table",
    method: "POST",
    path: "/addresses?on_conflict=id&select=id,address&order=id",
    headers: [merge],
    body: [%{"id" => 1, "address" => "changed"}, %{"id" => 9, "address" => "nine"}],
    stateful: true
  },
  # --- ignore-duplicates ----------------------------------------------------------------
  %{
    id: "upsert/ignore-mixed",
    method: "POST",
    path: "/projects?select=id,name&order=id",
    headers: [ignore],
    body: [%{"id" => 1, "name" => "Skipped"}, %{"id" => 100, "name" => "new"}],
    stateful: true
  },
  %{
    id: "upsert/ignore-all-existing",
    method: "POST",
    path: "/projects?select=id,name",
    headers: [ignore],
    body: [%{"id" => 1, "name" => "Skipped"}, %{"id" => 2, "name" => "Skipped"}],
    stateful: true
  },
  %{
    id: "upsert/ignore-all-new",
    method: "POST",
    path: "/projects?select=id,name&order=id",
    headers: [ignore],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 101, "name" => "b"}],
    stateful: true
  },
  %{
    id: "upsert/ignore-minimal",
    method: "POST",
    path: "/projects",
    headers: [ignore_min],
    body: %{"id" => 1, "name" => "Skipped"},
    stateful: true
  },
  %{
    id: "upsert/ignore-empty-array",
    method: "POST",
    path: "/projects",
    headers: [ignore],
    body: [],
    stateful: true
  },
  %{
    id: "upsert/ignore-count-exact",
    method: "POST",
    path: "/projects",
    headers: [{"prefer", "resolution=ignore-duplicates, count=exact, tx=rollback"}],
    body: [%{"id" => 1, "name" => "A"}, %{"id" => 100, "name" => "b"}],
    stateful: true
  },
  %{
    id: "upsert/ignore-on-conflict-unique",
    method: "POST",
    path: "/accounts?on_conflict=email&select=id,email&order=id",
    headers: [ignore],
    body: [
      %{"id" => 80, "email" => "alice@example.com", "role" => "admin"},
      %{"id" => 81, "email" => "fresh@example.com", "role" => "user"}
    ],
    stateful: true
  },
  %{
    id: "upsert/ignore-on-conflict-compound",
    method: "POST",
    path: "/files?on_conflict=project_id,filename",
    headers: [ignore],
    body: [%{"project_id" => 2, "filename" => "README.md", "content" => "C"}],
    stateful: true
  },
  %{
    id: "upsert/ignore-singular-no-row",
    method: "POST",
    path: "/projects",
    headers: [ignore, single],
    body: %{"id" => 1, "name" => "Skipped"},
    stateful: true
  },
  # --- missing=default ------------------------------------------------------------------
  %{
    id: "upsert/missing-default-merge",
    method: "POST",
    path: "/defaults_demo?select=id,label&order=id&columns=id,label",
    headers: [
      {"prefer",
       "resolution=merge-duplicates, missing=default, return=representation, tx=rollback"}
    ],
    body: [%{"id" => 1, "label" => "updated value"}, %{"label" => "new value"}],
    stateful: true
  },
  %{
    id: "upsert/missing-default-ignore",
    method: "POST",
    path: "/defaults_demo?select=id,label&order=id&columns=id,label",
    headers: [
      {"prefer",
       "resolution=ignore-duplicates, missing=default, return=representation, tx=rollback"}
    ],
    body: [%{"id" => 1, "label" => "updated value"}, %{"label" => "new value"}],
    stateful: true
  },
  # --- only primary key columns ---------------------------------------------------------
  %{
    id: "upsert/pk-only-merge",
    method: "POST",
    path: "/items?select=id&order=id",
    headers: [merge],
    body: [%{"id" => 1}, %{"id" => 100}],
    stateful: true
  },
  %{
    id: "upsert/pk-only-merge-existing",
    method: "POST",
    path: "/items?select=id",
    headers: [merge],
    body: [%{"id" => 1}],
    stateful: true
  },
  %{
    id: "upsert/pk-only-ignore",
    method: "POST",
    path: "/items?select=id&order=id",
    headers: [ignore],
    body: [%{"id" => 1}, %{"id" => 100}],
    stateful: true
  },
  # --- table without a primary key --------------------------------------------------------
  %{
    id: "upsert/no-pk-merge",
    method: "POST",
    path: "/no_pk",
    headers: [merge],
    body: [%{"a" => "x", "b" => "y"}],
    stateful: true
  },
  %{
    id: "upsert/no-pk-ignore",
    method: "POST",
    path: "/no_pk",
    headers: [ignore],
    body: [%{"a" => "x", "b" => "y"}],
    stateful: true
  },
  %{
    id: "upsert/no-pk-merge-empty-array",
    method: "POST",
    path: "/no_pk",
    headers: [merge],
    body: [],
    stateful: true
  },
  # --- errors ---------------------------------------------------------------------------
  %{
    id: "upsert/merge-duplicate-keys-in-payload",
    method: "POST",
    path: "/projects",
    headers: [merge],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 100, "name" => "b"}],
    stateful: true
  },
  %{
    id: "upsert/ignore-duplicate-keys-in-payload",
    method: "POST",
    path: "/projects?select=id,name",
    headers: [ignore],
    body: [%{"id" => 100, "name" => "a"}, %{"id" => 100, "name" => "b"}],
    stateful: true
  },
  %{
    id: "upsert/merge-not-null-violation",
    method: "POST",
    path: "/projects",
    headers: [merge],
    body: %{"id" => 1, "name" => nil},
    stateful: true
  },
  %{
    id: "upsert/merge-unknown-payload-key",
    method: "POST",
    path: "/projects",
    headers: [merge],
    body: %{"id" => 1, "nope" => 1},
    stateful: true
  }
]
