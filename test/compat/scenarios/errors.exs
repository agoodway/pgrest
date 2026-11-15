rb = {"prefer", "tx=rollback"}

[
  # --- routing ---------------------------------------------------------------------
  %{id: "errors/unknown-table", path: "/faketable"},
  %{id: "errors/unknown-table-hint", path: "/projectx"},
  %{id: "errors/unknown-table-no-hint", path: "/projxxxx"},
  %{id: "errors/invalid-path", path: "/first/second/third"},
  # --- SQLSTATE mapping ------------------------------------------------------------
  %{id: "errors/unknown-column-filter", path: "/items?nope=eq.1"},
  %{id: "errors/unknown-column-select", path: "/items?select=nope"},
  %{id: "errors/unknown-column-order", path: "/items?order=nope"},
  %{id: "errors/invalid-input-syntax", path: "/items?id=eq.abc"},
  %{
    id: "errors/unique-violation",
    method: "POST",
    path: "/clients",
    headers: [rb],
    body: %{"id" => 1, "name" => "dup"},
    stateful: true
  },
  %{
    id: "errors/foreign-key-violation",
    method: "POST",
    path: "/projects",
    headers: [rb],
    body: %{"id" => 100, "name" => "x", "client_id" => 999},
    stateful: true
  },
  %{
    id: "errors/not-null-violation",
    method: "POST",
    path: "/clients",
    headers: [rb],
    body: %{"id" => 100},
    stateful: true
  },
  %{
    id: "errors/invalid-integer-body",
    method: "POST",
    path: "/items",
    headers: [rb],
    body: %{"id" => "abc"},
    stateful: true
  },
  # --- parse before privilege ------------------------------------------------------
  # `anon` cannot read `private_docs`: a malformed select, filter or order is still a PGRST100,
  # not a 401.
  %{
    id: "errors/denied-table-malformed-filter",
    fixture: :supabase,
    path: "/private_docs?id=foo.1"
  },
  %{
    id: "errors/denied-table-malformed-order",
    fixture: :supabase,
    path: "/private_docs?order=id.nope"
  },
  %{
    id: "errors/denied-table-malformed-select",
    fixture: :supabase,
    path: "/private_docs?select=id,,"
  },
  %{
    id: "errors/denied-table-select-open-paren",
    fixture: :supabase,
    path: "/private_docs?select=id("
  },
  %{
    id: "errors/denied-table-order-bogus",
    fixture: :supabase,
    path: "/private_docs?order=id.bogus"
  },
  %{id: "errors/denied-table-valid-filter", fixture: :supabase, path: "/private_docs?id=eq.1"}
]
