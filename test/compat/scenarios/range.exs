[
  %{id: "range/header-only", path: "/items?order=id", headers: [{"range", "0-4"}]},
  %{id: "range/header-open-ended", path: "/items?order=id", headers: [{"range", "10-"}]},
  %{id: "range/header-unparseable", path: "/items?order=id", headers: [{"range", "abc"}]},
  %{id: "range/header-lower-gt-upper", path: "/items?order=id", headers: [{"range", "9-0"}]},
  %{id: "range/limit-offset", path: "/items?order=id&limit=3&offset=2"},
  %{id: "range/offset-only", path: "/items?order=id&offset=12"},
  %{id: "range/offset-past-end", path: "/items?order=id&offset=100"},
  %{id: "range/offset-negative", path: "/items?order=id&offset=-1"},
  %{id: "range/limit-zero", path: "/items?order=id&limit=0"},
  %{id: "range/limit-zero-offset", path: "/items?order=id&limit=0&offset=3"},
  %{id: "range/limit-negative", path: "/items?order=id&limit=-1"},
  %{id: "range/limit-nan-offset-zero", path: "/items?order=id&limit=abc&offset=0"},
  %{id: "range/limit-nan-offset-five", path: "/items?order=id&limit=abc&offset=5"},
  %{id: "range/limit-not-a-number", path: "/items?order=id&limit=abc"},
  %{
    id: "range/overlap",
    path: "/items?order=id&limit=5&offset=2",
    headers: [{"range", "0-4"}]
  },
  %{
    id: "range/overlap-header-wider",
    path: "/items?order=id&limit=2&offset=1",
    headers: [{"range", "0-9"}]
  },
  %{
    id: "range/disjoint",
    path: "/items?order=id&limit=3&offset=10",
    headers: [{"range", "0-2"}]
  },
  %{
    id: "range/limit-zero-with-header",
    path: "/items?order=id&limit=0",
    headers: [{"range", "0-4"}]
  },
  %{
    id: "range/head-with-range",
    method: "HEAD",
    path: "/items?order=id",
    headers: [{"range", "0-4"}]
  },
  %{
    id: "range/post-with-range",
    method: "POST",
    path: "/items",
    headers: [{"range", "0-0"}, {"prefer", "tx=rollback"}, {"content-type", "application/json"}],
    body: %{},
    stateful: true
  },
  %{
    id: "range/put-with-limit",
    method: "PUT",
    path: "/items?id=eq.1&limit=1",
    headers: [{"prefer", "tx=rollback"}, {"content-type", "application/json"}],
    body: %{"id" => 1},
    stateful: true
  },
  %{
    id: "range/post-scalar-body",
    method: "POST",
    path: "/items",
    headers: [{"prefer", "tx=rollback"}, {"content-type", "application/json"}],
    body: 5,
    stateful: true
  }
]
