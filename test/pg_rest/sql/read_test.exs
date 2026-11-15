defmodule PgRest.SQL.ReadTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias PgRest.Compat.Repo
  alias PgRest.Compat.Resources, as: R
  alias PgRest.Error.Translate
  alias PgRest.{MediaType, Plan, Planner, Request, SchemaGraph}
  alias PgRest.SQL.Read
  alias PgRest.Test.ReadResources, as: T

  @graph SchemaGraph.build(R.all())
  @scoped_graph SchemaGraph.build([T.Clients, T.Projects])

  defp statement(path, resource, context \\ %{}, opts \\ [], headers \\ []) do
    conn =
      Enum.reduce(headers, conn("GET", path), fn {k, v}, c ->
        Plug.Conn.put_req_header(c, k, v)
      end)

    {:ok, request} = Request.from_conn(conn, [])
    context = Map.merge(%{repo: Repo, graph: @graph}, context)
    assert {:ok, plan} = Planner.plan_read(request, resource, context)
    media = Keyword.get(opts, :media, MediaType.json())
    Read.statement(Plan.Read.put_media(plan, media), context)
  end

  defp run({sql, params}) do
    %{rows: [[total, page_total, body, nil, nil]]} = Repo.query!(sql, params, log: false)
    {total, page_total, Jason.decode!(body)}
  end

  defp rows(path, resource, context \\ %{}) do
    {_total, _page_total, body} = run(statement(path, resource, context))
    body
  end

  describe "shape" do
    test "the statement selects the response GUC columns after the body" do
      {sql, params} = statement("/projects?select=id", T.Projects)
      assert %{columns: columns} = Repo.query!(sql, params, log: false)
      assert Enum.take(columns, -2) == ["response_headers", "response_status"]
    end

    test "an embed tree is one statement with one lateral per embed" do
      {sql, _params} = statement("/clients?select=id,projects(id,tasks(id))", R.Clients)
      assert length(Regex.scan(~r/JOIN LATERAL/, sql)) == 2
      assert length(Regex.scan(~r/\bWITH pgrst_source AS\b/, sql)) == 1
      assert sql =~ "coalesce(json_agg(_postgrest_t.*), '[]')::text AS body"
    end

    test "executing it returns the nested rows" do
      [first | _] = rows("/clients?select=id,projects(id,tasks(id))&order=id", R.Clients)
      assert %{"id" => 1, "projects" => [%{"id" => 1, "tasks" => [%{"id" => 1}, _]} | _]} = first
    end

    test "limit and offset are bind parameters, so paging shares one SQL text" do
      {a, [_ | _] = params_a} = statement("/items?limit=1&offset=2", R.Items)
      {b, params_b} = statement("/items?limit=3&offset=7", R.Items)
      assert a == b
      assert "1" in params_a and "2" in params_a
      assert "3" in params_b and "7" in params_b
      assert a =~ "LIMIT $1::text::bigint OFFSET $2::text::bigint"
    end

    test "!inner on a to-many embed is an INNER JOIN LATERAL on a non-null aggregate" do
      {sql, _} = statement("/clients?select=id,projects!inner(id)", R.Clients)
      assert sql =~ "INNER JOIN LATERAL"
      assert sql =~ "IS NOT NULL"
      refute sql =~ "<> '[]'"
    end

    test "COALESCE(..., '[]') sits in the outer select list, outside the lateral" do
      {sql, _} = statement("/clients?select=id,projects(id)", R.Clients)
      [outer, lateral] = String.split(sql, "LEFT JOIN LATERAL", parts: 2)
      assert outer =~ "COALESCE("
      refute lateral =~ "COALESCE("
    end

    test "to-one embeds use row_to_json on a LEFT JOIN LATERAL" do
      {sql, _} = statement("/projects?select=id,clients(id)", R.Projects)
      assert sql =~ "row_to_json("
      assert sql =~ "LEFT JOIN LATERAL"
    end

    test "aliases of repeated and self-referencing embeds do not collide" do
      [row] =
        rows(
          "/family_tree?id=eq.1&select=a:family_tree!parent(id),b:family_tree!parent(id)",
          R.FamilyTree
        )

      assert row["a"] == row["b"]
      assert row["a"] != []
    end

    test "select casts go through Builder.cast and JSON keys are bound" do
      {sql, params} =
        statement("/complex_items?id=eq.1&select=settings->foo->>bar::text", R.ComplexItems)

      assert sql =~ "CAST("
      assert "foo" in params and "bar" in params
      refute sql =~ "'foo'"
    end
  end

  describe "empty embeds" do
    test "to-one with no match is null, to-many is []" do
      assert [%{"id" => 5, "clients" => nil}] =
               rows("/projects?id=eq.5&select=id,clients(id)", R.Projects)

      assert [%{"id" => 5, "tasks" => []}] =
               rows("/projects?id=eq.5&select=id,tasks(id)", R.Projects)
    end

    test "!inner with no match drops the parent" do
      assert [] == rows("/projects?id=eq.5&select=id,clients!inner(id)", R.Projects)
      assert [] == rows("/projects?id=eq.5&select=id,tasks!inner(id)", R.Projects)
    end

    test "a spread of a null to-one yields null columns" do
      assert [%{"id" => 5, "name" => nil}] =
               rows("/projects?id=eq.5&select=id,...clients(name)", R.Projects)
    end

    test "a to-many spread with no rows yields empty arrays" do
      assert [%{"id" => 5, "name" => []}] =
               rows("/projects?id=eq.5&select=id,...tasks(name)", R.Projects)
    end
  end

  describe "scope applies to embeds" do
    test "embedded rows outside the scope are absent" do
      context = %{graph: @scoped_graph}
      body = rows("/clients?select=id,projects(id,name)&order=id", T.Clients, context)

      names = body |> Enum.flat_map(& &1["projects"]) |> Enum.map(& &1["name"])
      assert names != []
      assert Enum.all?(names, &String.starts_with?(&1, "Windows"))
    end

    test "the scope also bounds an inner embed" do
      context = %{graph: @scoped_graph}
      # client 2 only has projects outside the scope
      ids = rows("/clients?select=id,projects!inner(id)&order=id", T.Clients, context)
      assert Enum.map(ids, & &1["id"]) == [1]
    end
  end

  describe "per-parent limits" do
    test "projects.limit=1 returns at most one project per client" do
      body = rows("/clients?select=id,projects(id)&projects.limit=1&order=id", R.Clients)
      assert Enum.all?(body, &(length(&1["projects"]) <= 1))
      assert Enum.any?(body, &(length(&1["projects"]) == 1))
    end

    test "max_limit clamps the root and every embed, to-one and m2m included" do
      ctx = %{max_limit: 1}
      body = rows("/clients?select=*,projects(*,tasks(id))", R.Clients, ctx)
      assert length(body) == 1
      assert Enum.all?(body, &(length(&1["projects"]) <= 1))
      users = rows("/users?select=*,tasks(*)", R.Users, ctx)
      assert length(users) == 1 and Enum.all?(users, &(length(&1["tasks"]) <= 1))
    end

    test "the clamp is LEAST(request limit, max_limit) in SQL" do
      {sql, params} =
        statement("/clients?select=id,projects(id)&projects.limit=5", R.Clients, %{max_limit: 2})

      assert sql =~ "LIMIT LEAST($"
      assert "5" in params and "2" in params
      {sql, _} = statement("/clients?select=id", R.Clients, %{max_limit: 2})
      assert sql =~ "LIMIT $1::text::bigint"
      refute sql =~ "LEAST"
    end
  end

  describe "readable columns" do
    test "GET /accounts omits hashed_password" do
      [row | _] = rows("/accounts?order=id&limit=1", R.Accounts)
      refute Map.has_key?(row, "hashed_password")
      assert Map.has_key?(row, "email")
    end
  end

  describe "types follow the database column, not the field name" do
    test "source-renamed fields bind with their own column's type" do
      # request names are database columns: `client_id` is the field named `name`
      assert [%{"client_id" => 1}, %{"client_id" => 1}] =
               rows("/projects?select=client_id&client_id=in.(1)&order=id", T.Swapped, %{
                 graph: SchemaGraph.build([T.Swapped])
               })

      assert [%{"name" => "Windows 7"}] =
               rows("/projects?select=name&name=eq.Windows 7", T.Swapped, %{
                 graph: SchemaGraph.build([T.Swapped])
               })
    end
  end

  describe "count" do
    test "exact count without limits is the page total" do
      {sql, _} = statement("/items", R.Items, %{}, [], [{"prefer", "count=exact"}])
      refute sql =~ "pgrst_source_count"
      assert {15, 15, _} = run(statement("/items", R.Items, %{}, [], [{"prefer", "count=exact"}]))
    end

    test "exact count with a limit counts without limit and offset" do
      stmt =
        statement("/items?limit=2&offset=1&order=id", R.Items, %{}, [], [
          {"prefer", "count=exact"}
        ])

      assert {15, 2, _} = run(stmt)
      assert elem(stmt, 0) =~ "pgrst_source_count"
    end

    test "inner joins and null filters count the filtered parents" do
      headers = [{"prefer", "count=exact"}]

      assert {4, 2, _} =
               run(
                 statement(
                   "/projects?select=id,clients!inner(id)&limit=2&order=id",
                   R.Projects,
                   %{},
                   [],
                   headers
                 )
               )

      assert {4, 2, _} =
               run(
                 statement(
                   "/projects?select=id,clients()&clients=not.is.null&limit=2&order=id",
                   R.Projects,
                   %{},
                   [],
                   headers
                 )
               )
    end

    test "no count is a NULL total" do
      assert {nil, 15, _} = run(statement("/items", R.Items))
    end
  end

  describe "statement options" do
    test "the object media type unwraps a single row" do
      object = [media: %MediaType{kind: :object, raw: "application/vnd.pgrst.object+json"}]
      assert {_, 1, %{"id" => 1}} = run(statement("/items?id=eq.1", R.Items, %{}, object))
      assert {_, 0, nil} = run(statement("/items?id=eq.0", R.Items, %{}, object))
    end
  end

  describe "errors" do
    test "a malformed filter value is the recorded 22P02" do
      {sql, params} = statement("/items?id=eq.abc", R.Items)
      assert {:error, exception} = Repo.query(sql, params, log: false)
      error = Translate.from_exception(exception, :anon)

      assert %{
               status: 400,
               code: "22P02",
               message: ~s(invalid input syntax for type bigint: "abc")
             } = error
    end
  end

  describe "custom params" do
    test "a declared custom param goes through handle_param" do
      body =
        rows("/projects?select=id,name&q=indows&order=id", T.Searchable, %{
          graph: SchemaGraph.build([T.Searchable])
        })

      assert Enum.all?(body, &(&1["name"] =~ "indows"))
      assert body != []
    end
  end
end
