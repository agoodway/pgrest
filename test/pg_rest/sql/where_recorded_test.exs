defmodule PgRest.SQL.WhereRecordedTest do
  # The Postgres errors raised by compiled filters must carry the same SQLSTATE, message and
  # hint as the recorded PostgREST responses (parity of bind typing, not only of rows).
  use ExUnit.Case, async: false

  alias PgRest.Catalog
  alias PgRest.Compat.{Repo, Scenario}
  alias PgRest.Grammar.Filter
  alias PgRest.SQL.{Builder, Where}

  @moduletag :capture_log

  @ids ~w(
    filters/json/double-arrow-then-arrow
    filters/json/huge-index
    filters/pattern/like-on-integer-column
    filters/pattern/like-any-on-integer-column
    filters/basic/eq-not-a-number
    filters/basic/in-blank-element-is-22P02
    filters/type/enum-eq-uppercase
    filters/type/enum-in-invalid
    filters/type/int4-decimal-text
  )

  @recorded for {%{id: id} = scenario, expected} <- Scenario.recorded_scenarios("filters", false),
                id in @ids,
                do: {scenario, expected}

  test "every error scenario is present" do
    assert length(@recorded) == length(@ids)
  end

  for {%{id: id, path: path}, %{body: body}} <- @recorded do
    @path path
    @body body

    test "#{id} fails like PostgREST" do
      %URI{path: "/" <> table, query: query} = URI.parse(@path)
      [{key, value} | _] = query |> URI.query_decoder() |> Enum.to_list()
      assert {:ok, condition} = Filter.parse_condition(key, value)

      types = Catalog.column_types(Repo, "test", table)
      categories = Catalog.column_categories(Repo, "test", table)

      {iodata, builder} =
        Where.compile(condition, "t", types, Builder.new(), categories: categories)

      {where, params} = Builder.to_sql(builder, iodata)

      # PostgREST runs with `search_path = <schema>`, which decides whether Postgres
      # qualifies type names in messages.
      {:error, {:error, %Postgrex.Error{postgres: pg}}} =
        Repo.transaction(fn ->
          Repo.query!("SET LOCAL search_path = test, public")
          result = Repo.query("SELECT 1 FROM test.#{table} t WHERE #{where}", params)
          Repo.rollback(result)
        end)

      recorded = Jason.decode!(@body)
      assert pg.pg_code == recorded["code"]
      assert pg.message == recorded["message"]
      assert Map.get(pg, :hint) == recorded["hint"]
    end
  end
end
