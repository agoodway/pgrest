defmodule PgRest.RegistryTest do
  use ExUnit.Case

  alias PgRest.Registry
  alias PgRest.Registry.Snapshot

  setup do
    start_supervised!(
      {Registry, modules: [PgRest.Test.Order, PgRest.Test.Product, PgRest.Test.NonResource]}
    )

    :ok
  end

  describe "get_resource/1" do
    test "finds resource by table name" do
      assert {:ok, config} = Registry.get_resource("orders")
      assert config.module == PgRest.Test.Order
      assert config.table == "orders"
      assert :status in config.fields
    end

    test "finds resource by module" do
      assert {:ok, config} = Registry.get_resource(PgRest.Test.Product)
      assert config.module == PgRest.Test.Product
      assert config.table == "products"
    end

    test "returns error for unknown table" do
      assert {:error, :not_found} = Registry.get_resource("nonexistent")
    end

    test "returns error for non-resource module" do
      assert {:error, :not_found} = Registry.get_resource(PgRest.Test.NonResource)
    end
  end

  describe "list_resources/0" do
    test "returns all registered resources" do
      resources = Registry.list_resources()
      tables = Enum.map(resources, & &1.table)
      assert "orders" in tables
      assert "products" in tables
    end
  end

  describe "snapshot/1" do
    test "holds the resources keyed by {schema, table} and the single default schema" do
      assert {:ok, %Snapshot{} = snap} = Registry.snapshot()
      assert snap.name == Registry
      assert snap.schemas == ["public"]
      assert snap.default_schema == "public"
      assert %{module: PgRest.Test.Order} = snap.resources[{"public", "orders"}]
      assert %{table: "products"} = snap.by_module[PgRest.Test.Product]
      assert snap.functions == %{}
    end

    test "is PGRST002 (503) for a registry that is not running" do
      assert {:error,
              %PgRest.Error{
                status: 503,
                code: "PGRST002",
                message: "Could not query the database for the schema cache. Retrying."
              }} = Registry.snapshot(:missing)
    end

    test "is gone once the registry stops" do
      stop_supervised!(Registry)
      assert {:error, %PgRest.Error{code: "PGRST002"}} = Registry.snapshot()
    end

    test "reload/1 republishes the snapshot" do
      assert {:ok, before} = Registry.snapshot()
      assert :ok = Registry.reload()
      assert {:ok, again} = Registry.snapshot()
      assert again.generation > before.generation
      assert %{again | generation: before.generation} == before
      assert {:error, _} = Registry.reload(:missing)
    end
  end
end

defmodule PgRest.RegistryNamedTest do
  use ExUnit.Case

  alias PgRest.Compat.{Resources, Supabase}
  alias PgRest.Registry
  alias PgRest.Registry.Snapshot

  @supabase_schemas ["public", "personal"]

  test "two named registries do not see each other's tables" do
    start_supervised!({Registry, name: :reg_a, modules: [Resources.Clients]})
    start_supervised!({Registry, name: :reg_b, modules: [Resources.Items]})

    assert {:ok, a} = Registry.snapshot(:reg_a)
    assert {:ok, b} = Registry.snapshot(:reg_b)
    assert a.name == :reg_a
    assert {:ok, %{module: Resources.Clients}} = Snapshot.fetch_resource(a, "test", "clients")
    assert {:error, %{code: "PGRST205"}} = Snapshot.fetch_resource(a, "test", "items")
    assert {:ok, %{module: Resources.Items}} = Snapshot.fetch_resource(b, "test", "items")
    assert {:error, %{code: "PGRST205"}} = Snapshot.fetch_resource(b, "test", "clients")
  end

  test "a second registry starts next to the default one" do
    start_supervised!({Registry, modules: [Resources.Clients]})
    start_supervised!({Registry, name: :second, modules: [Resources.Items]})

    assert {:ok, %{module: Resources.Clients}} = Registry.get_resource("clients")
    assert {:ok, _} = Registry.snapshot(:second)
  end

  test "the same table name in two schemas coexists, keyed by {schema, table}" do
    start_supervised!(
      {Registry, name: :supa, modules: Supabase.Resources.all(), schemas: @supabase_schemas}
    )

    assert {:ok, snap} = Registry.snapshot(:supa)
    assert snap.schemas == @supabase_schemas
    assert snap.default_schema == "public"

    assert {:ok, %{module: Supabase.Personal.User}} =
             Snapshot.fetch_resource(snap, "personal", "users")

    assert {:ok, %{module: Supabase.User}} = Snapshot.fetch_resource(snap, "public", "users")
  end

  test "a miss is PGRST205 naming the requested schema" do
    start_supervised!(
      {Registry, name: :supa, modules: Supabase.Resources.all(), schemas: @supabase_schemas}
    )

    {:ok, snap} = Registry.snapshot(:supa)

    assert {:error,
            %PgRest.Error{
              status: 404,
              code: "PGRST205",
              message: "Could not find the table 'personal.channels' in the schema cache"
            }} = Snapshot.fetch_resource(snap, "personal", "channels")

    assert {:error, %{hint: "Perhaps you meant the table 'public.channels'"}} =
             Snapshot.fetch_resource(snap, "public", "channel")
  end

  test "resources in two schemas without :schemas raise" do
    assert_raise ArgumentError,
                 ~r/resources span schemas \["personal", "public"\]; pass :schemas/,
                 fn ->
                   Registry.start_link(name: :supa, modules: Supabase.Resources.all())
                 end
  end

  test "a resource outside :schemas raises" do
    assert_raise ArgumentError, ~r/schema "personal".*not in :schemas/, fn ->
      Registry.start_link(name: :supa, modules: Supabase.Resources.all(), schemas: ["public"])
    end
  end

  test "functions/3 is empty until functions are introspected" do
    start_supervised!({Registry, name: :reg_a, modules: [Resources.Clients]})
    {:ok, snap} = Registry.snapshot(:reg_a)
    assert Snapshot.functions(snap, "test", "anything") == []
  end
