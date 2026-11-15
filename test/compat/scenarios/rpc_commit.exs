[
  %{
    id: "rpc_commit/singular-delete-rolls-back",
    method: "POST",
    path: "/rpc/delete_items_returns_setof",
    stateful: true,
    headers: [{"prefer", "tx=commit"}, {"accept", "application/vnd.pgrst.object+json"}]
  },
  %{
    id: "rpc_commit/singular-before-max-affected",
    method: "POST",
    path: "/rpc/delete_items_returns_setof",
    stateful: true,
    headers: [
      {"prefer", "tx=commit, handling=strict, max-affected=1"},
      {"accept", "application/vnd.pgrst.object+json"}
    ]
  }
]
