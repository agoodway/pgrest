# Adapted from v14.18 RpcSpec, UpsertSpec, UnicodeSpec and QuerySpec.
[
  %{id: "sweep/bad-negative-json-path", path: "/complex_items?select=arr_data-%3E%3E--34"},
  %{id: "sweep/foreign-filter", path: "/sweep_foreign_items?id=eq.1"},
  %{
    id: "sweep/foreign-select-order-limit",
    path: "/sweep_foreign_items?select=id&order=id.desc&limit=2"
  },
  %{
    id: "sweep/nullable-key-location",
    method: "POST",
    path: "/test_null_pk_competitors_sponsors",
    stateful: true,
    headers: [{"prefer", "return=headers-only, tx=rollback"}],
    body: %{"id" => 1}
  },
  %{
    id: "sweep/content-location-sorted",
    path: "/projects?order=id&select=id&name=like.*&id=gt.1"
  },
  %{id: "sweep/uppercase-rpc-get", path: "/rpc/UpperEcho?Input=hello"},
  %{
    id: "sweep/uppercase-rpc-post",
    method: "POST",
    path: "/rpc/UpperEcho",
    body: %{"Input" => "hello"}
  },
  %{
    id: "sweep/typed-get",
    path: "/rpc/typed_echo?flag=true&amount=1.25&day=2026-01-02&ids=%7B1,2%7D&doc=%7B%22a%22:1%7D"
  },
  %{
    id: "sweep/typed-null-get",
    path: "/rpc/typed_echo?flag=false&amount=-2&day=2024-02-29&ids=%7B%7D&doc=null"
  },
  %{
    id: "sweep/typed-invalid-get",
    path: "/rpc/typed_echo?flag=oops&amount=1&day=2026-01-02&ids=%7B1%7D&doc=null"
  },
  %{id: "sweep/unicode-read", path: "/%D9%85%D9%88%D8%A7%D8%B1%D8%AF"},
  %{
    id: "sweep/unicode-insert",
    method: "POST",
    path: "/%D9%85%D9%88%D8%A7%D8%B1%D8%AF",
    stateful: true,
    headers: [{"prefer", "tx=rollback, return=representation"}],
    body: %{"هویت" => 1}
  },
  %{
    id: "sweep/unicode-delete",
    method: "DELETE",
    path: "/%D9%85%D9%88%D8%A7%D8%B1%D8%AF?%D9%87%D9%88%DB%8C%D8%AA=eq.1",
    stateful: true,
    headers: [{"prefer", "tx=rollback"}]
  },
  %{
    id: "sweep/upsert-embed",
    method: "POST",
    path: "/projects?select=id,name,clients(id,name)",
    stateful: true,
    headers: [{"prefer", "resolution=merge-duplicates, return=representation, tx=rollback"}],
    body: %{"id" => 1, "name" => "updated", "client_id" => 1}
  },
  %{
    id: "sweep/partially-unnamed-post",
    method: "POST",
    path: "/rpc/partially_unnamed",
    body: %{"" => 1, "label" => "a"},
    only: :pgrest,
    expect: %{
      status: 404,
      headers: %{"content-type" => "application/json; charset=utf-8"},
      body: %{
        "code" => "PGRST202",
        "message" =>
          "Could not find the function test.partially_unnamed(, label) in the schema cache",
        "details" =>
          "Searched for the function test.partially_unnamed with parameters , label or with a single unnamed json/jsonb parameter, but no matches were found in the schema cache.",
        "hint" => nil
      }
    }
  }
] ++
  for resolution <- ~w(merge ignore), id <- [1, 91] do
    %{
      id: "sweep/camel-#{resolution}-#{id}",
      method: "POST",
      path: "/UnitTest?select=idUnitTest,nameUnitTest",
      stateful: true,
      headers: [
        {"prefer", "resolution=#{resolution}-duplicates, return=representation, tx=rollback"}
      ],
      body: %{"idUnitTest" => id, "nameUnitTest" => "updated"}
    }
  end
