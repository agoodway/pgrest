defmodule PgRest.AggregatesTest do
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [json: 1, register: 1, request: 5]

  alias PgRest.AST.{Aggregate, Field}
  alias PgRest.Compat.{Functions, Repo, Resources}
  alias PgRest.SQL.Aggregate, as: AggregateSQL
  alias PgRest.SQL.Builder
  alias PgRest.Test.TelemetryProbe

  defmodule Clients do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
      has_many(:projects, PgRest.AggregatesTest.Projects, foreign_key: :client_id)
    end
  end

  # Only client 1's projects (2 of the fixture's 5) are in scope.
  defmodule Projects do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      belongs_to(:client, PgRest.AggregatesTest.Clients, type: :integer)
    end

    @impl PgRest.Resource
    def scope(query, _context), do: where(query, [p], p.client_id == 1)
  end

  # A to-one spread target with `after_load/2`: PgRest plans the spread as a merge.
  defmodule LoadedClients do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, after_load: true

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def after_load(row, _context), do: row
  end

  defmodule LoadedProjects do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      belongs_to(:client, PgRest.AggregatesTest.LoadedClients, type: :integer)
    end
  end

  # Tasks reach clients through projects: two nested to-one spreads.
  defmodule NestedTasks do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "tasks" do
      field(:name, :string)
      belongs_to(:project, PgRest.AggregatesTest.LoadedProjects, type: :integer)
    end
  end

  # `after_load/2` on the outer spread's resource; its nested clients spread is plain.
  defmodule MergedProjects do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, after_load: true

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      belongs_to(:client, PgRest.AggregatesTest.Clients, type: :integer)
    end

    @impl PgRest.Resource
    def after_load(row, _context), do: row
  end

  defmodule MergedTasks do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "tasks" do
      field(:name, :string)
      belongs_to(:project, PgRest.AggregatesTest.MergedProjects, type: :integer)
    end
  end

  defp get(path, opts \\ [aggregates: true]), do: request("GET", path, nil, [], opts)

  describe "select_item/4" do
    defp render(agg, opts \\ []) do
      {sql, builder} = AggregateSQL.select_item(agg, "t", Builder.new(), opts)
      {IO.iodata_to_binary(sql), Builder.param_count(builder)}
    end

    test "an input cast and a result cast both go through Builder.cast/2" do
      agg = %Aggregate{
        fun: :avg,
        field: %Field{name: "price"},
        input_cast: "numeric",
        cast: "int"
      }

      assert render(agg) == {~S|CAST(avg(CAST("t"."price" AS numeric)) AS int) AS "avg"|, 0}
    end

    test "count() counts rows and takes its alias" do
      assert render(%Aggregate{fun: :count}) == {~S|count(*) AS "count"|, 0}
      assert render(%Aggregate{fun: :count, alias: "n"}) == {~S|count(*) AS "n"|, 0}
    end

    test "a JSON path key is a bind parameter; a path on a non-JSON column reads to_jsonb" do
      agg = %Aggregate{
        fun: :sum,
        field: %Field{name: "doc", json_path: [double_arrow: "key"]},
        input_cast: "integer"
      }

      assert render(agg, column_types: %{"doc" => "jsonb"}) ==
               {~S|sum(CAST("t"."doc" ->> $1 AS integer)) AS "sum"|, 1}

      assert render(agg, column_types: %{"doc" => "text"}) ==
               {~S|sum(CAST(to_jsonb("t"."doc") ->> $1 AS integer)) AS "sum"|, 1}
    end

    test "a cast that the grammar would refuse raises" do
      assert_raise ArgumentError, fn -> render(%Aggregate{fun: :count, cast: "int)"}) end
    end
  end

  describe "scope (Review Focus 3)" do
    setup do
      register([Clients, Projects])
      :ok
    end

    test "count() counts only the rows in scope" do
      conn = get("/projects?select=count()")

      assert conn.status == 200
      assert json(conn) == [%{"count" => 2}]
    end

    test "an embedded count() counts only the child rows in scope" do
      conn = get("/clients?select=name,projects(count())&order=id")

      assert conn.status == 200

      assert json(conn) == [
               %{"name" => "Microsoft", "projects" => [%{"count" => 2}]},
               %{"name" => "Apple", "projects" => [%{"count" => 0}]}
             ]
    end

    test "several aggregates in one embed read only the rows in scope" do
      conn = get("/clients?select=name,projects(count:id.count(),total:id.sum())&order=id")

      assert json(conn) == [
               %{"name" => "Microsoft", "projects" => [%{"count" => 2, "total" => 3}]},
               %{"name" => "Apple", "projects" => [%{"count" => 0, "total" => nil}]}
             ]
    end

    test "aggregates are off by default: PGRST123" do
      conn = get("/projects?select=count()", [])

      assert conn.status == 400
      assert %{"code" => "PGRST123"} = json(conn)
    end
  end

  describe "spreads over after_load/2 resources" do
    setup do
      register([LoadedClients, LoadedProjects])
      :ok
    end

    test "an aggregate in a to-one spread with after_load/2 fails closed with PGRST127" do
      conn = get("/projects?select=...clients(n:id.count())")

      assert conn.status == 400

      assert json(conn) == %{
               "code" => "PGRST127",
               "message" => "Feature not implemented",
               "details" =>
                 "Aggregates are not implemented for spreads of resources with after_load/2.",
               "hint" => nil
             }
    end

    test "an aggregate beside such a spread still groups by it" do
      conn = get("/projects?select=c:count(),...clients(name)")

      assert conn.status == 200

      assert MapSet.new(json(conn)) ==
               MapSet.new([
                 %{"c" => 1, "name" => nil},
                 %{"c" => 2, "name" => "Apple"},
                 %{"c" => 2, "name" => "Microsoft"}
               ])
    end
  end

  describe "spreads over after_load/2 resources, nested" do
    @psg "Aggregates are not implemented for spreads of resources with after_load/2."

    test "an aggregate hoisted from a nested to-one spread under an after_load/2 spread is PGRST127" do
      register([MergedTasks, MergedProjects, Clients])
      conn = get("/tasks?select=...projects(...clients(n:id.count()))")

      assert conn.status == 400

      assert %{"code" => "PGRST127", "message" => "Feature not implemented", "details" => @psg} =
               json(conn)
    end

    test "after_load/2 on a deeper resource of the spread's subtree is PGRST127" do
      register([NestedTasks, LoadedProjects, LoadedClients])
      conn = get("/tasks?select=...projects(n:id.count(),...clients(name))")

      assert conn.status == 400

      assert %{"code" => "PGRST127", "message" => "Feature not implemented", "details" => @psg} =
               json(conn)
    end
  end

  describe "GROUP BY" do
    test "positions follow the select list: columns, casts, embeds and spread columns" do
      start_supervised!({PgRest.Registry, modules: Resources.all()})
      TelemetryProbe.attach([:pgrest, :query, :stop])

      path =
        "/processes?select=name,id::text,cnt:count(),factories(name)," <>
          "...process_categories(cat:name),...process_costs(cost.sum())"

      assert %{status: 200} = request("GET", path, nil, [], aggregates: true)

      [sql] =
        for {_event, _measurements, %{sql: sql}} <- TelemetryProbe.drain(),
            String.contains?(sql, "GROUP BY"),
            do: sql

      assert sql =~ ~r/ GROUP BY 1, 2, 4, 5(?![,0-9])/
    end
  end

  describe "RPC" do
    test "aggregates over an RPC result call the function once, counted or not" do
      start_supervised!(
        {PgRest.Registry,
         modules: Resources.all(), introspect: [repo: Repo, only: Functions.test_functions()]}
      )

      TelemetryProbe.attach([:pgrest, :query, :stop])
      path = "/rpc/getallprojects?select=client_id,id.max()&order=client_id&limit=2"
      conn = request("GET", path, nil, [{"prefer", "count=exact"}], aggregates: true)

      assert conn.status == 206
      assert json(conn) == [%{"client_id" => 1, "max" => 2}, %{"client_id" => 2, "max" => 4}]

      [sql] =
        for {_event, _measurements, %{sql: sql}} <- TelemetryProbe.drain(),
            String.contains?(sql, "getallprojects"),
            do: sql

      assert sql |> String.split(~S|"getallprojects"(|) |> length() == 2
    end
  end
end
