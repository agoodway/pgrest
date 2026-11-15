# Horizontal filter operators (PostgREST test/spec Query/*, AndOrParams, JsonOperator).
# Names are `<group>/<case>`; most groups run on tables the fixture ships (items,
# projects, entities, complex_items, no_pk, ranges, tsearch, type_cases, csv_edge).
# Scenarios are written readably; percent-encode what an HTTP request target cannot carry.
encode = fn path ->
  for <<byte <- path>>, into: "" do
    if byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9 or byte in ~c"-._~!$&'()*+,;=:@/?%",
      do: <<byte>>,
      else: "%" <> Base.encode16(<<byte>>)
  end
end

sorted = fn id, path -> %{id: "filters/" <> id, path: encode.(path), sort: true} end

basic = [
  {"eq", "/items?id=eq.5"},
  {"not-eq", "/items?id=not.eq.5&order=id"},
  {"neq", "/items?id=neq.5&order=id"},
  {"duplicate-keys-gt-lt", "/items?id=gt.1&id=lt.5&order=id"},
  {"duplicate-keys-three", "/items?id=gte.2&id=lte.9&id=neq.4&order=id"},
  {"not-lt", "/items?id=not.lt.14&order=id.asc"},
  {"not-gt", "/items?id=not.gt.2&order=id"},
  {"gte-lte", "/items?id=gte.3&id=lte.5&order=id"},
  {"in", "/items?id=in.(1,3,5)&order=id"},
  {"not-in", "/items?id=not.in.(2,4,6,7,8,9,10,11,12,13,14,15)&order=id"},
  {"in-empty", "/items?id=in.()"},
  {"in-blank", "/items?id=in.( )"},
  {"not-in-empty", "/items?id=not.in.()&order=id"},
  {"in-blank-element-is-22P02", "/items?id=in.( ,3,4)"},
  {"in-not-a-number", "/items?id=in.(1,abc)"},
  {"eq-not-a-number", "/items?id=eq.abc"},
  {"eq-empty-value-int", "/items?id=eq."},
  {"unknown-column", "/items?nope=eq.1"},
  {"two-columns-anded", "/projects?name=like.Windows*&client_id=eq.1&order=id"}
]

patterns = [
  {"like-suffix", "/projects?name=like.*7"},
  {"like-prefix", "/projects?name=like.Windows*&order=id"},
  {"like-case-sensitive", "/projects?name=like.*windows*"},
  {"like-both-ends", "/projects?name=like.*indow*&order=id"},
  {"not-like", "/projects?name=not.like.Windows*&order=id"},
  {"ilike", "/projects?name=ilike.WINDOWS*&order=id"},
  {"ilike-infix", "/projects?name=ilike.*SX&order=id"},
  {"not-ilike", "/projects?name=not.ilike.windows*&order=id"},
  {"match", "/projects?name=match.7$"},
  {"match-anchor", "/projects?name=match.^Win&order=id"},
  {"imatch", "/projects?name=imatch.^win&order=id"},
  {"not-match", "/projects?name=not.match.7$&order=id"},
  {"not-imatch", "/projects?name=not.imatch.^win&order=id"},
  {"like-literal-percent", "/projects?name=like.%25ows%25"},
  {"like-on-integer-column", "/projects?id=like.1"},
  {"like-any-on-integer-column", "/projects?id=like(any).{1,2}"},
  {"citext-like", "/type_cases?email=like.alice*&select=id"},
  {"citext-ilike-any", "/type_cases?email=ilike(any).{ALICE*,nobody}&select=id"},
  {"citext-match", "/type_cases?email=match.^BOB&select=id"}
]

