defmodule PgRest.SQL.WhereTest do
  # Not async: the index test and the catalog share the compat database.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias PgRest.Catalog
  alias PgRest.Compat.Repo
  alias PgRest.Grammar.Filter
  alias PgRest.SQL.{Builder, Where}

  @types %{
    "id" => "bigint",
    "qty" => "integer",
    "price" => "numeric(10,2)",
    "name" => "text",
    "tags" => "text[]",
    "doc" => "tsvector",
    "body" => "text",
    "settings" => "jsonb",
    "arr" => "integer[]",
    "status" => "test.status_enum"
  }

  defp condition(key, value) do
    assert {:ok, condition} = Filter.parse_condition(key, value)
    condition
  end

  defp tree(key, value) do
    assert {:ok, tree} = Filter.parse_logic(key, value)
    tree
  end

  defp compile_live(node, table) do
    types = Catalog.column_types(Repo, "test", table)
    categories = Catalog.column_categories(Repo, "test", table)

    {iodata, builder} =
      Where.compile(node, "t", types, Builder.new(), categories: categories)

    Builder.to_sql(builder, iodata)
  end

  defp compile(node, opts \\ []) do
    {iodata, builder} = Where.compile(node, "t", @types, Builder.new(), opts)
    {sql, params} = Builder.to_sql(builder, iodata)
    {sql, params}
  end

  describe "emitted SQL" do
    test "eq casts to the catalog type, dropping the typmod" do
      assert compile(condition("id", "eq.5")) == {~S|"t"."id" = $1::text::bigint|, ["5"]}

      assert compile(condition("price", "eq.9.994")) ==
               {~S|"t"."price" = $1::text::numeric|, ["9.994"]}

      assert compile(condition("status", "eq.draft")) ==
               {~S|"t"."status" = $1::text::test.status_enum|, ["draft"]}
    end

    test "in binds one text array and casts it" do
      assert compile(condition("id", "in.(1,2)")) ==
               {~S|"t"."id" = ANY($1::text[]::bigint[])|, [["1", "2"]]}
    end

    test "fts keeps the config as a bind parameter" do
      assert compile(condition("doc", "fts(english).cat")) ==
               {~S|"t"."doc" @@ to_tsquery($1::text::regconfig, $2::text)|, ["english", "cat"]}

      assert compile(condition("body", "plfts(french).cat")) ==
               {~S|to_tsvector($1::text::regconfig, "t"."body") @@ plainto_tsquery($2::text::regconfig, $3::text)|,
                ["french", "french", "cat"]}

      assert {~S|"t"."doc" @@ websearch_to_tsquery($1::text)|, ["cat"]} ==
               compile(condition("doc", "wfts.cat"))
    end

    test "any and all use ANY/ALL over a typed array" do
      assert compile(condition("id", "gt(all).{1,2}")) ==
               {~S|"t"."id" > ALL($1::text[]::bigint[])|, [["1", "2"]]}

      assert compile(condition("name", "like(any).{a*,*b}")) ==
               {~S|"t"."name" LIKE ANY($1)|, [["a%", "%b"]]}
    end

    test "negated logic nests with parentheses" do
      node = tree("not.or", "(id.eq.1,and(id.gt.5,id.lt.7))")

      assert compile(node) ==
               {~S|NOT (("t"."id" = $1::text::bigint OR ("t"."id" > $2::text::bigint AND "t"."id" < $3::text::bigint)))|,
                ["1", "5", "7"]}

      assert compile(condition("id", "not.eq.1")) ==
               {~S|NOT ("t"."id" = $1::text::bigint)|, ["1"]}
    end

    test "json path keys appear only as parameters" do
      {sql, params} = compile(condition("settings->foo->>it's", "eq.x"))

      assert sql ==
               ~S|"t"."settings" -> $1 ->> $2 = $3::text|

      assert params == ["foo", "it's", "x"]
      refute sql =~ "foo"
      refute sql =~ "it's"
    end

    test "json arrow result compares as jsonb and indexes bind as text int" do
      assert compile(condition("settings->a", ~S|eq.{"b":2}|)) ==
               {~S|"t"."settings" -> $1 = $2::text::jsonb|, ["a", ~S|{"b":2}|]}

      assert compile(condition("settings->>99999999999999999999", "eq.1")) ==
               {~S|"t"."settings" ->> $1::text::int = $2::text|, ["+99999999999999999999", "1"]}
    end

    test "is, isdistinct and array operators" do
      assert compile(condition("name", "is.null")) == {~S|"t"."name" IS NULL|, []}
      assert compile(condition("name", "is.not_null")) == {~S|"t"."name" IS NOT NULL|, []}
      assert compile(condition("name", "is.unknown")) == {~S|"t"."name" IS UNKNOWN|, []}

      assert compile(condition("id", "isdistinct.2")) ==
               {~S|"t"."id" IS DISTINCT FROM $1::text::bigint|, ["2"]}

      assert compile(condition("arr", "cs.{1,2}")) ==
               {~S|"t"."arr" @> $1::text::integer[]|, ["{1,2}"]}
    end

    test "string and enum columns bind a bare parameter" do
      {iodata, builder} =
        Where.compile(condition("status", "eq.active"), "t", @types, Builder.new(),
          categories: %{"status" => "E", "name" => "S", "id" => "N"}
        )

      assert Builder.to_sql(builder, iodata) == {~S|"t"."status" = $1|, ["active"]}

      {iodata, builder} =
        Where.compile(condition("name", "in.(a,b)"), "t", @types, Builder.new(),
          categories: %{"name" => "S"}
        )

      assert Builder.to_sql(builder, iodata) == {~S|"t"."name" = ANY($1)|, [["a", "b"]]}

      {iodata, builder} =
        Where.compile(condition("id", "eq.1"), "t", @types, Builder.new(),
          categories: %{"id" => "N"}
        )

      assert Builder.to_sql(builder, iodata) == {~S|"t"."id" = $1::text::bigint|, ["1"]}
    end

    test "in with the empty list matches nothing, like PostgREST" do
      assert compile(condition("id", "in.()")) == {~S|"t"."id" = ANY('{}')|, []}
      assert compile(condition("id", ~S|in.("")|)) == {~S|"t"."id" = ANY('{}')|, []}
      assert {_sql, [["", "3"]]} = compile(condition("id", "in.( ,3)"))
    end

    test "pattern operators bind a bare parameter" do
      assert compile(condition("name", "like.a*")) == {~S|"t"."name" LIKE $1|, ["a%"]}
      assert compile(condition("name", "imatch.^a")) == {~S|"t"."name" ~* $1|, ["^a"]}
    end

    test "typmods are dropped without changing semantics" do
      types = %{
        "c" => "character(3)",
        "ca" => "character(3)[]",
        "b" => "bit(3)",
        "v" => "bit varying(5)",
        "vc" => "character varying(10)",
        "ts" => "timestamp(3) with time zone",
        "q" => ~S|test."we(1)ird"|
      }

      sql = fn field ->
        {iodata, builder} =
          Where.compile(condition(field, "eq.x"), "t", types, Builder.new())

        iodata |> then(&Builder.to_sql(builder, &1)) |> elem(0)
      end

      assert sql.("c") == ~S|"t"."c" = $1::text::bpchar|
      assert sql.("ca") == ~S|"t"."ca" = $1::text::bpchar[]|
      assert sql.("b") == ~S|"t"."b" = $1::text::varbit|
      assert sql.("v") == ~S|"t"."v" = $1::text::bit varying|
      assert sql.("vc") == ~S|"t"."vc" = $1::text::character varying|
      assert sql.("ts") == ~S|"t"."ts" = $1::text::timestamp with time zone|
      assert sql.("q") == ~S|"t"."q" = $1::text::test."we(1)ird"|
    end

    test "columns option maps field names to sources" do
      assert compile(condition("name", "eq.x"), columns: %{"name" => "full_name"}) ==
               {~S|"t"."full_name" = $1::text|, ["x"]}
    end
  end

  describe "against Postgres" do
    @cases [
      {"items", "id", "in.(1,3,5)", [1, 3, 5]},
      {"items", "id", "not.in.(2,4,6,7,8,9,10,11,12,13,14,15)", [1, 3, 5]},
      {"items", "id", "in.()", []},
      {"items", "id", "not.in.()", Enum.to_list(1..15)},
      {"complex_items", "arr_data", "cs.{2}", [2, 3]},
      {"complex_items", "arr_data", "cd.{1,2,4}", [1, 2]},
      {"complex_items", "settings->foo->>bar", "eq.baz", [1, 2, 3]},
      {"complex_items", "settings->foo->bar", ~S|eq."baz"|, [1, 2, 3]},
      {"complex_items", "settings->foo->>int", "eq.1", [1, 2, 3]},
      {"complex_items", "name", "like.T*", [2, 3]},
      {"complex_items", "name", "ilike(any).{one,*WO}", [1, 2]},
      {"ranges", "range", "adj.(1,10)", []},
      {"ranges", "range", "sl.[10,20]", [1, 2, 3]},
      {"ranges", "range", "ov.[3,3]", [1, 2]},
      {"projects", "id", "gt(all).{4,3}", [5]},
      {"projects", "id", "eq(any).{3,4,5}", [3, 4, 5]},
      {"type_cases", "status", "in.(draft,active)", [1, 2]},
      {"type_cases", "email", "eq.ALICE@EXAMPLE.COM", [1]},
      {"type_cases", "at", "gte.2024-06-15T14:30:00+02:00", [2]},
      {"type_cases", "price", "eq.9.994", []},
      {"type_cases", "price", "eq.9.990", [1]},
      {"type_cases", "qty", "isdistinct.10", [2, 3]},
      {"csv_edge", "label", "eq.unicode: héllo ✓ 日本", [4]},
      {"items", "id", ~S|in.("")|, []},
      {"items", "id", ~S|not.in.("")|, Enum.to_list(1..15)},
      {"type_cases", "code", "eq.ab", [2]},
      {"type_cases", "code", "eq.abcd", []},
      {"type_cases", "code", "in.(abc,ab)", [1, 2]},
      {"type_cases", "bits", "eq.101", [1]},
      {"type_cases", "bits", "eq.1", []},
      {"type_cases", "bits", "in.(101,010)", [1, 2]},
      {"type_cases", "email", "like.alice*", [1]},
      {"type_cases", "email", "ilike(any).{ALICE*,nobody}", [1]},
      {"type_cases", "email", "match.^BOB", [2]}
    ]

    for {table, key, value, ids} <- @cases do
      test "#{table}?#{key}=#{value}" do
        {where, params} = compile_live(condition(unquote(key), unquote(value)), unquote(table))
        sql = ~s|SELECT t.id FROM test.#{unquote(table)} t WHERE #{where} ORDER BY 1|
        assert Enum.map(Repo.query!(sql, params).rows, &hd/1) == unquote(ids)
      end
    end

    test "fts on a tsvector column and on a text column" do
      for {table, col, value, count} <- [
            {"tsearch", "text_search_vector", "fts(english).impossible", 1},
            {"tsearch", "text_search_vector", "plfts(french).amusant", 1},
            {"entities", "name", "fts(english).entity", 3}
          ] do
        {where, params} = compile_live(condition(col, value), table)
        sql = ~s|SELECT count(*) FROM test.#{table} t WHERE #{where}|
        assert [[^count]] = Repo.query!(sql, params).rows
      end
    end

    test "a malformed value is Postgres 22P02" do
      {where, params} = compile_live(condition("id", "eq.abc"), "items")

      assert {:error, %Postgrex.Error{postgres: %{code: :invalid_text_representation}}} =
               Repo.query("SELECT 1 FROM test.items t WHERE #{where}", params)
    end

    for {key, value, index} <- [
          {"qty", "eq.3", "type_cases_qty_idx"},
          {"status", "eq.active", "type_cases_status_idx"},
          {"status", "in.(draft,active)", "type_cases_status_idx"},
          {"email", "eq.x@example.com", "type_cases_email_idx"}
        ] do
      test "type_cases?#{key}=#{value} uses #{index}" do
        {where, params} = compile_live(condition(unquote(key), unquote(value)), "type_cases")

        assert {:ok, plan} =
                 Repo.transaction(fn ->
                   Repo.query!("SET LOCAL enable_seqscan = off")

                   %{rows: rows} =
                     Repo.query!(
                       ~s|EXPLAIN SELECT 1 FROM test.type_cases t WHERE #{where}|,
                       params
                     )

                   Enum.map_join(rows, "\n", &hd/1)
                 end)

        assert plan =~ unquote(index)
        refute plan =~ "::numeric"
      end
    end
  end
end
