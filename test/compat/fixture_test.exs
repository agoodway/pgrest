defmodule PgRest.Compat.FixtureTest do
  use ExUnit.Case, async: true

  alias PgRest.Compat.{Repo, Resources}

  # Tables PostgREST's fixtures leave empty; their scenarios insert rows.
  @empty_tables ~w(compound_pk loc_test موارد)

  defp source(mod), do: mod.__schema__(:source)

  describe "resources" do
    test "all/0 lists distinct Ecto schemas prefixed with `test`" do
      mods = Resources.all()

      assert mods == Enum.uniq(mods)
      assert Enum.all?(mods, &(&1.__schema__(:prefix) == "test"))
    end

    test "every table and view in schema test has exactly one resource" do
      tables =
        sorted_column("""
        SELECT tablename FROM pg_tables t
        WHERE schemaname = 'test'
          AND NOT (SELECT relispartition FROM pg_class
                    WHERE oid = format('test.%I', t.tablename)::regclass)
        UNION ALL
        SELECT foreign_table_name FROM information_schema.foreign_tables
        WHERE foreign_table_schema = 'test'
        UNION ALL
        SELECT viewname FROM pg_views
        WHERE schemaname = 'test' AND viewname NOT LIKE 'pgrst_reload_%'
        """)

      assert tables == Resources.all() |> Enum.map(&source/1) |> Enum.sort()
    end

    for mod <- Resources.all() do
      table = mod.__schema__(:source)

      if table in @empty_tables do
        test "#{table} is seeded empty" do
          assert Repo.aggregate(unquote(mod), :count) == 0
        end
      else
        test "#{table} has seed rows" do
          assert Repo.aggregate(unquote(mod), :count) > 0
        end
      end
    end

    test "hashed_password is redacted" do
      assert :hashed_password in Resources.Accounts.__schema__(:redact_fields)
    end

    test "many_to_many through users_tasks preloads" do
      user = Repo.get!(Resources.Users, 1) |> Repo.preload(:tasks)

      assert user.tasks |> Enum.map(& &1.id) |> Enum.sort() == [1, 2, 3, 4]
    end
  end

  describe "foreign keys" do
    test "every single-column FK has a belongs_to association" do
      associations = belongs_to_pairs()

      missing =
        for {name, table, column, ref_table} <- single_column_fks(),
            {table, column, ref_table} not in associations,
            do: name

      assert missing == []
    end

    test "every belongs_to association has a real single-column FK behind it" do
      fks =
        for {_name, table, column, ref_table} <- single_column_fks(),
            do: {table, column, ref_table}

      assert for(pair <- belongs_to_pairs(), pair not in fks, do: pair) == []
    end

    test "every FK constraint, composite included, is a relationship in the graph" do
      graph = PgRest.SchemaGraph.build(Resources.all())

      in_graph =
        for {_m, rels} <- graph.rels,
            r <- rels,
            r.kind != :m2m,
            into: MapSet.new(),
            do: r.constraint

      %{rows: rows} =
        Repo.query!("""
        SELECT c.conname
          FROM pg_constraint c
          JOIN pg_namespace n ON n.oid = c.connamespace
         WHERE c.contype = 'f' AND n.nspname = 'test'
           AND NOT (SELECT relispartition FROM pg_class WHERE oid = c.conrelid)
        """)

      assert for([name] <- rows, name not in in_graph, do: name) == []
    end
  end

  describe "junctions" do
    # PostgREST addM2MRels, recomputed from pg_constraint: a table with two distinct
    # foreign keys whose columns all lie in its primary key is a junction.
    test "every junction in the database is a many-to-many relationship in the graph" do
      %{rows: rows} =
        Repo.query!("""
        SELECT c.contype, t.relname, c.conname, rt.relname,
               ARRAY(SELECT a.attname FROM unnest(c.conkey) k JOIN pg_attribute a
                      ON a.attrelid = c.conrelid AND a.attnum = k)
          FROM pg_constraint c
          JOIN pg_namespace n ON n.oid = c.connamespace
          JOIN pg_class t ON t.oid = c.conrelid
          LEFT JOIN pg_class rt ON rt.oid = c.confrelid
         WHERE c.contype IN ('f', 'p') AND n.nspname = 'test'
        """)

      pks = for ["p", table, _, _, cols] <- rows, into: %{}, do: {table, MapSet.new(cols)}
      fks = for ["f", table, name, ref, cols] <- rows, do: {table, name, ref, cols}

      expected =
        for {table, c1, ref1, cols1} <- fks,
            {^table, c2, ref2, cols2} <- fks,
            c1 != c2,
            MapSet.subset?(MapSet.new(cols1 ++ cols2), Map.get(pks, table, MapSet.new())),
            into: MapSet.new(),
            do: {ref1, ref2, table, c1, c2}

      graph = PgRest.SchemaGraph.build(Resources.all())

      actual =
        for {_module, rels} <- graph.rels,
            %{kind: :m2m} = rel <- rels,
            into: MapSet.new() do
          {source(rel.source), source(rel.target), rel.junction.table,
           elem(rel.junction.constraints, 0), elem(rel.junction.constraints, 1)}
        end

      assert MapSet.size(expected) > 0
      assert actual == expected
    end
  end

  defp belongs_to_pairs do
    for mod <- Resources.all(),
        name <- mod.__schema__(:associations),
        %Ecto.Association.BelongsTo{owner_key: key, related: related} <-
          [mod.__schema__(:association, name)],
        do: {mod.__schema__(:source), Atom.to_string(key), related.__schema__(:source)}
  end

  defp single_column_fks do
    %{rows: rows} =
      Repo.query!("""
      SELECT c.conname, t.relname, a.attname, rt.relname
        FROM pg_constraint c
        JOIN pg_namespace n ON n.oid = c.connamespace
        JOIN pg_class t ON t.oid = c.conrelid
        JOIN pg_class rt ON rt.oid = c.confrelid
        JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
       WHERE c.contype = 'f' AND n.nspname = 'test' AND cardinality(c.conkey) = 1
         AND NOT t.relispartition
      """)

    for [name, table, column, ref] <- rows, do: {name, table, column, ref}
  end

  defp sorted_column(sql) do
    %{rows: rows} = Repo.query!(sql)
    rows |> List.flatten() |> Enum.sort()
  end
end