nulls = [
  {"is-null", "/no_pk?a=is.null"},
  {"is-not-null", "/no_pk?a=is.not_null"},
  {"not-is-null", "/no_pk?a=not.is.null"},
  {"not-is-not-null", "/no_pk?a=not.is.not_null"},
  {"is-null-uppercase", "/no_pk?a=is.NULL"},
  {"is-not-null-mixed-case", "/no_pk?a=is.NoT_NuLl"},
  {"is-null-integer-column", "/projects?client_id=is.null"},
  {"is-nil-is-400", "/no_pk?a=is.nil"},
  {"is-ok-is-400", "/no_pk?a=is.ok"},
  {"is-true-on-text-column", "/no_pk?a=is.true"},
  {"isdistinct", "/no_pk?select=a&a=isdistinct.2"},
  {"not-isdistinct", "/no_pk?select=a&a=not.isdistinct.2"},
  {"isdistinct-null-column-int", "/type_cases?select=id&qty=isdistinct.10&order=id"}
]

arrays_ranges = [
  {"cs", "/complex_items?select=id&arr_data=cs.{2}&order=id"},
  {"cs-multiple", "/complex_items?arr_data=cs.{1,2}&select=id&order=id"},
  {"cd", "/complex_items?select=id&arr_data=cd.{1,2,4}&order=id"},
  {"ov", "/complex_items?select=id&arr_data=ov.{3,9}&order=id"},
  {"eq-array", "/entities?arr=eq.{1,2,3}&select=id"},
  {"neq-array", "/entities?arr=neq.{1,2,3}&select=id&order=id"},
  {"cs-text-array", "/complex_items?tags=cs.{a,b}&select=id&order=id"},
  {"cs-malformed-array", "/complex_items?arr_data=cs.1,2"},
  {"cs-jsonb", ~S|/complex_items?settings=cs.{"foo":{"int":1}}&select=id&order=id|},
  {"cd-jsonb",
   ~S|/complex_items?settings=cd.{"foo":{"int":1,"bar":"baz","x":1}}&select=id&order=id|},
  {"range-eq", "/ranges?range=eq.[1,3]"},
  {"range-neq", "/ranges?range=neq.[1,3]&select=id&order=id"},
  {"range-lt", "/ranges?range=lt.[1,10]&select=id&order=id"},
  {"range-gt", "/ranges?range=gt.[1,2]&select=id&order=id"},
  {"range-cs", "/ranges?range=cs.[2,2]&select=id&order=id"},
  {"range-sl", "/ranges?range=sl.[10,20]&select=id&order=id"},
  {"range-sr", "/ranges?range=sr.[0,0]&select=id&order=id"},
  {"range-nxr", "/ranges?range=nxr.[5,5]&select=id&order=id"},
  {"range-nxl", "/ranges?range=nxl.[4,4]&select=id&order=id"},
  {"range-adj", "/ranges?range=adj.(1,10)&select=id&order=id"},
  {"range-adj-touching", "/ranges?range=adj.[13,14)&select=id&order=id"},
  {"range-ov", "/ranges?range=ov.[3,3]&select=id&order=id"}
]

