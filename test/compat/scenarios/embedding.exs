# Resource embedding (PostgREST QuerySpec, EmbedDisambiguationSpec, EmbedInnerJoinSpec,
# RelatedQueriesSpec, SpreadQueriesSpec). Names are `embedding/<group>/<case>`.
encode = fn path ->
  for <<byte <- path>>, into: "" do
    if byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in ~c"-._~!$&'()*+,;=:@/?%",
      do: <<byte>>,
      else: "%" <> Base.encode16(<<byte>>)
  end
end

groups = [
  basics: [
    {"m2o-and-o2m", "/projects?id=eq.1&select=id,name,clients(*),tasks(id,name)&tasks.order=id"},
    {"renamed",
     "/projects?id=eq.1&select=myId:id,name,project_client:clients(*),project_tasks:tasks(id,name)&project_tasks.order=id"},
    {"renamed-nested-keys", "/projects?select=name,client:clients(clientId:id,name)&order=id"},
    {"missing-parent-null", "/projects?id=in.(1,5)&select=id,clients(id)&order=id"},
    {"no-children-empty", "/projects?id=in.(5)&select=id,tasks(id)"},
    {"two-levels",
     "/clients?id=eq.1&select=id,projects(id,tasks(id))&projects.order=id&projects.tasks.order=id"},
    {"three-levels",
     "/clients?select=id,projects(id,tasks(id,users(id)))&order=id&projects.order=id&projects.tasks.order=id&projects.tasks.users.order=id"},
    {"m2m", "/tasks?select=id,users(id)&order=id&users.order=id"},
    {"m2m-reverse", "/users?select=id,tasks(id)&order=id&tasks.order=id"},
    {"m2m-alias", "/tasks?select=id,theUsers:users(id)&order=id&theUsers.order=id"},
    {"m2m-then-m2o",
     "/users?id=eq.1&select=name,tasks(name,project:projects(name))&tasks.order=id"},
    {"composite-fk", "/comments?select=*,users_tasks(userId:user_id)&order=id"},
    {"composite-fk-m2m",
     "/files?filename=eq.autoexec.bat&project_id=eq.1&select=filename,users_tasks(user_id,task_id)"},
    {"composite-children", "/users_tasks?user_id=eq.2&task_id=eq.6&select=*,comments(content)"},
    {"star-embed", "/clients?select=*,projects(*)&order=id&projects.order=id"},
    {"limit-per-parent",
     "/clients?select=id,projects(id)&projects.limit=1&projects.order=id&order=id"},
    {"limit-offset-per-parent",
     "/clients?select=id,projects(id)&projects.limit=1&projects.offset=1&projects.order=id&order=id"},
    {"limit-zero-per-parent", "/clients?select=id,projects(id)&projects.limit=0&order=id"},
    {"limit-not-a-number",
     "/clients?select=id,projects(id)&projects.limit=abc&order=id&projects.order=id"},
    {"embedded-filter",
     "/clients?select=id,projects(id,name)&projects.name=like.Win*&order=id&projects.order=id"},
    {"embedded-filter-two-levels",
     "/clients?select=id,projects(id,tasks(id))&projects.tasks.id=lt.3&order=id&projects.order=id&projects.tasks.order=id"},
    {"embedded-filter-unknown-column", "/clients?select=id,projects(id)&projects.nope=eq.1"},
    {"embedded-filter-not-embedded", "/clients?select=id&nope.id=eq.1"},
    {"embedded-logic",
     "/clients?select=id,projects(id)&projects.or=(id.eq.1,id.eq.3)&order=id&projects.order=id"},
    {"embedded-not-logic",
     "/clients?select=id,projects(id)&projects.not.or=(id.eq.1,id.eq.3)&order=id&projects.order=id"},
    {"root-and-embedded-filter",
     "/clients?id=eq.1&select=id,projects(id,name)&projects.id=gt.1&projects.order=id"},
    {"same-table-twice",
     "/projects?id=eq.1&select=id,a:tasks(id),b:tasks(name)&a.order=id&b.order=id"}
  ],
  one_to_one: [
    {"fk-is-pk", "/students_info?select=address,students(name)&order=id"},
    {"fk-is-pk-reverse", "/students?select=name,students_info(address)&order=id"},
    {"unique-fk", "/country?select=name,capital(name)&order=id"},
    {"unique-fk-reverse", "/capital?select=name,country(name)&order=id"},
    {"by-column", "/capital?select=name,country_id(name)&order=id"},
    {"by-constraint", "/capital?select=name,capital_country_id_fkey(name)&order=id"},
    {"hint-column", "/country?select=name,capital!country_id(name)&order=id"},
    {"ambiguous", "/ambig_a?select=*,ambig_b(*)"}
  ],
  self: [
    {"parent", "/family_tree?id=in.(3,4)&select=id,parent(id,name,parent(*))&order=id"},
    {"children",
     "/family_tree?id=eq.1&select=id,name,children:family_tree!parent(id,name,children:family_tree!parent(id,name))&children.order=id&children.children.order=id"},
    {"parent-then-children",
     "/family_tree?id=eq.2&select=id,name,parent(id,name,children:family_tree!parent(id,name))"},
    {"parent-and-children-aliased",
     "/family_tree?id=eq.2&select=id,p:parent(id),c:family_tree!parent(id)&c.order=id"},
    {"same-table-twice-aliases",
     "/family_tree?id=eq.4&select=id,a:family_tree!parent(id),b:family_tree!parent(name)&a.order=id&b.order=id"},
    {"organizations-two-self-fks",
     "/organizations?select=id,name,referee(id,name),auditor(id,name)&id=eq.3"},
    {"organizations-children",
     "/organizations?id=eq.1&select=id,refereeds:organizations!referee(id,name),auditees:organizations!auditor(id,name)&refereeds.order=id&auditees.order=id"}
  ],
  disambiguation: [
    {"ambiguous-two-fks", "/orders?id=eq.1&select=id,addresses(address)"},
    {"by-constraint", "/orders?id=eq.1&select=id,name,billing(address),shipping(address)"},
    {"by-column",
     "/orders?id=eq.1&select=id,name,billing_address_id(id),shipping_address_id(id)"},
    {"fk-constraint-named-client",
     "/projects?id=in.(1,3)&select=id,name,client(id,name)&order=id"},
    {"fk-column", "/projects?id=in.(1,3)&select=id,name,client_id(id,name)&order=id"},
    {"hint-unknown", "/projects?select=id,clients!nope(id)"},
    {"junction-hint", "/ambig_a?select=id,ambig_b!ambig_ab(id)&order=id&ambig_b.order=id"},
    {"inner-with-hint", "/projects?select=id,clients!client!inner(id)&clients.id=eq.2&order=id"},
    {"no-relationship", "/clients?select=id,tasks(id)"}
  ],
  inner: [
    {"m2o-inner", "/projects?select=id,clients!inner(id)&order=id"},
    {"m2o-left", "/projects?select=id,clients!left(id)&order=id"},
    {"m2o-inner-filter-1", "/projects?select=id,clients!inner(id)&clients.id=eq.1&order=id"},
    {"m2o-inner-filter-2", "/projects?select=id,clients!inner(id)&clients.id=eq.2&order=id"},
    {"m2o-inner-filter-none", "/projects?select=id,clients!inner(id)&clients.id=eq.0&order=id"},
    {"o2m-inner",
     "/entities?select=id,child_entities!inner(id)&order=id&child_entities.order=id"},
    {"o2m-left", "/entities?select=id,child_entities!left(id)&order=id&child_entities.order=id"},
    {"o2m-inner-filter",
     "/entities?select=id,child_entities!inner(id)&child_entities.id=eq.1&order=id"},
    {"o2m-inner-filter-none",
     "/entities?select=id,child_entities!inner(id)&child_entities.id=eq.0&order=id"},
    {"m2m-inner", "/tasks?select=id,users!inner(id)&order=id&users.order=id"},
    {"m2m-inner-filter", "/users?select=id,tasks!inner(id)&tasks.id=eq.1&order=id"},
    {"two-levels-below",
     "/tasks?select=id,projects!inner(id,clients!inner(id))&projects.clients.id=eq.1&order=id"},
    {"o2m-two-levels",
     "/entities?select=id,child_entities!inner(id,grandchild_entities!inner(id))&child_entities.grandchild_entities.id=in.(1,5)&order=id&child_entities.order=id&child_entities.grandchild_entities.order=id"},
    {"only-direct-parent",
     "/tasks?select=id,projects(id,clients!inner(id))&projects.clients.id=eq.2&order=id"},
    {"nested-left-under-inner",
     "/entities?select=id,child_entities!inner(id,grandchild_entities(id))&child_entities.grandchild_entities.id=eq.2&order=id&child_entities.order=id"},
    {"multiple-inner",
     "/projects?select=name,clients!inner(name),tasks!inner(name)&order=id&tasks.order=id"},
    {"inner-with-count", "/projects?select=id,clients!inner(id)&order=id&limit=2"},
    {"inner-order-embedded-column",
     "/projects?select=id,clients!inner(id,name)&order=clients(name).desc,id"}
  ],
  null_filters: [
    {"m2o-not-null", "/projects?select=name,clients()&clients=not.is.null&order=id"},
    {"m2o-is-null", "/projects?select=name,clients()&clients=is.null"},
    {"m2o-not-null-with-columns",
     "/projects?select=name,clients(name)&clients=not.is.null&order=id"},
    {"o2m-not-null",
     "/entities?select=name,child_entities()&child_entities=not.is.null&order=id"},
    {"o2m-is-null", "/entities?select=name,child_entities()&child_entities=is.null&order=id"},
    {"m2m-not-null", "/users?select=name,tasks()&tasks.id=eq.1&tasks=not.is.null&order=id"},
    {"m2m-is-null", "/users?select=name,tasks()&tasks.id=eq.1&tasks=is.null&order=id"},
    {"nested",
     "/entities?select=name,child_entities(name,grandchild_entities())&child_entities.grandchild_entities=not.is.null&child_entities=not.is.null&order=id&child_entities.order=id"},
    {"or-across-embeds",
     "/entities?select=name,child_entities(),grandchild_entities:child_entities(grandchild_entities())&or=(child_entities.not.is.null,name.eq.entity 3)&order=id"},
    {"is-not-null-keyword", "/projects?select=name,clients()&clients=is.not_null&order=id"},
    {"with-count", "/projects?select=name,clients()&clients=not.is.null&order=id&limit=1"}
  ],
  empty: [
    {"m2o", "/projects?select=id,name,clients()&order=id"},
    {"inner-filter", "/projects?select=id,name,clients!inner()&clients.id=eq.2&order=id"},
    {"o2m-inner", "/clients?select=id,name,projects!inner()&projects.name=eq.IOS&order=id"},
    {"m2m-inner", "/users?select=*,tasks!inner()&tasks.id=eq.3&order=id"},
    {"nested-inner",
     "/users?select=*,users_tasks!inner(tasks!inner(projects()))&users_tasks.tasks.id=eq.3&order=id"},
    {"root-only-embeds", "/projects?select=clients()&order=id&limit=2"}
  ],
  spread: [
    {"to-one", "/projects?select=id,...clients(client_name:name)&order=id"},
    {"to-one-star", "/projects?select=id,...clients(*)&order=id"},
    {"nested",
     "/grandchild_entities?select=name,...child_entities(parent_name:name,...entities(grandparent_name:name))&order=id&limit=3"},
    {"o2o", "/country?select=name,...capital(capital:name)&order=id"},
    {"inside-embed",
     "/grandchild_entities?select=name,child_entity:child_entities(name,...entities(parent_name:name))&order=id&limit=1"},
    {"m2m-junction-columns-kept",
     "/users?select=*,tasks:users_tasks(*,...tasks(*))&order=id&limit=1&tasks.order=task_id"},
    {"m2m-junction-columns-dropped",
     "/users?select=*,tasks:users_tasks(...tasks(*))&order=id&limit=1&tasks.order=task_id"},
    {"to-many", "/clients?select=name,...projects(name)&order=id"},
    {"to-many-two-columns",
     "/clients?select=name,...projects(id,name)&order=id&projects.order=id"},
    {"to-many-ordered", "/clients?select=name,...projects(id)&order=id&projects.order=id.desc"},
    {"to-many-order-by-unselected",
     "/clients?select=name,...projects(name)&order=id&projects.order=id.desc"},
    {"to-many-inner", "/clients?select=name,...projects!inner(name)&order=id&projects.order=id"},
    {"to-many-null-filter",
     "/clients?select=name,...projects(projects:name)&projects=is.null&order=id"},
    {"to-many-filtered",
     "/clients?select=name,...projects(name)&projects.name=like.Win*&order=id"},
    {"to-many-m2m", "/users?select=name,...tasks(name)&order=id&tasks.order=id"},
    {"empty-spread", "/projects?select=id,...clients()&order=id&limit=2"}
  ],
  counts: [
    {"inner-join-page-total", "/projects?select=id,clients!inner(id)&order=id",
     [{"prefer", "count=exact"}]},
    {"embedded-limit", "/clients?select=id,projects(id)&projects.limit=1&order=id",
     [{"prefer", "count=exact"}]},
    {"root-limit", "/clients?select=id,projects(id)&order=id&limit=1&projects.order=id",
     [{"prefer", "count=exact"}]},
    {"null-filter", "/projects?select=name,clients()&clients=not.is.null&order=id&limit=2",
     [{"prefer", "count=exact"}]},
    {"o2m-inner-filter", "/entities?select=id,child_entities!inner(id)&child_entities.id=eq.1",
     [{"prefer", "count=exact"}]}
  ]
]

limits = [
  {"to-many-embed", "/clients?select=*,projects(*)&order=id&projects.order=id"},
  {"embedded-limit-above-max",
   "/clients?select=*,projects(*)&projects.limit=5&order=id&projects.order=id"},
  {"m2m", "/users?select=*,tasks(*)&order=id&tasks.order=id"},
  {"to-one-embed", "/projects?select=id,clients(*)&order=id"},
  {"root", "/items?order=id"}
]

limit_scenarios =
  for {name, path} <- limits,
      do: %{id: "embedding/limits/#{name}", path: encode.(path), server: :limits}

scenarios =
  for {group, cases} <- groups, case_ <- cases do
    {name, path, headers} =
      case case_ do
        {name, path} -> {name, path, []}
        {name, path, headers} -> {name, path, headers}
      end

    %{id: "embedding/#{group}/#{name}", path: encode.(path), headers: headers}
  end

scenarios ++ limit_scenarios
