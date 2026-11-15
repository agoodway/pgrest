[
  # Ambiguous: two foreign keys from orders to addresses (PGRST201).
  %{id: "embed_errors/ambiguous-two-fks", path: "/orders?select=id,addresses(id)"},
  %{
    id: "embed_errors/ambiguous-self-two-fks",
    path: "/organizations?select=id,organizations(id)"
  },
  # A hint that names one column resolves it.
  %{
    id: "embed_errors/hint-column-resolves",
    path: "/orders?select=id,addresses!billing_address_id(id)&order=id"
  },
  %{
    id: "embed_errors/hint-constraint-resolves",
    path: "/orders?select=id,addresses!shipping(id)&order=id"
  },
  # Self relationship: the hint names the foreign column.
  %{
    id: "embed_errors/self-hint-parent",
    path: "/family_tree?select=id,kids:family_tree!parent(id)&order=id"
  },
  # Nothing matches (PGRST200), with and without fuzzy suggestions.
  %{id: "embed_errors/no-relationship", path: "/clients?select=id,nope(id)"},
  %{id: "embed_errors/no-relationship-typo-child", path: "/clients?select=id,project(id)"},
  %{id: "embed_errors/no-relationship-typo-both", path: "/client?select=id,project(id)"},
  %{
    id: "embed_errors/no-relationship-unknown-hint",
    path: "/projects?select=id,clients!nope(id)"
  },
  %{id: "embed_errors/no-relationship-unrelated-table", path: "/clients?select=id,tasks(id)"},
  %{id: "embed_errors/no-relationship-leaf-table", path: "/items?select=id,nope(id)"},
  # Direct and junction paths to the same table (PGRST201), and the hints that resolve it.
  %{id: "embed_errors/ambiguous-direct-and-junction", path: "/ambig_a?select=id,ambig_b(id)"},
  %{
    id: "embed_errors/hint-junction-resolves",
    path: "/ambig_a?select=id,ambig_b!ambig_ab(id)&order=id&ambig_b.order=id"
  },
  %{
    id: "embed_errors/hint-direct-constraint-resolves",
    path: "/ambig_a?select=id,ambig_b!ambig_b_a_id_fkey(id)&order=id&ambig_b.order=id"
  },
  # Valid embeds the graph must serve: many-to-many, one-to-one, composite keys.
  %{
    id: "embed_errors/m2m-users-tasks",
    path: "/users?select=id,tasks(id)&order=id&tasks.order=id"
  },
  %{
    id: "embed_errors/o2o-students-info",
    path: "/students?select=id,students_info(address)&order=id"
  },
  %{
    id: "embed_errors/o2o-capital-country",
    path: "/country?select=id,capital(name)&order=id"
  },
  %{
    id: "embed_errors/composite-o2m-files-touched",
    path: "/files?select=filename,touched_files(user_id,task_id)&order=project_id,filename"
  },
  %{
    id: "embed_errors/composite-m2o-comments-users-tasks",
    path: "/comments?select=id,users_tasks(user_id,task_id)"
  },
  %{
    id: "embed_errors/composite-partial-match-not-joined",
    path:
      "/users_tasks?user_id=eq.3&task_id=eq.1&select=user_id,touched_files(filename,project_id)&order=user_id"
  },
  %{
    id: "embed_errors/m2m-composite-explicit",
    path:
      "/users_tasks?user_id=eq.1&task_id=eq.1&select=user_id,files!touched_files(filename)&files.order=filename"
  }
]
