count = {"prefer", "count=exact"}

[
  %{id: "pagination/limit", path: "/items?select=id&order=id.asc&limit=3"},
  %{id: "pagination/limit-offset", path: "/items?select=id&order=id.asc&limit=3&offset=2"},
  %{
    id: "pagination/head-limit-offset",
    method: "HEAD",
    path: "/items?select=id&order=id.asc&limit=3&offset=2"
  },
  %{
    id: "pagination/range-beats-limit",
    path: "/items?select=id&order=id.asc&limit=3",
    headers: [{"range", "0-1"}]
  },
  %{
    id: "pagination/range-first-two",
    path: "/items?select=id&order=id",
    headers: [{"range", "0-1"}]
  },
  %{
    id: "pagination/range-open-ended",
    path: "/items?select=id&order=id",
    headers: [{"range", "0-"}]
  },
  %{
    id: "pagination/range-single",
    path: "/items?select=id&order=id",
    headers: [{"range", "0-0"}]
  },
  %{
    id: "pagination/range-beyond-end",
    path: "/items?select=id&order=id",
    headers: [{"range", "10-100"}]
  },
  %{id: "pagination/range-empty-table", path: "/compound_pk", headers: [{"range", "0-1"}]},
  %{id: "pagination/offset-zero-empty", path: "/compound_pk?offset=0"},
  %{id: "pagination/offset-zero-empty-count", path: "/compound_pk?offset=0", headers: [count]},
  %{id: "pagination/offset-negative", path: "/items?select=id&order=id&offset=-4"},
  %{id: "pagination/limit-zero", path: "/items?select=id&order=id&limit=0"},
  %{id: "pagination/limit-negative", path: "/items?select=id&order=id&limit=-1"},
  %{
    id: "pagination/range-lower-gt-upper",
    path: "/items?select=id&order=id",
    headers: [{"range", "1-0"}]
  },
  %{
    id: "pagination/offset-past-end-count",
    path: "/items?select=id&order=id&offset=100",
    headers: [count]
  },
  %{
    id: "pagination/range-past-end-count",
    path: "/items?select=id&order=id",
    headers: [{"range", "100-199"}, count]
  },
  %{id: "pagination/offset-empty-table-count", path: "/compound_pk?offset=1", headers: [count]},
  %{id: "pagination/offset-past-end-no-count", path: "/items?select=id&order=id&offset=100"},
  %{
    id: "pagination/offset-equals-total-count",
    path: "/items?select=id&order=id&offset=15",
    headers: [count]
  },
  %{
    id: "pagination/embedded-limits",
    path:
      "/clients?select=id,projects(id,tasks(id))&order=id.asc&limit=1&projects.order=id.asc&projects.limit=2&projects.tasks.order=id.asc&projects.tasks.limit=1"
  }
]
