# Vertical filtering (PostgREST QuerySpec, JsonOperatorSpec): aliases, casts, JSON paths,
# empty and starred selects. Names are `select/<case>`.
encode = fn path ->
  for <<byte <- path>>, into: "" do
    if byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in ~c"-._~!$&'()*+,;=:@/?%",
      do: <<byte>>,
      else: "%" <> Base.encode16(<<byte>>)
  end
end

cases = [
  {"alias", "/complex_items?id=eq.1&select=myId:id"},
  {"cast", "/complex_items?select=id::text&order=id"},
  {"alias-and-cast", "/complex_items?id=eq.1&select=myId:id::text"},
  {"dash-in-column", "/complex_items?id=eq.3&select=id,field-with_sep"},
  {"unknown-cast-type", "/complex_items?select=id::fakecolumntype"},
  {"empty-select", "/projects?select=&order=id"},
  {"no-select", "/complex_items?id=eq.3"},
  {"star", "/projects?select=*&order=id"},
  {"unknown-column", "/projects?select=id,banana"},
  {"unknown-column-hint", "/projects?select=nam"},
  {"json-double-arrow-cast-json", "/complex_items?id=eq.1&select=settings->>foo::json"},
  {"json-nested", "/complex_items?id=eq.1&select=settings->foo->>bar"},
  {"json-nested-alias", "/complex_items?id=eq.1&select=myBar:settings->foo->>bar"},
  {"json-int-cast", "/complex_items?id=eq.1&select=settings->foo->>int::integer"},
  {"json-bad-cast", "/complex_items?select=settings->foo->>bar::integer&id=eq.1"},
  {"json-arrow-terminal", "/complex_items?id=eq.1&select=settings->foo"},
  {"json-array-index", "/complex_items?id=eq.1&select=arr_data->>0::int"},
  {"json-negative-index", "/complex_items?id=eq.1&select=arr_data->>-1::int"},
  {"json-array-arrow", "/complex_items?id=eq.1&select=arr_data->0"},
  {"json-duplicate-names",
   "/complex_items?id=eq.1&select=settings->foo->>bar,settings->foo->>baz"},
  {"two-columns", "/projects?select=id,name&order=id"},
  {"columns-param-ignored", "/items?columns=id&order=id"},
  {"on-conflict-param-ignored", "/items?on_conflict=id&order=id"},
  {"duplicate-alias", "/projects?select=a:id,b:id&order=id&limit=2"},
  {"star-and-column", "/clients?select=*,id&order=id&limit=1"}
]

for {id, path} <- cases, do: %{id: "select/" <> id, path: encode.(path)}
