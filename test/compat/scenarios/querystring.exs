[
  %{id: "querystring/plus-is-space", path: "/compound_pk?k2=eq.a+b"},
  %{id: "querystring/unicode", path: "/compound_pk?k2=eq.%C3%A9t%C3%A9"},
  %{id: "querystring/semicolon-separator", path: "/items?id=eq.1;limit=0"},
  # `?id` (no `=`) is ignored; `?id=` is a filter with an empty value.
  %{id: "querystring/key-without-equals", path: "/items?id&order=id"},
  %{id: "querystring/empty-value", path: "/items?id="},
  # PostgREST decodes malformed percent-encoding leniently (the literal "%zz" then
  # fails as a bigint with 22P02). PgRest rejects it up front with a 400.
  %{
    id: "querystring/bad-percent-encoding",
    path: "/items?id=eq.%zz",
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST100",
        "message" => "Malformed percent-encoding in the query string",
        "details" => "Invalid percent-encoding near \"%zz\".",
        "hint" => nil
      }
    }
  },
  %{
    id: "querystring/trailing-percent",
    path: "/items?id=eq.%",
    only: :pgrest,
    expect: %{
      status: 400,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST100",
        "message" => "Malformed percent-encoding in the query string",
        "details" => "Invalid percent-encoding near \"%\".",
        "hint" => nil
      }
    }
  }
]
