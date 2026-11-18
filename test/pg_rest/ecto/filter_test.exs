defmodule PgRest.Ecto.FilterTest do
  use ExUnit.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias PgRest.AST.{Condition, Field, Logic}
  alias PgRest.Ecto.Filter
  alias PgRest.Error
  alias PgRest.Grammar.Filter, as: Grammar

  defmodule TypeCase do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "type_cases" do
      field(:status, Ecto.Enum, values: [:draft, :active, :archived])
      field(:email, :string)
      field(:qty, :integer)
      field(:at, :utc_datetime)
      field(:price, :decimal)
    end
  end

  defmodule ComplexItem do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:tags, {:array, :string})
      field(:arr_data, {:array, :integer})
    end
  end

  # `complex_items` with its `text[]` tags typed as an `Ecto.Enum` array; `owner_ids` has no
  # column and is only compiled, never queried.
  defmodule TaggedItem do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:tags, {:array, Ecto.Enum}, values: [:a, :b, :c, :z])
      field(:owner_id, :binary_id)
      field(:owner_ids, {:array, :binary_id})
    end
  end

  defmodule Project do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      field(:client_id, :integer)
    end
  end

  defp parse!(key, value) do
    {:ok, condition} = Grammar.parse_condition(key, value)
    condition
  end

  defp logic!(key, value) do
    {:ok, tree} = Grammar.parse_logic(key, value)
    tree
  end

  defp where_of(schema, dynamic), do: from(r in schema, where: ^dynamic)

  defp dynamic!(node, opts) do
    assert {:ok, dynamic} = Filter.to_dynamic(node, opts)
    dynamic
  end

  # The `where` clause as Ecto prints it, e.g. `t0.qty > ^10`.
  defp expr(schema, node, opts \\ []) do
    schema
    |> where_of(dynamic!(node, Keyword.put_new(opts, :schema, schema)))
    |> Inspect.Ecto.Query.to_string()
    |> then(&Regex.run(~r/where: (.*)$/m, &1, capture: :all_but_first))
    |> hd()
  end

  defp params(schema, node, opts \\ []) do
    %Ecto.Query{wheres: [%{params: params}]} =
      where_of(schema, dynamic!(node, Keyword.put_new(opts, :schema, schema)))

    Enum.map(params, &elem(&1, 0))
  end

  describe "to_dynamic/2 comparisons" do
    for {op, sql} <- [eq: "==", neq: "!=", gt: ">", gte: ">=", lt: "<", lte: "<="] do
      test "#{op} compiles to #{sql}" do
        assert expr(TypeCase, parse!("qty", "#{unquote(op)}.10")) ==
                 "t0.qty #{unquote(sql)} ^10"
      end
    end

    test "casts the value with the schema field type" do
      assert params(TypeCase, parse!("qty", "eq.10")) == [10]
      assert params(TypeCase, parse!("price", "gt.9.5")) == [Decimal.new("9.5")]
      assert params(TypeCase, parse!("status", "eq.active")) == [:active]

      assert params(TypeCase, parse!("at", "lt.2024-03-01T00:00:00Z")) ==
               [~U[2024-03-01 00:00:00Z]]
    end

    test "accepts values that are already typed" do
      condition = %Condition{field: %Field{name: "qty"}, op: :gte, value: 10}
      assert params(TypeCase, condition) == [10]
    end

    test "isdistinct casts and compiles to != or IS NULL" do
      condition = parse!("qty", "isdistinct.10")
      assert expr(TypeCase, condition) == "t0.qty != ^10 or is_nil(t0.qty)"
      assert params(TypeCase, condition) == [10]
    end

    test "isdistinct from nil is IS NOT NULL" do
      condition = %Condition{field: %Field{name: "qty"}, op: :isdistinct, value: nil}
      assert expr(TypeCase, condition) == "not is_nil(t0.qty)"
    end

    test "not. negates the expression" do
      assert expr(TypeCase, parse!("qty", "not.eq.10")) == "not (t0.qty == ^10)"
    end
  end

  describe "to_dynamic/2 patterns" do
    test "like and ilike turn * into %, without casting" do
      assert expr(TypeCase, parse!("email", "ilike.*ali*")) == ~s|ilike(t0.email, ^"%ali%")|
      assert expr(TypeCase, parse!("email", "like.A*")) == ~s|like(t0.email, ^"A%")|
    end

    test "match and imatch are POSIX regex fragments" do
      assert expr(TypeCase, parse!("email", "match.^A")) =~ ~s|fragment("? ~ ?", t0.email|
      assert expr(TypeCase, parse!("email", "imatch.^a")) =~ ~s|fragment("? ~* ?", t0.email|
    end
  end

  describe "to_dynamic/2 in" do
    test "casts every element" do
      condition = parse!("qty", "in.(10,20)")
      assert expr(TypeCase, condition) == "t0.qty in ^[10, 20]"
    end

    test "not.in negates" do
      assert expr(TypeCase, parse!("qty", "not.in.(10)")) == "t0.qty not in ^[10]"
    end

    test ~s|in.() and in.("") are the empty list, as in PostgREST| do
      assert expr(TypeCase, parse!("status", "in.()")) == "t0.status in ^[]"
      assert expr(TypeCase, parse!("email", ~s|in.("")|)) == "t0.email in ^[]"
    end
  end

  describe "to_dynamic/2 is" do
    test "null and not_null" do
      assert expr(TypeCase, parse!("email", "is.null")) == "is_nil(t0.email)"
      assert expr(TypeCase, parse!("email", "is.not_null")) == "not is_nil(t0.email)"
      assert expr(TypeCase, parse!("email", "not.is.null")) == "not is_nil(t0.email)"
    end

    test "true, false and unknown keep SQL IS semantics" do
      assert expr(TypeCase, parse!("qty", "is.true")) == ~s|fragment("? IS TRUE", t0.qty)|
      assert expr(TypeCase, parse!("qty", "is.false")) == ~s|fragment("? IS FALSE", t0.qty)|
      assert expr(TypeCase, parse!("qty", "is.unknown")) == ~s|fragment("? IS UNKNOWN", t0.qty)|
    end
  end

  describe "to_dynamic/2 arrays" do
    for {op, sql} <- [cs: "@>", cd: "<@", ov: "&&"] do
      test "#{op} splits the array literal, casts it and compiles to #{sql}" do
        condition = parse!("arr_data", "#{unquote(op)}.{1,2}")

        assert expr(ComplexItem, condition) =~
                 ~s|fragment("? #{unquote(sql)} ?", c0.arr_data, ^[1, 2])|
      end
    end

    test "takes an already split list" do
      condition = %Condition{field: %Field{name: "tags"}, op: :cs, value: ["a", "b"]}
      assert params(ComplexItem, condition) == [["a", "b"]]
    end

    test "dumps elements for the fragment: enums to strings, UUIDs to 16 bytes" do
      assert params(TaggedItem, parse!("tags", "cs.{a,b}")) == [["a", "b"]]

      uuid = "8c5f1d8e-6a3a-4a7e-9a0e-1f0f6c8a2b3c"
      {:ok, bytes} = Ecto.UUID.dump(uuid)
      assert params(TaggedItem, parse!("owner_ids", "ov.{#{uuid}}")) == [[bytes]]
    end

    test "an element the field type rejects is a 22P02" do
      assert {:error, %Error{code: "22P02"}} =
               Filter.to_dynamic(parse!("tags", "cs.{a,nope}"), schema: TaggedItem)
    end

    test "a value that is not an array literal is a 22P02" do
      assert {:error, %Error{code: "22P02"}} =
               Filter.to_dynamic(parse!("tags", "cs.[1,5)"), schema: ComplexItem)
    end
  end

  describe "to_dynamic/2 UUID fields" do
    @uuid "8c5f1d8e-6a3a-4a7e-9a0e-1f0f6c8a2b3c"

    test "a malformed UUID is a 22P02" do
      for {key, value} <- [
            {"owner_id", "eq.not-a-uuid"},
            {"owner_id", "in.(#{@uuid},not-a-uuid)"},
            {"owner_ids", "cs.{not-a-uuid}"}
          ] do
        assert {:error, %Error{code: "22P02"}} =
                 Filter.to_dynamic(parse!(key, value), schema: TaggedItem)
      end
    end

    test "a valid UUID is cast and dumped" do
      {:ok, bytes} = Ecto.UUID.dump(@uuid)
      assert params(TaggedItem, parse!("owner_id", "eq.#{@uuid}")) == [@uuid]
      assert params(TaggedItem, parse!("owner_id", "in.(#{@uuid})")) == [[@uuid]]
      assert params(TaggedItem, parse!("owner_ids", "cs.{#{@uuid}}")) == [[bytes]]
    end

    test "an uppercase UUID is normalised" do
      assert params(TaggedItem, parse!("owner_id", "eq.#{String.upcase(@uuid)}")) == [@uuid]
    end
  end

  describe "to_dynamic/2 full-text search" do
    test "fts family without a config" do
      for {op, fun} <- [
            fts: "to_tsquery",
            plfts: "plainto_tsquery",
            phfts: "phraseto_tsquery",
            wfts: "websearch_to_tsquery"
          ] do
        assert expr(Project, parse!("name", "#{op}.windows")) =~
                 ~s|fragment("to_tsvector(?) @@ #{fun}(?)", p0.name, ^"windows")|
      end
    end

    test "a config binds as regconfig on both sides" do
      condition = parse!("name", "fts(english).windows")

      %Ecto.Query{wheres: [%{expr: expr}]} =
        where_of(Project, dynamic!(condition, schema: Project))

      assert {:fragment, [],
              [
                raw: "to_tsvector(",
                expr: _config,
                raw: "::text::regconfig, ",
                expr: _field,
                raw: ") @@ to_tsquery(",
                expr: _config2,
                raw: "::text::regconfig, ",
                expr: _query,
                raw: ")"
              ]} = expr

      assert params(Project, condition) == ["english", "english", "windows"]
    end
  end

  describe "to_dynamic/2 logic trees" do
    test "and/or nest and negate" do
      tree = logic!("or", "(qty.eq.10,and(qty.gt.15,email.not.is.null))")

      assert expr(TypeCase, tree) ==
               "t0.qty == ^10 or (t0.qty > ^15 and not is_nil(t0.email))"
    end

    test "not.and negates the whole node" do
      tree = logic!("not.and", "(qty.eq.10,qty.eq.20)")
      assert expr(TypeCase, tree) == "not (t0.qty == ^10 and t0.qty == ^20)"
    end

    test "the first failing child is the error" do
      tree = logic!("or", "(qty.eq.10,nope.eq.1)")

      assert {:error, %Error{code: "42703", message: "column type_cases.nope does not exist"}} =
               Filter.to_dynamic(tree, schema: TypeCase)
    end
  end

  describe "to_dynamic/2 field resolution" do
    test "a field the schema does not have is a 42703" do
      assert {:error, %Error{status: 400, code: "42703"}} =
               Filter.to_dynamic(parse!("nope", "eq.1"), schema: TypeCase)
    end

    test ":fields restricts the filterable fields" do
      assert {:ok, _dynamic} =
               Filter.to_dynamic(parse!("qty", "eq.1"), schema: TypeCase, fields: [:qty])

      assert {:error, %Error{code: "42703"}} =
               Filter.to_dynamic(parse!("email", "eq.a"), schema: TypeCase, fields: [:qty])
    end

    test ":fields without a schema resolves names and keeps values uncast" do
      condition = parse!("qty", "eq.10")
      dynamic = dynamic!(condition, fields: [:qty])
      %Ecto.Query{wheres: [%{params: [{"10", _type}]}]} = where_of("type_cases", dynamic)

      assert {:error, %Error{code: "42703", message: ~s|column "email" does not exist|}} =
               Filter.to_dynamic(parse!("email", "eq.a"), fields: [:qty])
    end

    test "a value the field type rejects is a 22P02" do
      assert {:error,
              %Error{code: "22P02", message: ~s|invalid input syntax for column "qty": "abc"|}} =
               Filter.to_dynamic(parse!("qty", "eq.abc"), schema: TypeCase)

      assert {:error, %Error{code: "22P02"}} =
               Filter.to_dynamic(parse!("qty", "in.(1,x)"), schema: TypeCase)
    end

    test "neither :schema nor :fields is an ArgumentError" do
      assert_raise ArgumentError, ~r/:schema or :fields/, fn ->
        Filter.to_dynamic(parse!("qty", "eq.1"), [])
      end
    end
  end

  describe "to_dynamic/2 unsupported filters" do
    test "JSON paths, any/all and range operators are refused with a PGRST100" do
      for {key, value} <- [
            {"settings->a", "eq.1"},
            {"qty", "eq(any).{1,2}"},
            {"qty", "sl.[1,5)"},
            {"qty", "adj.[1,5)"}
          ] do
        assert {:error, %Error{status: 400, code: "PGRST100", message: message}} =
                 Filter.to_dynamic(parse!(key, value), schema: TypeCase)

        assert message =~ "PgRest.Ecto.Filter does not support"
      end
    end
  end

  describe "to_dynamic/2 malformed values" do
    defp condition(name, op, value),
      do: %Condition{field: %Field{name: name}, op: op, value: value}

    test "an is value outside null, not_null, true, false and unknown is a PGRST100" do
      for value <- ["is.maybe", "maybe", nil, 1, [:null]] do
        assert {:error, %Error{status: 400, code: "PGRST100"}} =
                 Filter.to_dynamic(condition("qty", :is, value), schema: TypeCase)

        assert {:error, %Error{code: "PGRST100"}} =
                 Filter.to_dynamic(condition("qty", :is, value), fields: [:qty])
      end
    end

    test "a value of the wrong shape for its operator is a PGRST100, never a raise" do
      for {name, op, value} <- [
            {"qty", :in, "abc"},
            {"qty", :in, 10},
            {"email", :like, 1},
            {"email", :ilike, ["a"]},
            {"email", :match, nil},
            {"email", :imatch, %{}},
            {"name", :fts, 1},
            {"name", :wfts, ["windows"]}
          ] do
        for opts <- [[schema: schema_for(name)], [fields: [String.to_existing_atom(name)]]] do
          assert {:error, %Error{status: 400, code: "PGRST100"}} =
                   Filter.to_dynamic(condition(name, op, value), opts)
        end
      end
    end

    test "an array operator value that is neither a list nor a literal is a 22P02" do
      for opts <- [[schema: ComplexItem], [fields: [:tags]]] do
        assert {:error, %Error{code: "22P02"}} =
                 Filter.to_dynamic(condition("tags", :cs, 5), opts)
      end
    end

    test "a list or map compared without a schema type is a PGRST100" do
      for op <- [:eq, :neq, :gt, :gte, :lt, :lte, :isdistinct], value <- [[1], %{a: 1}] do
        assert {:error, %Error{code: "PGRST100"}} =
                 Filter.to_dynamic(condition("qty", op, value), fields: [:qty])
      end
    end

    test "nil compared with a comparison operator is a PGRST100, never a raise" do
      for op <- [:eq, :neq, :gt, :gte, :lt, :lte],
          opts <- [[schema: TypeCase], [fields: [:qty]]] do
        assert {:error, %Error{status: 400, code: "PGRST100"}} =
                 Filter.to_dynamic(condition("qty", op, nil), opts)
      end
    end

    test "a full-text config that is not a string is a PGRST100" do
      node = %Condition{field: %Field{name: "email"}, op: :fts, value: "cats", fts_config: 1}

      assert {:error, %Error{status: 400, code: "PGRST100"}} =
               Filter.to_dynamic(node, schema: TypeCase)
    end

    test "a struct value compared without a schema type binds as is" do
      for value <- [~D[2024-01-01], Decimal.new("9.5")] do
        assert {:ok, _dynamic} =
                 Filter.to_dynamic(condition("at", :gte, value), fields: [:at])
      end
    end

    test "an operator the compiler does not know is a PGRST100" do
      assert {:error, %Error{code: "PGRST100"}} =
               Filter.to_dynamic(condition("qty", :bogus, "1"), schema: TypeCase)
    end

    test "a logic node without children or with an unknown op is a PGRST100" do
      for op <- [:and, :or] do
        assert {:error, %Error{code: "PGRST100"}} =
                 Filter.to_dynamic(%Logic{op: op, children: []}, schema: TypeCase)
      end

      assert {:error, %Error{code: "PGRST100"}} =
               Filter.to_dynamic(
                 %Logic{op: :xor, children: [parse!("qty", "eq.1")]},
                 schema: TypeCase
               )
    end
  end

  defp schema_for("name"), do: Project
  defp schema_for(_name), do: TypeCase

  describe "where/3" do
    test "applies every node and takes the schema from the query" do
      nodes = [parse!("qty", "gt.10"), parse!("email", "is.not_null")]

      assert [%{params: [{10, _}]}, %{params: []}] =
               TypeCase |> Filter.where(nodes) |> wheres()
    end

    test "no nodes leaves the query without a where" do
      assert {:ok, %Ecto.Query{wheres: []}} = Filter.where(TypeCase, [])
    end

    test "returns the first error" do
      assert {:error, %Error{code: "22P02"}} =
               Filter.where(TypeCase, [parse!("qty", "eq.1"), parse!("qty", "eq.x")])
    end

    test "schema: nil with :fields skips casting" do
      assert [%{params: [{"10", _}]}] =
               TypeCase
               |> Filter.where([parse!("qty", "eq.10")], schema: nil, fields: [:qty])
               |> wheres()
    end

    test "a schemaless source needs :fields" do
      assert {:ok, %Ecto.Query{}} =
               Filter.where("type_cases", [parse!("qty", "eq.1")], fields: [:qty])

      assert_raise ArgumentError, fn -> Filter.where("type_cases", [parse!("qty", "eq.1")]) end
    end
  end

  defp wheres({:ok, %Ecto.Query{wheres: wheres}}), do: wheres
end

defmodule PgRest.Ecto.FilterDBTest do
  use ExUnit.Case, async: true

  import Ecto.Query, only: [order_by: 2, select: 3]

  alias PgRest.Compat.Repo
  alias PgRest.Ecto.Filter
  alias PgRest.Ecto.FilterTest.{ComplexItem, Project, TaggedItem, TypeCase}
  alias PgRest.Grammar.Filter, as: Grammar

  defp ids(schema, filters) do
    nodes = Enum.map(filters, &parse!/1)
    {:ok, query} = Filter.where(schema, nodes)

    query
    |> order_by(:id)
    |> select([r], r.id)
    |> Repo.all()
  end

  defp parse!({"or" = key, value}), do: ok!(Grammar.parse_logic(key, value))
  defp parse!({key, value}), do: ok!(Grammar.parse_condition(key, value))

  defp ok!({:ok, node}), do: node

  test "comparisons, enums, decimals and timestamps" do
    assert ids(TypeCase, [{"qty", "gte.20"}]) == [2]
    assert ids(TypeCase, [{"status", "eq.archived"}]) == [3]
    assert ids(TypeCase, [{"price", "lt.10"}]) == [1]
    assert ids(TypeCase, [{"at", "gt.2024-03-01T00:00:00Z"}]) == [2]
    assert ids(TypeCase, [{"qty", "not.eq.10"}]) == [2]
  end

  test "isdistinct keeps NULL rows and dumps enum values" do
    assert ids(TypeCase, [{"qty", "isdistinct.10"}]) == [2, 3]
    assert ids(TypeCase, [{"status", "isdistinct.active"}]) == [1, 3]
  end

  test "in, is and patterns" do
    assert ids(TypeCase, [{"qty", "in.(10,20)"}]) == [1, 2]
    assert ids(TypeCase, [{"status", "in.()"}]) == []
    assert ids(TypeCase, [{"status", "not.in.()"}]) == [1, 2, 3]
    assert ids(TypeCase, [{"email", "is.null"}]) == [3]
    assert ids(TypeCase, [{"email", "ilike.*EXAMPLE*"}]) == [1, 2]
    assert ids(TypeCase, [{"email", "like.bob*"}]) == [2]
  end

  test "array operators" do
    assert ids(ComplexItem, [{"tags", "cs.{a,b}"}]) == [2, 3]
    assert ids(ComplexItem, [{"arr_data", "cd.{1,2}"}]) == [1, 2]
    assert ids(ComplexItem, [{"tags", "ov.{c,z}"}]) == [3]
    assert ids(TaggedItem, [{"tags", "cs.{a,b}"}]) == [2, 3]
  end

  defmodule UuidItem do
    @moduledoc false
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: false}
    schema "uuid_items" do
    end
  end

  test "UUID fields compare against uuid columns" do
    uuid = "8c5f1d8e-6a3a-4a7e-9a0e-1f0f6c8a2b3c"
    {:ok, bytes} = Ecto.UUID.dump(uuid)

    Repo.checkout(fn ->
      Repo.query!("create temp table uuid_items (id uuid primary key)")
      Repo.query!("insert into uuid_items values ($1)", [bytes])

      assert {:ok, query} = Filter.where(UuidItem, [parse!({"id", "eq.#{String.upcase(uuid)}"})])
      assert Repo.all(query) |> Enum.map(& &1.id) == [uuid]

      assert {:ok, query} = Filter.where(UuidItem, [parse!({"id", "in.(#{uuid})"})])
      assert Repo.aggregate(query, :count) == 1

      assert {:error, %PgRest.Error{code: "22P02"}} =
               Filter.where(UuidItem, [parse!({"id", "eq.not-a-uuid"})])

      Repo.query!("drop table uuid_items")
    end)
  end

  test "logic trees" do
    assert ids(TypeCase, [{"or", "(qty.eq.10,status.eq.archived)"}]) == [1, 3]
  end

  test "full-text search" do
    assert ids(Project, [{"name", "fts.windows"}]) == [1, 2]
    assert ids(Project, [{"name", "fts(english).windows"}]) == [1, 2]
    assert ids(Project, [{"name", "wfts.windows 10"}]) == [2]
  end
end
