defmodule PgRest.SchemaGraphTest do
  use ExUnit.Case, async: true

  alias PgRest.Compat.{Resources, Scenario}
  alias PgRest.{Error, GraphTest, SchemaGraph}
  alias PgRest.SchemaGraph.Relationship

  setup_all do
    %{graph: SchemaGraph.build(Resources.all())}
  end

  defp resolve!(graph, source, name, hint \\ nil) do
    assert {:ok, %Relationship{} = rel} =
             SchemaGraph.resolve(graph, Module.concat(Resources, source), name, hint)

    rel
  end

  describe "resolve/4 kinds" do
    test "clients -> projects is one-to-many", %{graph: graph} do
      rel = resolve!(graph, Clients, "projects")

      assert %{
               kind: :o2m,
               constraint: "client",
               source_columns: ["id"],
               target_columns: ["client_id"]
             } = rel

      assert rel.assoc == :projects
    end

    test "projects -> clients is many-to-one", %{graph: graph} do
      assert %{kind: :m2o, source_columns: ["client_id"], target_columns: ["id"]} =
               resolve!(graph, Projects, "clients")
    end

    test "users -> tasks is many-to-many through users_tasks", %{graph: graph} do
      rel = resolve!(graph, Users, "tasks")

      assert %{kind: :m2m, source_columns: ["id"], target_columns: ["id"]} = rel

      assert rel.assoc == :tasks

      assert %{
               module: Resources.UsersTasks,
               table: "users_tasks",
               schema: "test",
               source_columns: ["user_id"],
               target_columns: ["task_id"],
               constraints: {"users_tasks_user_id_fkey", "users_tasks_task_id_fkey"}
             } = rel.junction
    end

    test "students -> students_info is one-to-one from the explicit composite declaration", %{
      graph: graph
    } do
      assert %{kind: :o2o, source_columns: ["code", "id"], target_columns: ["code", "id"]} =
               resolve!(graph, Students, "students_info")

      assert %{kind: :o2o} = resolve!(graph, StudentsInfo, "students")
    end

    test "has_one pairs are one-to-one on both sides", %{graph: graph} do
      assert %{kind: :o2o, assoc: :capital} = resolve!(graph, Country, "capital")
      assert %{kind: :o2o, assoc: :country} = resolve!(graph, Capital, "country")
    end

    test "relationships are discovered from the other resource's belongs_to", %{graph: graph} do
      assert %{kind: :o2m, assoc: nil, constraint: "users_tasks_user_id_fkey"} =
               resolve!(graph, Users, "users_tasks")

      assert %{kind: :o2m, source_columns: ["id"], target_columns: ["parent_id"]} =
               resolve!(graph, Entities, "child_entities")
    end

    test "association names resolve when nothing else matches", %{graph: graph} do
      assert %{kind: :m2o, source_columns: ["billing_address_id"]} =
               resolve!(graph, Orders, "billing_address")
    end
  end

  describe "resolve/4 disambiguation" do
    test "orders -> addresses without a hint is ambiguous", %{graph: graph} do
      assert {:error, %Error{status: 300, code: "PGRST201", details: details}} =
               SchemaGraph.resolve(graph, Resources.Orders, "addresses", nil)

      assert length(details) == 2
    end

    test "a column hint picks one relationship", %{graph: graph} do
      assert %{kind: :m2o, constraint: "billing", source_columns: ["billing_address_id"]} =
               resolve!(graph, Orders, "addresses", "billing_address_id")
    end

    test "a constraint hint picks one relationship", %{graph: graph} do
      assert %{constraint: "shipping"} = resolve!(graph, Orders, "addresses", "shipping")
    end

    test "family_tree -> family_tree with hint parent is the one-to-many", %{graph: graph} do
      assert %{kind: :o2m, source_columns: ["id"], target_columns: ["parent"]} =
               resolve!(graph, FamilyTree, "family_tree", "parent")
    end

    test "family_tree self relationship resolves without a hint by table name or column", %{
      graph: graph
    } do
      assert %{kind: :o2m} = resolve!(graph, FamilyTree, "family_tree")
      assert %{kind: :m2o} = resolve!(graph, FamilyTree, "parent")
    end

    test "organizations -> organizations is ambiguous without a hint", %{graph: graph} do
      assert {:error, %Error{code: "PGRST201"}} =
               SchemaGraph.resolve(graph, Resources.Organizations, "organizations", nil)

      assert %{kind: :o2m, target_columns: ["auditor"]} =
               resolve!(graph, Organizations, "organizations", "auditor")
    end

    test "a junction table hint selects the many-to-many", %{graph: graph} do
      assert %{kind: :m2m, junction: %{table: "touched_files"}} =
               resolve!(graph, UsersTasks, "files", "touched_files")
    end
  end

  defp resolve_graph!(graph, source, name, hint) do
    assert {:ok, rel} = SchemaGraph.resolve(graph, source, name, hint)
    rel
  end

  describe "resolve/4 junctions (PostgREST addM2MRels)" do
    test "files -> users_tasks is derived from the touched_files junction", %{graph: graph} do
      assert %{kind: :m2m, source_columns: ["project_id", "filename"], assoc: nil} =
               rel = resolve!(graph, Files, "users_tasks")

      assert rel.junction.module == Resources.TouchedFiles
      assert rel.junction.constraints == {"fk_upload", "fk_users_tasks"}
      assert %{kind: :m2m} = resolve!(graph, UsersTasks, "files")
    end

    test "a junction with only belongs_to and a composite primary key resolves, both ways", %{
      graph: graph
    } do
      assert %{kind: :m2m, junction: %{module: Resources.AmbigAb}} =
               resolve!(graph, AmbigA, "ambig_b", "ambig_ab")

      assert %{kind: :m2m} = resolve!(graph, AmbigB, "ambig_a", "ambig_ab")
    end

    test "a direct foreign key plus a junction path to the same table is ambiguous", %{
      graph: graph
    } do
      assert {:error,
              %Error{
                status: 300,
                code: "PGRST201",
                details: [%{"cardinality" => "one-to-many"}, %{"cardinality" => "many-to-many"}]
              }} =
               SchemaGraph.resolve(graph, Resources.AmbigA, "ambig_b", nil)

      assert %{kind: :o2m} = resolve!(graph, AmbigA, "ambig_b", "ambig_b_a_id_fkey")
    end

    test "a table with a surrogate primary key is not a junction", %{graph: graph} do
      # comments references users and users_tasks but its key is a surrogate id.
      assert %{kind: :o2m} = resolve!(graph, Users, "users_tasks")
    end

    test "explicit m2m through a registered junction yields both directions" do
      graph = SchemaGraph.build([GraphTest.ExplA, GraphTest.ExplB, GraphTest.ExplJ])

      assert {:ok,
              %{kind: :m2m, assoc: :bs, source_columns: ["id"], target_columns: ["id"]} = forward} =
               SchemaGraph.resolve(graph, GraphTest.ExplA, "expl_b", nil)

      assert %{module: GraphTest.ExplJ, source_columns: ["a_id"], target_columns: ["b_id"]} =
               forward.junction

      assert {:ok,
              %{kind: :m2m, junction: %{constraints: {"expl_j_b_id_fkey", "expl_j_a_id_fkey"}}}} =
               SchemaGraph.resolve(graph, GraphTest.ExplB, "expl_a", nil)
    end

    test "explicit m2m without a registered junction raises" do
      assert_raise ArgumentError, ~r/expl_j.*no registered resource/, fn ->
        SchemaGraph.build([GraphTest.ExplA, GraphTest.ExplB])
      end
    end

    test "an explicit declaration with an unregistered target raises" do
      assert_raise ArgumentError, ~r/ExplB.*not a registered resource/, fn ->
        SchemaGraph.build([GraphTest.ExplAUnregisteredTarget])
      end
    end

    test "different constraint names on the same columns are two relationships" do
      graph = SchemaGraph.build([GraphTest.ConflParent, GraphTest.ConflKid])

      assert {:error, %Error{code: "PGRST201", details: [_, _]}} =
               SchemaGraph.resolve(graph, GraphTest.ConflParent, "confl_kid", nil)

      assert %{kind: :o2m} = resolve_graph!(graph, GraphTest.ConflParent, "confl_kid", "from_kid")
    end

    test "an explicit m2m over a derivable junction resolves both ways, once" do
      graph = SchemaGraph.build([GraphTest.DerivA, GraphTest.DerivB, GraphTest.DerivJ])

      assert {:ok, %{kind: :m2m, assoc: :bs}} =
               SchemaGraph.resolve(graph, GraphTest.DerivA, "deriv_b", nil)

      assert {:ok, %{kind: :m2m}} = SchemaGraph.resolve(graph, GraphTest.DerivB, "deriv_a", nil)
    end

    test "the same explicit m2m declared from both sides resolves" do
      graph = SchemaGraph.build([GraphTest.BothC, GraphTest.BothD, GraphTest.BothJ])

      assert {:ok, %{kind: :m2m, assoc: :ds}} =
               SchemaGraph.resolve(graph, GraphTest.BothC, "both_d", nil)

      assert {:ok, %{kind: :m2m, assoc: :cs}} =
               SchemaGraph.resolve(graph, GraphTest.BothD, "both_c", nil)
    end

    test "a many_to_many alias is skipped when several derived m2m share its junction" do
      graph = SchemaGraph.build([GraphTest.SelfA, GraphTest.SelfJ])
      m2ms = for %{kind: :m2m} = rel <- graph.rels[GraphTest.SelfA], do: rel

      assert length(m2ms) == 2
      assert Enum.all?(m2ms, &(&1.assoc == nil))
    end
  end

  describe "resolve/4 composite keys" do
    test "files -> touched_files carries both key columns in constraint order", %{graph: graph} do
      assert %{
               kind: :o2m,
               constraint: "fk_upload",
               source_columns: ["project_id", "filename"],
               target_columns: ["project_id", "filename"]
             } = resolve!(graph, Files, "touched_files")
    end

    test "a single component of a composite key is not a relationship", %{graph: graph} do
      assert {:error, %Error{code: "PGRST200"}} =
               SchemaGraph.resolve(graph, Resources.Files, "touched_files", "project_id")

      assert {:error, %Error{code: "PGRST200"}} =
               SchemaGraph.resolve(graph, Resources.Files, "touched_files", "filename")
    end

    test "comments -> users_tasks is the composite many-to-one", %{graph: graph} do
      assert %{
               kind: :m2o,
               constraint: "comments_task_id_fkey",
               source_columns: ["task_id", "user_id"]
             } =
               resolve!(graph, Comments, "users_tasks")
    end
  end

  describe "resolve/4 errors" do
    test "clients -> nope is PGRST200", %{graph: graph} do
      assert {:error, %Error{status: 400, code: "PGRST200"}} =
               SchemaGraph.resolve(graph, Resources.Clients, "nope", nil)
    end

    test "unrelated tables do not resolve", %{graph: graph} do
      assert {:error, %Error{code: "PGRST200"}} =
               SchemaGraph.resolve(graph, Resources.Clients, "tasks", nil)
    end
  end

  describe "bodies equal the PostgREST recordings" do
    @expected Scenario.read_expected("embed_errors")

    # scenario id => {source resource, embed name, hint}
    @errors %{
      "embed_errors/ambiguous-two-fks" => {Orders, "addresses", nil},
      "embed_errors/ambiguous-direct-and-junction" => {AmbigA, "ambig_b", nil},
      "embed_errors/ambiguous-self-two-fks" => {Organizations, "organizations", nil},
      "embed_errors/no-relationship" => {Clients, "nope", nil},
      "embed_errors/no-relationship-typo-child" => {Clients, "project", nil},
      "embed_errors/no-relationship-unknown-hint" => {Projects, "clients", "nope"},
      "embed_errors/no-relationship-unrelated-table" => {Clients, "tasks", nil},
      "embed_errors/no-relationship-leaf-table" => {Items, "nope", nil}
    }

    for {id, {source, name, hint}} <- @errors do
      test id, %{graph: graph} do
        recorded = Map.fetch!(@expected, unquote(id))
        source = Module.concat(Resources, unquote(source))

        assert {:error, %Error{status: status} = error} =
                 SchemaGraph.resolve(graph, source, unquote(name), unquote(hint))

        assert status == recorded["status"]
        assert Jason.decode!(Jason.encode!(Error.to_body(error))) == recorded["body"]
      end
    end
  end

  describe "build/1" do
    test "ignores associations to modules that are not part of the graph" do
      graph = SchemaGraph.build([Resources.Clients])

      assert graph.rels == %{}
      assert graph.tables == %{Resources.Clients => {"test", "clients"}}
    end
  end
end