end

defmodule PgRest.RegistryGraphTest do
  use ExUnit.Case

  alias PgRest.Compat.Resources
  alias PgRest.ResourceTest.{ScopedNoPk, ScopedNoPkNoKey}
  alias PgRest.SchemaGraph

  test "stores the relationship graph" do
    start_supervised!({PgRest.Registry, modules: Resources.all()})

    assert %SchemaGraph{} = graph = PgRest.Registry.graph()

    assert {:ok, %{kind: :o2m}} =
             SchemaGraph.resolve(graph, Resources.Clients, "projects", nil)
  end

  test "a custom-scoped resource with neither primary key nor unique_key raises" do
    assert_raise ArgumentError, ~r/ScopedNoPkNoKey.*unique_key/, fn ->
      PgRest.Registry.start_link(modules: [ScopedNoPkNoKey])
    end
  end

  test "a custom-scoped resource with a unique_key registers" do
    start_supervised!({PgRest.Registry, modules: [ScopedNoPk]})

    assert {:ok, %{unique_key: [:name], custom_scope?: true}} =
             PgRest.Registry.get_resource(ScopedNoPk)
  end

  test "two resources with the same schema and table raise at start" do
    assert_raise ArgumentError, ~r/"test"\."clients"/, fn ->
      PgRest.Registry.start_link(
        modules: [Resources.Clients, PgRest.Test.SecurityResources.PkHidden]
      )
    end
  end

  test "an unknown option raises" do
    assert_raise ArgumentError, ~r/unknown PgRest.Registry options: \[:bogus\]/, fn ->
      PgRest.Registry.start_link(modules: [Resources.Clients], bogus: true)
    end
  end
end

defmodule PgRest.RegistryJunctionTest do
  use ExUnit.Case

  alias PgRest.GraphTest.{ExplA, ExplAUnregisteredTarget, ExplB, ExplJ}
  alias PgRest.SQL.ScopedSource
  alias PgRest.StatementCache

  test "an explicit m2m whose junction is not registered raises at start" do
    assert_raise ArgumentError, ~r/no registered resource/, fn ->
      PgRest.Registry.start_link(modules: [ExplA, ExplB])
    end
  end

  test "an explicit relationship to an unregistered target raises at start" do
    assert_raise ArgumentError, ~r/not a registered resource/, fn ->
      PgRest.Registry.start_link(modules: [ExplAUnregisteredTarget])
    end
  end

  test "starts when the junction is registered" do
    start_supervised!({PgRest.Registry, modules: [ExplA, ExplB, ExplJ]})

    assert {:ok, %{kind: :m2m}} =
             PgRest.SchemaGraph.resolve(PgRest.Registry.graph(), ExplA, "expl_b", nil)
  end

  test "the shared caches belong to PgRest.Cache, not to any registry" do
    owner = Process.whereis(PgRest.Cache)
    assert is_pid(owner)

    start_supervised!({PgRest.Registry, modules: [ExplB]})
    stop_supervised!(PgRest.Registry)

    assert :ets.info(ScopedSource.cache_table(), :owner) == owner
    assert :ets.info(StatementCache, :owner) == owner
  end
end
