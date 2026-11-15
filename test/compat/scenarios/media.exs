[
  %{id: "media/default-json", path: "/items?select=id&order=id&limit=1"},
  %{
    id: "media/accept-any",
    path: "/items?select=id&order=id&limit=1",
    headers: [{"accept", "*/*"}]
  },
  %{
    id: "media/accept-application-json",
    path: "/items?select=id&order=id&limit=1",
    headers: [{"accept", "application/json"}]
  },
  %{
    id: "media/accept-unknown-then-any",
    path: "/items?select=id&order=id&limit=1",
    headers: [{"accept", "text/unknowntype, */*"}]
  },
  %{
    id: "media/accept-q-values",
    path: "/items?select=id&order=id&limit=1",
    headers: [{"accept", "application/vnd.pgrst.object+json;q=0.5, application/json"}]
  },
  %{
    id: "media/accept-q-values-object-first",
    path: "/items?select=id&id=eq.5",
    headers: [{"accept", "application/json;q=0.5, application/vnd.pgrst.object+json"}]
  },
  %{
    id: "media/accept-application-wildcard",
    path: "/items?select=id&limit=1",
    headers: [{"accept", "application/*"}]
  },
  %{
    id: "media/accept-unknown-q-sorted",
    path: "/items?select=id&limit=1",
    headers: [{"accept", "text/foo; q=0.5, text/bar"}]
  },
  %{
    id: "media/accept-unknown-single-q",
    path: "/items?select=id&limit=1",
    headers: [{"accept", "text/foo;q=0.5"}]
  },
  %{
    id: "media/accept-unknown",
    path: "/items?select=id&limit=1",
    headers: [{"accept", "text/unknowntype"}]
  },
  %{
    id: "media/accept-two-unknown",
    path: "/items?select=id&limit=1",
    headers: [{"accept", "text/unknowntype, text/other"}]
  },
  %{
    id: "media/singular-one-row",
    path: "/items?select=id&id=eq.5",
    headers: [{"accept", "application/vnd.pgrst.object+json"}]
  },
  %{
    id: "media/singular-zero-rows",
    path: "/items?select=id&id=eq.0",
    headers: [{"accept", "application/vnd.pgrst.object+json"}]
  },
  %{
    id: "media/singular-many-rows",
    path: "/items?select=id&order=id",
    headers: [{"accept", "application/vnd.pgrst.object+json"}]
  },
  %{
    id: "media/singular-with-count",
    path: "/items?select=id&id=eq.5",
    headers: [{"accept", "application/vnd.pgrst.object+json"}, {"prefer", "count=exact"}]
  },
  %{
    id: "media/singular-embed",
    path: "/clients?select=id,projects(id)&id=eq.1&projects.order=id",
    headers: [{"accept", "application/vnd.pgrst.object+json"}]
  },
  %{
    id: "media/singular-limit-one",
    path: "/items?select=id&order=id&limit=1",
    headers: [{"accept", "application/vnd.pgrst.object+json"}]
  },
  %{
    id: "media/head-singular",
    method: "HEAD",
    path: "/items?select=id&id=eq.5",
    headers: [{"accept", "application/vnd.pgrst.object+json"}]
  },
  %{id: "media/content-location-sorted", path: "/no_pk?b=eq.1&a=eq.1"},
  %{id: "media/content-location-no-query", path: "/no_pk"},
  %{id: "media/unknown-table", path: "/nonexistent"},
  %{id: "media/unknown-table-typo", path: "/client"},
  %{id: "media/invalid-path", path: "/items/1"},
  %{
    id: "media/accept-case-and-params",
    path: "/items?select=id&limit=1",
    headers: [{"accept", "Application/JSON; charset=utf-8"}]
  }
]
