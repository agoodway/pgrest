# 17 nested levels: `or=(and(and(...(id.eq.1)...)))`. PostgREST would hand this to
# Postgres; PgRest caps logic-tree depth at 16 and rejects it at parse.
too_deep = Enum.reduce(1..16, "(id.eq.1)", fn _level, inner -> "(and" <> inner <> ")" end)

[
  %{id: "filter_syntax/operator-missing-value", path: "/items?id=eq"},
  %{id: "filter_syntax/unclosed-or", path: "/items?or=(id.eq.1"},
  %{id: "filter_syntax/unknown-operator", path: "/items?id=foo.1"},
  %{id: "filter_syntax/is-value-nox", path: "/no_pk?a=is.nox"},
  %{id: "filter_syntax/is-value-not-nul", path: "/no_pk?a=is.not_nul"},
  %{id: "filter_syntax/is-value-upper-partial", path: "/no_pk?a=is.NOT_NU"},
  %{
    id: "filter_syntax/logic-depth-exceeds-16",
    path: "/items?or=" <> too_deep,
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST100",
        "message" => "logic tree depth exceeds 16",
        "details" => nil,
        "hint" => nil
      }
    }
  }
]
