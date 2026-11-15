count = {"prefer", "count=exact"}

[
  %{id: "counting/exact-empty", path: "/items?id=eq.0", headers: [count]},
  %{id: "counting/exact-empty-table", path: "/compound_pk", headers: [count]},
  %{id: "counting/none-full-page", path: "/items?select=id&order=id"},
  %{id: "counting/none-empty", path: "/items?id=eq.0"},
  %{
    id: "counting/exact-partial-page",
    path: "/items?select=id&order=id&limit=2",
    headers: [count]
  },
  %{id: "counting/exact-full-page", path: "/items?select=id&order=id", headers: [count]},
  %{
    id: "counting/exact-offset-window",
    path: "/items?select=id&order=id&limit=2&offset=3",
    headers: [count]
  },
  %{
    id: "counting/head-exact",
    method: "HEAD",
    path: "/items?select=id&order=id",
    headers: [count]
  },
  %{
    id: "counting/head-exact-limit",
    method: "HEAD",
    path: "/items?select=id&order=id&limit=2&offset=3",
    headers: [count]
  },
  %{
    id: "counting/exact-inner-join",
    path: "/projects?select=name,clients!inner(name)&clients.name=eq.Microsoft",
    headers: [count]
  },
  %{
    id: "counting/exact-embed-not-null",
    path: "/projects?select=name,clients(name)&clients=not.is.null",
    headers: [count]
  },
  %{
    id: "counting/exact-with-range-header",
    path: "/items?select=id&order=id",
    headers: [{"range", "2-4"}, count]
  },
  %{
    id: "counting/exact-limits",
    path: "/items?select=id&order=id",
    headers: [count],
    server: :limits
  },
  %{
    id: "counting/preference-applied-combined",
    path: "/items?select=id&order=id&limit=1",
    headers: [{"prefer", "count=exact, handling=strict, return=minimal"}]
  },
  %{
    id: "counting/handling-lenient-echoed",
    path: "/items?select=id&order=id&limit=1",
    headers: [{"prefer", "handling=lenient"}]
  },
  %{
    id: "counting/tx-rollback-echoed",
    path: "/items?select=id&order=id&limit=1",
    headers: [{"prefer", "tx=rollback"}]
  },
  %{
    id: "counting/unknown-preference-ignored",
    path: "/items?select=id&limit=1",
    headers: [{"prefer", "foo=bar"}]
  },
  %{
    id: "counting/spread-inner-limit",
    path: "/projects?select=id,...tasks!inner(name)&order=id&limit=1",
    headers: [{"prefer", "count=exact"}]
  },
  %{
    id: "counting/spread-null-filter-limit",
    path: "/projects?select=id,...tasks(name)&tasks=not.is.null&order=id&limit=1",
    headers: [{"prefer", "count=exact"}]
  }
]
