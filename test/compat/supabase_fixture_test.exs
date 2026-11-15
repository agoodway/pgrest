defmodule PgRest.Compat.SupabaseFixtureTest do
  use ExUnit.Case, async: false

  alias PgRest.Compat.{AuthenticatorRepo, Fixture, JWT, SupabaseRepo}
  alias PgRest.Compat.Supabase.Resources

  @schemas Fixture.schemas(:supabase)

  defp insert_message_and_rollback do
    Fixture.rolled_back_insert!(
      SupabaseRepo,
      "INSERT INTO public.messages (username, channel_id) VALUES ('supabot', 1) RETURNING id"
    )
  end

  describe "database" do
    test "supabase fixture loaded" do
      assert %{rows: [[5]]} = SupabaseRepo.query!("select count(*) from public.users")
      assert %{rows: [[_]]} = SupabaseRepo.query!("select count(*) from personal.users")
    end

    test "the authenticator can switch to every API role but holds no privileges itself" do
      assert %{rows: [[true, true, true]]} =
               AuthenticatorRepo.query!("""
               select pg_has_role('anon', 'member'),
                      pg_has_role('authenticated', 'member'),
                      pg_has_role('service_role', 'member')
               """)

      assert %{rows: [[false]]} =
               AuthenticatorRepo.query!("select has_table_privilege('public.users', 'select')")
    end

    test "anon sees no rls_notes" do
      SupabaseRepo.transaction(fn ->
        SupabaseRepo.query!("set local role anon")
        assert %{rows: []} = SupabaseRepo.query!("select * from public.rls_notes")
      end)
    end

    test "authenticated sees only the rows its sub owns" do
      SupabaseRepo.transaction(fn ->
        SupabaseRepo.query!("set local role authenticated")

        SupabaseRepo.query!("select set_config('request.jwt.claims', $1, true)", [
          ~s({"sub":"alice"})
        ])

        assert %{rows: [["a1"], ["a2"]]} =
                 SupabaseRepo.query!("select slug from public.rls_notes order by slug")
      end)
    end
  end

  describe "resources" do
    test "every table in public and personal has exactly one resource; every resource is a table or view" do
      relations = fn kinds ->
        %{rows: rows} =
          SupabaseRepo.query!(
            """
            SELECT n.nspname || '.' || c.relname FROM pg_class c
              JOIN pg_namespace n ON n.oid = c.relnamespace
             WHERE n.nspname = ANY($1) AND c.relkind = ANY($2::text[]::"char"[])
               AND NOT c.relispartition
            """,
            [@schemas, kinds]
          )

        rows |> List.flatten() |> MapSet.new()
      end

      tables = relations.(["r", "p"])
      tables_or_views = relations.(["r", "p", "v"])

      resources =
        for mod <- Resources.all(), do: mod.__schema__(:prefix) <> "." <> mod.__schema__(:source)

      assert resources == Enum.uniq(resources)
      resources = MapSet.new(resources)
      assert MapSet.subset?(tables, resources)
      assert MapSet.subset?(resources, tables_or_views)
    end

    test "every FK in public/personal is a relationship in the graph" do
      graph = PgRest.SchemaGraph.build(Resources.all())

      in_graph =
        for {_module, rels} <- graph.rels,
            rel <- rels,
            rel.kind != :m2m,
            into: MapSet.new(),
            do: rel.constraint

      %{rows: rows} =
        SupabaseRepo.query!(
          """
          SELECT c.conname FROM pg_constraint c
            JOIN pg_namespace n ON n.oid = c.connamespace
           WHERE c.contype = 'f' AND n.nspname = ANY($1) AND NOT c.conparentid > 0
          """,
          [@schemas]
        )

      assert rows != []
      assert for([name] <- rows, name not in in_graph, do: name) == []
    end

    test "every FK has a belongs_to association, including the cross-schema one" do
      associations =
        for mod <- Resources.all(),
            name <- mod.__schema__(:associations),
            %Ecto.Association.BelongsTo{owner_key: key, related: related} <-
              [mod.__schema__(:association, name)],
            into: MapSet.new() do
          {mod.__schema__(:prefix), mod.__schema__(:source), Atom.to_string(key),
           related.__schema__(:prefix), related.__schema__(:source)}
        end

      %{rows: rows} =
        SupabaseRepo.query!(
          """
          SELECT n.nspname, t.relname, a.attname, rn.nspname, rt.relname
            FROM pg_constraint c
            JOIN pg_namespace n ON n.oid = c.connamespace
            JOIN pg_class t ON t.oid = c.conrelid
            JOIN pg_class rt ON rt.oid = c.confrelid
            JOIN pg_namespace rn ON rn.oid = rt.relnamespace
            JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = c.conkey[1]
           WHERE c.contype = 'f' AND n.nspname = ANY($1) AND c.conparentid = 0
          """,
          [@schemas]
        )

      fks =
        for [schema, table, column, ref_schema, ref] <- rows,
            do: {schema, table, column, ref_schema, ref}

      assert {"personal", "user_notes", "author", "public", "users"} in fks
      assert for(fk <- fks, fk not in associations, do: fk) == []
    end
  end

  describe "sequences" do
    test "reset_sequences! restores the supabase baseline" do
      baseline = Fixture.sequence_baseline(:supabase)
      :ok = Fixture.reset_sequences!(baseline)
      id1 = insert_message_and_rollback()
      :ok = Fixture.reset_sequences!(baseline)
      assert insert_message_and_rollback() == id1
      :ok = Fixture.reset_sequences!(baseline)
    end
  end

  test "privileged_hello preserves the upstream SQL fixture and default volatility" do
    assert SupabaseRepo.query!("""
           SELECT l.lanname, p.provolatile::text, p.prosrc
           FROM pg_proc p JOIN pg_language l ON l.oid=p.prolang
           WHERE p.oid='public.privileged_hello(text)'::regprocedure
           """).rows == [["sql", "v", "\n  select 'Privileged hello to ' || $1;\n"]]
  end

  describe "postgrest_supabase" do
    @describetag :differential

    test "serves roles and RLS" do
      base = Fixture.postgrest_url(:supabase)
      assert %{status: 401, body: %{"code" => "42501"}} = Req.get!(base <> "/private_docs")
      token = JWT.sign(%{"role" => "authenticated", "sub" => "alice"})
      assert %{status: 200, body: [_, _]} = Req.get!(base <> "/rls_notes", auth: {:bearer, token})
    end

    test "load! returns only after the new schema cache is served" do
      marker = Fixture.last_reload_marker(:supabase)
      assert %{status: 200} = Req.get!(Fixture.postgrest_url(:supabase) <> "/" <> marker)
    end
  end
end
