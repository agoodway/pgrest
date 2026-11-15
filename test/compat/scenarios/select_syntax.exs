# Where PostgREST silently ignores unparsed trailing text (`id::int) FROM x`, `id)`, a
# leading comma) PgRest answers 400, so request text can never smuggle SQL past the
# grammar. These scenarios are PgRest-only.
strict = fn id, query, message, details ->
  %{
    id: id,
    path: "/items?select=" <> query,
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{"code" => "PGRST100", "message" => message, "details" => details, "hint" => nil}
    }
  }
end

trailing = ~S|unexpected ")" expecting "," or end of input|

[
  strict.(
    "select_syntax/cast-close-paren",
    "id::int%29",
    ~S|"failed to parse select parameter (id::int))" (line 1, column 8)|,
    trailing
  ),
  strict.(
    "select_syntax/cast-injection",
    "id::int%29%20FROM%20items%20UNION%20SELECT%201--",
    ~S|"failed to parse select parameter (id::int) FROM items UNION SELECT 1--)" (line 1, column 8)|,
    trailing
  ),
  strict.(
    "select_syntax/extra-close",
    "id%29",
    ~S|"failed to parse select parameter (id))" (line 1, column 3)|,
    trailing
  ),
  strict.(
    "select_syntax/leading-comma",
    ",id",
    ~S|"failed to parse select parameter (,id)" (line 1, column 1)|,
    ~S|unexpected "," expecting "...", field name (* or [a..z0..9_$]), "*" or "count()"|
  ),
  %{id: "select_syntax/alias", path: "/items?select=ident:id&order=id"},
  %{id: "select_syntax/cast-text", path: "/items?select=id::text&order=id"},
  %{id: "select_syntax/cast-spaced-name", path: "/items?select=id::double%20precision&order=id"},
  %{id: "select_syntax/cast-semicolon", path: "/items?select=id::text%3B"},
  %{id: "select_syntax/cast-quoted", path: "/items?select=id::%22int%22"},
  %{id: "select_syntax/cast-dash-dash", path: "/items?select=id::int--"},
  %{id: "select_syntax/cast-dotted", path: "/items?select=id::a.b"},
  %{id: "select_syntax/cast-comma-splits", path: "/items?select=id::text,id&order=id"},
  %{id: "select_syntax/trailing-comma", path: "/items?select=id,"},
  %{id: "select_syntax/spaces", path: "/items?select=%20id%20,%20ident:id%20&order=id"},
  %{id: "select_syntax/unclosed-embed", path: "/projects?select=id,clients(id"},
  %{id: "select_syntax/embed-alias", path: "/projects?select=id,c:clients(id)&order=id"},
  %{id: "select_syntax/embed-inner", path: "/projects?select=id,clients!inner(id)&order=id"},
  %{id: "select_syntax/embed-left", path: "/projects?select=id,clients!left(id)&order=id"},
  %{id: "select_syntax/embed-hint", path: "/projects?select=id,clients!client(id)&order=id"},
  %{id: "select_syntax/embed-spread", path: "/projects?select=id,...clients(name)&order=id"},
  %{id: "select_syntax/embed-empty", path: "/projects?select=id,clients()&order=id"},
  %{id: "select_syntax/embed-spread-alias", path: "/projects?select=id,a:...clients(name)"},
  %{id: "select_syntax/aggregate-count", path: "/items?select=count()", server: :limits},
  %{id: "select_syntax/aggregate-sum", path: "/items?select=id.sum()", server: :limits},
  %{id: "select_syntax/aggregate-avg-cast", path: "/items?select=id.avg()::int", server: :limits},
  %{id: "select_syntax/aggregate-unknown-fun", path: "/items?select=id.median()"}
]
