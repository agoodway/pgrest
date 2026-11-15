# Ordering (PostgREST QuerySpec, RelatedQueriesSpec). Names are `ordering/<case>`.
encode = fn path ->
  for <<byte <- path>>, into: "" do
    if byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in ~c"-._~!$&'()*+,;=:@/?%",
      do: <<byte>>,
      else: "%" <> Base.encode16(<<byte>>)
  end
end

cases = [
  {"asc", "/items?id=lte.2&order=id.asc"},
  {"desc", "/items?id=lte.2&order=id.desc"},
  {"default-direction", "/items?id=lte.2&order=id"},
  {"nulls-first", "/no_pk?order=a.nullsfirst"},
  {"asc-nulls-last", "/no_pk?order=a.asc.nullslast"},
  {"desc-nulls-first", "/no_pk?order=a.desc.nullsfirst"},
  {"desc-nulls-last", "/no_pk?order=a.desc.nullslast"},
  {"multi-column", "/projects?select=client_id,id,name&order=client_id.desc.nullslast,id.desc"},
  {"unknown-column", "/projects?order=nope"},
  {"json-key", "/complex_items?select=id&order=settings->>id.asc,id"},
  {"embedded-order", "/projects?id=eq.1&select=id,name,tasks(id,name)&tasks.order=name.asc"},
  {"embedded-order-alias",
   "/projects?id=eq.1&select=id,name,the_tasks:tasks(id,name)&the_tasks.order=name.asc"},
  {"embedded-order-two-levels",
   "/users?id=eq.1&select=name,tasks(id,name,projects(id))&tasks.order=name.asc&tasks.projects.order=id.desc"},
  {"embedded-order-desc", "/clients?id=eq.1&select=id,projects(id)&projects.order=id.desc"},
  {"embedded-order-unknown-column", "/clients?select=id,projects(id)&projects.order=nope"},
  {"related-order", "/projects?select=id,clients(name)&order=clients(name).nullsfirst,id"},
  {"related-order-alias", "/projects?select=id,client:clients(name)&order=client(name).asc,id"},
  {"related-order-desc",
   "/projects?select=id,clients(name)&order=clients(name).desc.nullslast,id"},
  {"related-order-to-many", "/clients?select=id,projects(id)&order=projects(id)"},
  {"related-order-to-many-alias", "/clients?select=id,pros:projects(id)&order=pros(id)"},
  {"related-order-not-embedded", "/projects?select=id,clients(id)&order=clientsx(id)"},
  {"related-order-column-not-selected", "/projects?select=id,clients(id)&order=clients(name)"},
  {"related-order-inside-embed",
   "/users?select=name,tasks(id,name,projects(id,name))&tasks.order=projects(id).desc&order=name&limit=1"},
  {"order-by-embed-not-allowed-dot", "/clients?select=id,projects(id)&order=projects.id"}
]

for {id, path} <- cases, do: %{id: "ordering/" <> id, path: encode.(path)}