in_quoting = [
  {"in-quoted-comma", ~S|/csv_edge?label=in.("comma, inside")&select=id|},
  {"in-mixed-quoted-unquoted", ~S|/csv_edge?label=in.(plain,"comma, inside")&select=id|},
  {"in-escaped-quote", ~S|/csv_edge?label=in.("quote \"inside\"")&select=id|},
  {"in-escaped-backslash", ~S|/csv_edge?label=in.("\\")&select=id|},
  {"in-any-escaped-char", ~S|/csv_edge?label=in.("c\o\m\m\a, i\nside")&select=id|},
  {"in-stray-quote-unquoted", ~S|/csv_edge?label=in.(")&select=id|},
  {"in-parens-unquoted", "/grandchild_entities?name=in.((grandchild,entity,4))&select=id"},
  {"in-quoted-parens",
   ~S|/grandchild_entities?name=in.("(grandchild,entity,4)","(grandchild,entity,5)")&select=id&order=id|},
  {"not-in-quoted",
   ~S|/grandchild_entities?name=not.in.("(grandchild,entity,4)",grandchild entity 1)&select=id&order=id|},
  {"in-quoted-number", ~S|/items?id=in.("1","2")&order=id|},
  {"in-whitespace", "/items?id=in.( 1 , 2 )&order=id"},
  {"in-quoted-empty-text", ~S|/csv_edge?label=in.("")&select=id|},
  {"not-in-quoted-empty-text", ~S|/csv_edge?label=not.in.("")&select=id&order=id|},
  {"in-quoted-empty-int", ~S|/items?id=in.("")|},
  {"not-in-quoted-empty-int", ~S|/items?id=not.in.("")&select=id&order=id|}
]

reserved_unicode = [
  {"empty-string", "/csv_edge?label=eq.&select=id"},
  {"unicode-percent-encoded",
   "/csv_edge?label=eq.unicode%3A%20h%C3%A9llo%20%E2%9C%93%20%E6%97%A5%E6%9C%AC&select=id,label"},
  {"unicode-like", "/csv_edge?label=like.unicode*&select=id,label"},
  {"unicode-ilike-infix", "/csv_edge?label=ilike.*H%C3%89LLO*&select=id"},
  {"unicode-in", ~S|/csv_edge?label=in.("unicode: héllo ✓ 日本",plain)&select=id|},
  {"reserved-ampersand", "/csv_edge?label=eq.a%26b&select=id"},
  {"reserved-percent", "/csv_edge?label=like.100%25*&select=id"},
  {"reserved-plus-is-space", "/csv_edge?label=eq.comma,+inside&select=id"},
  {"reserved-comma", "/csv_edge?label=eq.comma,%20inside&select=id"},
  {"reserved-hash", "/csv_edge?label=eq.a%23b&select=id"},
  {"missing-operator", "/items?id=0"}
]

modifiers = [
  {"eq-any", "/projects?id=eq(any).{3,4,5}&order=id"},
  {"gt-all", "/projects?id=gt(all).{4,3}&order=id"},
  {"gte-all", "/projects?id=gte(all).{4,3}&order=id"},
  {"lt-all", "/projects?id=lt(all).{4,3}&order=id"},
  {"lte-all", "/projects?id=lte(all).{4,3}&order=id"},
  {"like-any", "/projects?name=like(any).{Windows*,*OS}&select=id&order=id"},
  {"ilike-all", "/projects?name=ilike(all).{*WINDOWS*,*10}&select=id&order=id"},
  {"match-any", "/projects?name=match(any).{IOS,Orphan}&select=id&order=id"},
  {"imatch-any", "/projects?name=imatch(any).{^ios,^orph}&select=id&order=id"},
  {"eq-any-quoted",
   ~S|/csv_edge?label=eq(any).{"comma, inside","quote \"inside\""}&select=id&order=id|},
  {"eq-any-not-a-number", "/projects?id=eq(any).{1,x}"},
  {"modifier-not-allowed", "/projects?id=neq(any).{1}"}
]

logic = [
  {"or-and-nested", "/items?or=(id.eq.1,and(id.gt.5,id.lt.7))&order=id"},
  {"not-or", "/entities?not.or=(id.eq.1,id.eq.2)&select=id&order=id"},
  {"or-plus-plain", "/entities?or=(id.eq.1,id.eq.2)&name=eq.entity%201&select=id"},
  {"nested",
   "/entities?or=(and(name.eq.entity%202,id.eq.2),and(name.eq.entity%201,id.eq.1))&select=id&order=id"},
  {"negated-nested",
   "/entities?or=(not.and(name.eq.entity%202,id.eq.2),not.and(name.eq.entity%201,id.eq.1))&select=id&order=id"},
  {"and-and-or", "/entities?and=(id.eq.1,name.eq.entity%201)&or=(id.eq.1,id.eq.2)&select=id"},
  {"operators", "/entities?or=(id.lt.2,id.gt.3)&select=id&order=id"},
  {"like-ilike", "/entities?or=(name.like.*1,name.ilike.*ENTITY%202)&select=id&order=id"},
  {"in-in", "/entities?or=(id.in.(1,2),id.in.(3,4))&select=id&order=id"},
  {"is-null", "/entities?and=(name.is.null,arr.is.null)&select=id"},
  {"cs-cd", "/entities?or=(arr.cs.{1,2,3},arr.cd.{1})&select=id&order=id"},
  {"isdistinct", "/entities?or=(arr.isdistinct.{1},id.eq.4)&select=id&order=id"},
  {"not-prefixed-ops",
   "/entities?and=(arr.not.cs.{1,2,3},and(id.not.eq.2,name.not.like.*3))&select=id"},
  {"not-in-not-is", "/entities?and=(id.not.in.(1,3),name.not.is.null)&select=id&order=id"},
  {"quoted-comma-parens",
   ~S|/grandchild_entities?or=(name.eq."(grandchild,entity,4)",name.eq."(grandchild,entity,5)")&select=id&order=id|},
  {"quoted-like",
   ~S|/grandchild_entities?or=(name.like."*ity,4*",name.ilike."*ITY,5)")&select=id&order=id|},
  {"whitespace",
   "/entities?and=( and ( id.in.( 1, 2, 3 ) , id.eq.3 ) , or ( id.eq.2 , id.eq.3 ) )&select=id"},
  {"empty-is-400", "/entities?or=()"},
  {"single", "/entities?or=(id.eq.1)&select=id"},
  {"and-single", "/entities?and=(id.eq.1)&select=id"},
  {"column-named-or-prefix",
   "/grandchild_entities?or=(and_starting_col.eq.smth,or_starting_col.eq.smth)&select=id"},
  {"json-in-or",
   "/grandchild_entities?or=(jsonb_col->a->>b.eq.foo,jsonb_col->>b.eq.bar)&select=id&order=id"},
  {"fts-in-or",
   "/tsearch?or=(text_search_vector.plfts(german).Art%20Spass,text_search_vector.fts(english).impossible)"},
  {"not-fts-in-or", "/entities?and=(text_search_vector.not.fts.foo,id.lte.2)&select=id&order=id"}
]

json = [
  {"arrow-arrow-text", "/complex_items?settings->foo->>bar=eq.baz&select=id&order=id"},
  {"no-match", "/complex_items?settings->foo->>bar=eq.fake&select=id"},
  {"not-eq", "/complex_items?settings->foo->>bar=not.eq.baz&select=id"},
  {"int-as-text", "/complex_items?settings->foo->>int=eq.1&select=id&order=id"},
  {"int-gt-text-compare", "/complex_items?settings->foo->>int=gt.0&select=id&order=id"},
  {"jsonb-arrow-eq", ~S|/complex_items?settings->foo->bar=eq."baz"&select=id&order=id|},
  {"jsonb-object-eq",
   ~S|/complex_items?settings->foo=eq.{"int":1,"bar":"baz"}&select=id&order=id|},
  {"double-arrow-then-arrow", "/complex_items?settings->>foo->>bar=eq.baz&select=id"},
  {"key-with-apostrophe", "/complex_items?settings->>it's=eq.x&select=id"},
  {"key-with-apostrophe-is-null", "/complex_items?settings->>it's=is.null&select=id&order=id"},
  {"key-with-double-quote", "/complex_items?settings->>he%22llo=eq.x&select=id"},
  {"key-with-double-quote-is-null",
   "/complex_items?settings->>he%22llo=is.null&select=id&order=id"},
  {"quoted-key", ~S|/complex_items?settings->>"foo"=is.null&select=id|},
  {"index-on-object", "/complex_items?settings->>0=eq.1&select=id"},
  {"index-on-array-column", "/complex_items?arr_data->>0=eq.1&select=id"},
  {"huge-index", "/complex_items?settings->>99999999999999999999=eq.1&select=id"},
  {"nested-jsonb-col", "/grandchild_entities?jsonb_col->a->>b=eq.foo&select=id"}
]

fts = [
  {"fts-english", "/tsearch?text_search_vector=fts(english).impossible"},
  {"fts-default-config", "/tsearch?text_search_vector=fts.impossible"},
  {"fts-and", "/tsearch?text_search_vector=fts(english).fun%26possible"},
  {"fts-or", "/tsearch?text_search_vector=fts(english).impossible%7Cpossible"},
  {"plfts-french", "/tsearch?text_search_vector=plfts(french).amusant"},
  {"plfts-two-words", "/tsearch?text_search_vector=plfts(english).impossible%20possible"},
  {"phfts", "/tsearch?text_search_vector=phfts(english).The%20Fat%20Cats"},
  {"not-phfts", "/tsearch?text_search_vector=not.phfts(english).The%20Fat%20Cats"},
  {"wfts", "/tsearch?text_search_vector=wfts(english).impossible%20or%20possible"},
  {"fts-german", "/tsearch?text_search_vector=plfts(german).Art%20Spass"},
  {"fts-unknown-config", "/tsearch?text_search_vector=fts(nonexistent).cat"},
  {"fts-on-text-column", "/entities?name=fts(english).entity&select=id&order=id"},
  {"fts-on-text-column-no-config", "/entities?name=fts.entity&select=id&order=id"},
  {"fts-on-text-column-not", "/entities?name=not.plfts(english).one&select=id&order=id"},
  {"fts-on-json-column", "/complex_items?settings=fts(english).baz&select=id&order=id"},
  {"fts-malformed-query", "/tsearch?text_search_vector=fts(english).%26%26"}
]

type_cases = [
  {"enum-eq", "/type_cases?status=eq.active&select=id"},
  {"enum-eq-uppercase", "/type_cases?status=eq.ONLINE&select=id"},
  {"enum-in", "/type_cases?status=in.(draft,active)&select=id&order=id"},
  {"enum-in-invalid", "/type_cases?status=in.(ONLINE,OFFLINE)&select=id"},
  {"enum-gt", "/type_cases?status=gt.draft&select=id&order=id"},
  {"citext-case-insensitive", "/type_cases?email=eq.ALICE@EXAMPLE.COM&select=id"},
  {"citext-in", "/type_cases?email=in.(BOB@example.com)&select=id"},
  {"int4-eq-no-match", "/type_cases?qty=eq.3&select=id"},
  {"int4-eq", "/type_cases?qty=eq.10&select=id"},
  {"int4-decimal-text", "/type_cases?qty=eq.10.0&select=id"},
  {"int4-gt", "/type_cases?qty=gt.10&select=id"},
  {"timestamptz-offset", "/type_cases?at=gte.2024-06-15T14:30:00%2B02:00&select=id&order=id"},
  {"timestamptz-utc", "/type_cases?at=eq.2024-01-01T00:00:00Z&select=id"},
  {"timestamptz-invalid", "/type_cases?at=gt.yesterday-ish&select=id"},
  {"numeric-exact", "/type_cases?price=eq.9.99&select=id"},
  {"numeric-trailing-zero", "/type_cases?price=eq.9.990&select=id"},
  {"numeric-no-rounding", "/type_cases?price=eq.9.994&select=id"},
  {"numeric-1-005", "/type_cases?price=eq.1.005&select=id"},
  {"numeric-in", "/type_cases?price=in.(9.99,19.5)&select=id&order=id"},
  {"numeric-any", "/type_cases?price=gt(any).{10,19}&select=id&order=id"},
  {"char-padded", "/type_cases?code=eq.ab&select=id"},
  {"char-longer-than-column", "/type_cases?code=eq.abcd&select=id"},
  {"char-in", "/type_cases?code=in.(abc,ab)&select=id&order=id"},
  {"bit-eq", "/type_cases?bits=eq.101&select=id"},
  {"bit-shorter-than-column", "/type_cases?bits=eq.1&select=id"},
  {"bit-in", "/type_cases?bits=in.(101,010)&select=id&order=id"}
]

cases =
  for {group, entries} <- [
        {"basic", basic},
        {"pattern", patterns},
        {"null", nulls},
        {"array-range", arrays_ranges},
        {"in-quoting", in_quoting},
        {"reserved-unicode", reserved_unicode},
        {"modifier", modifiers},
        {"logic", logic},
        {"json", json},
        {"fts", fts},
        {"type", type_cases}
      ],
      {name, path} <- entries do
    sorted.("#{group}/#{name}", path)
  end

cases
