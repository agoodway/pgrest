[
  %{id: "order_syntax/desc-nullslast", path: "/items?order=id.desc.nullslast"},
  %{id: "order_syntax/nullsfirst-only", path: "/items?order=id.nullsfirst"},
  %{id: "order_syntax/multiple", path: "/projects?order=client_id.desc,id.asc"},
  %{id: "order_syntax/spaces", path: "/items?order=%20id%20.desc"},
  %{
    id: "order_syntax/relation-term",
    path: "/projects?select=id,clients(id)&order=clients(name).desc.nullsfirst,id"
  },
  %{
    id: "order_syntax/relation-term-selected",
    path: "/projects?select=id,clients(name)&order=clients(name).desc.nullsfirst,id"
  },
  %{id: "order_syntax/relation-two-fields", path: "/projects?order=clients(name,id)"},
  %{id: "order_syntax/bad-direction", path: "/items?order=id.ac"},
  %{id: "order_syntax/direction-typo", path: "/items?order=id.descc"},
  %{id: "order_syntax/nulls-typo", path: "/items?order=id.nulsfist"},
  %{id: "order_syntax/nulls-trailing", path: "/items?order=id.nullslasttt"},
  %{id: "order_syntax/double-direction", path: "/items?order=id.asc.desc"},
  %{id: "order_syntax/empty-term", path: "/items?order=id,,id"},
  %{id: "order_syntax/trailing-comma", path: "/items?order=id,"}
]
