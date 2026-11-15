defmodule PgRest.SQL.ScopedSourceTest do
  # Sync: the compiled-SQL cache is a named ETS table (owned by PgRest.Cache).
  use ExUnit.Case

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias PgRest.Compat.Repo
  alias PgRest.SQL.{Builder, ScopedSource}
  alias PgRest.Test.SQLResources, as: R
  alias PgRest.Test.SQLResources.{Extra, Extra2}

  @doc false
  def handle_event(_event, _measure, meta, pid), do: send(pid, {:scope_cache, meta.cached})

  setup do
    :ets.delete_all_objects(ScopedSource.cache_table())
    :ok
  end

  defp splice(resource, ctx, builder),
    do: resource |> ScopedSource.base_query(ctx, []) |> ScopedSource.compile(resource, builder)

  # Runs `SELECT * FROM <splice> s` behind `lead` native parameters.
  defp run(resource, ctx, lead \\ 2) do
    builder = Builder.new(repo: Repo)

    {guards, builder} =
      Enum.map_reduce(1..lead//1, builder, fn i, b ->
        {ph, b} = Builder.param(b, i, "integer", :native)
        {[ph, " IS NOT NULL"], b}
      end)

    {splice, builder} = splice(resource, ctx, builder)
    where = if guards == [], do: "", else: [" WHERE ", Enum.intersperse(guards, " AND ")]

    {sql, params} =
      Builder.to_sql(builder, ["SELECT * FROM ", splice, " s", where, " ORDER BY 1"])

    {sql, SQL.query!(Repo, sql, params).rows}
  end

  test "compiled scope cache clears after its size bound" do
    table = ScopedSource.cache_table()
    for n <- 1..5_001, do: :ets.insert(table, {{:filler, n}, :shape, "sql"})
    {_sql, rows} = run(R.Where, %{client_id: 1})
    assert length(rows) == 2
    assert :ets.info(table, :size) <= 5_000
  end

  describe "splicing" do
    test "a where scope returns its rows with placeholders starting at $3" do
      {sql, rows} = run(R.Where, %{client_id: 1})
      # the splice (first in the text) holds only $3; $1 and $2 are the leading guards
      assert Enum.concat(Regex.scan(~r/\$\d+/, sql)) == ["$3", "$1", "$2"]
      assert rows == [[1, "Windows 7", 1], [2, "Windows 10", 1]]
    end

    test "a joined scope returns each base row once, as a PK semijoin" do
      {sql, rows} = run(R.Joined, %{client_id: 1})
      assert sql =~ "IN (SELECT"
      assert Enum.concat(Regex.scan(~r/\$\d+/, sql)) == ["$3", "$1", "$2"]
      assert rows == [[1, "Windows 7", 1], [2, "Windows 10", 1]]
    end

    test "named bindings (as:) survive splicing, with and without a join" do
      {_sql, rows} = run(R.NamedPlain, %{client_id: 1})
      assert rows == [[1, "Windows 7", 1], [2, "Windows 10", 1]]

      {sql, rows} = run(R.Named, %{client_id: 1})
      assert sql =~ "IN (SELECT"
      assert rows == [[1, "Windows 7", 1], [2, "Windows 10", 1]]
    end

    test "a distinct scope is spliced as the PK semijoin" do
      {sql, rows} = run(R.Distinct, %{client_id: 2})
      assert sql =~ "IN (SELECT"
      assert rows == [[3, "IOS", 2], [4, "OSX", 2]]
    end

    test "renamed columns are exposed by field name" do
      {sql, rows} = run(R.Renamed, %{client_id: 2}, 0)
      assert sql =~ ~s(AS "title")
      assert rows == [[3, "IOS", 2], [4, "OSX", 2]]

      {_, rows} = run(R.RenamedJoined, %{}, 0)
      assert length(rows) == 4
    end

    test "the semijoin reads the scope's effective prefix on both sides" do
      {sql, rows} = run(Extra.Prefixed, %{}, 0)
      assert sql =~ ~s("test"."projects" t)
      refute sql =~ ~s("public")
      assert length(rows) == 5
    end

    test "with no prefix anywhere the semijoin is unqualified on both sides" do
      query = ScopedSource.base_query(Extra2.Unprefixed, %{}, [])
      {splice, _} = ScopedSource.compile(query, Extra2.Unprefixed, Builder.new(repo: Repo))
      sql = IO.iodata_to_binary(splice)
      assert sql =~ ~s(FROM "projects" t)
      assert sql =~ ~s(FROM "projects" AS)
      refute sql =~ ~s("public")
    end

    test "load_in_query: false fields are excluded on both paths" do
      for distinct? <- [false, true] do
        {_sql, rows} = run(Extra2.Hidden, %{distinct: distinct?}, 0)
        assert length(rows) == 5

        builder = Builder.new(repo: Repo)
        {splice, builder} = splice(Extra2.Hidden, %{distinct: distinct?}, builder)
        {sql, params} = Builder.to_sql(builder, ["SELECT * FROM ", splice, " s ORDER BY 1"])
        assert SQL.query!(Repo, sql, params).columns == ["id", "title"]
      end
    end

    test "the semijoin selects schema fields only" do
      builder = Builder.new(repo: Repo)
      {splice, builder} = splice(Extra.Narrow, %{}, builder)
      {sql, params} = Builder.to_sql(builder, ["SELECT * FROM ", splice, " s ORDER BY 1"])
      result = SQL.query!(Repo, sql, params)
      assert result.columns == ["id", "name"]
      assert length(result.rows) == 5
    end

    test "an identity scope has no wrapper" do
      {sql, rows} = run(R.Plain, %{}, 0)
      refute sql =~ "IN (SELECT"
      assert length(rows) == 5
    end

    test "custom params only run when declared" do
      {_sql, rows} = run(R.Custom, %{}, 0)
      assert length(rows) == 5

      query = ScopedSource.base_query(R.Custom, %{}, [{"name_like", "W%"}, {"other", "x"}])
      assert [_] = query.wheres

      builder = Builder.new(repo: Repo)
      {splice, builder} = ScopedSource.compile(query, R.Custom, builder)
      {sql, params} = Builder.to_sql(builder, ["SELECT id FROM ", splice, " s ORDER BY id"])
      assert SQL.query!(Repo, sql, params).rows == [[1], [2]]
    end

    test "a keyless table with a joining/distinct scope raises at first use" do
      assert_raise ArgumentError, ~r/primary key/, fn -> run(R.Keyless, %{}, 0) end
    end

    test "a fragment holding a $1 literal keeps it and binds in the right slot" do
      query =
        from(p in R.Plain,
          where: fragment("? || '$1' <> ?", p.name, ^"nope") and p.client_id == ^1
        )

      builder = Builder.new(repo: Repo)
      {guard, builder} = Builder.param(builder, 7, "integer", :native)
      {splice, builder} = ScopedSource.compile(query, R.Plain, builder)

      {sql, params} =
        Builder.to_sql(builder, [
          "SELECT id FROM ",
          splice,
          " s WHERE ",
          guard,
          " = 7 ORDER BY id"
        ])

      assert sql =~ "'$1'"
      assert sql =~ "$2" and sql =~ "$3"
      assert params == [7, "nope", 1]
      assert SQL.query!(Repo, sql, params).rows == [[1], [2]]
    end
  end

  describe "predicate contract" do
    test "combinations, lock, CTEs, windows and a replaced source raise" do
      for kind <- [:union, :lock, :cte, :window, :from] do
        assert_raise ArgumentError, ~r/may only add where\/join\/distinct/, fn ->
          ScopedSource.base_query(Extra.Forbidden, %{kind: kind}, [])
        end
      end
    end

    test "from hints and updates raise" do
      for kind <- [:hint, :update] do
        assert_raise ArgumentError, ~r/may only add where\/join\/distinct/, fn ->
          ScopedSource.base_query(Extra2.Hinted, %{kind: kind}, [])
        end
      end
    end

    test "compile without a repo raises ArgumentError" do
      query = ScopedSource.base_query(R.Plain, %{}, [])

      assert_raise ArgumentError, ~r/no :repo/, fn ->
        ScopedSource.compile(query, R.Plain, Builder.new())
      end
    end

    test "order_by and limit raise" do
      for resource <- [R.Ordered, R.Limited] do
        assert_raise ArgumentError,
                     "#{inspect(resource)}.scope/2 may only add where/join/distinct clauses",
                     fn -> ScopedSource.base_query(resource, %{}, []) end
      end
    end
  end

  describe "compiled-SQL cache" do
    setup do
      id = {__MODULE__, make_ref()}
      :telemetry.attach(id, [:pgrest, :scope_cache], &__MODULE__.handle_event/4, self())

      on_exit(fn -> :telemetry.detach(id) end)
    end

    test "same shape, different values: own rows, one entry, no second to_sql" do
      {_, rows1} = run(R.Where, %{client_id: 1})
      assert_received {:scope_cache, false}
      {_, rows2} = run(R.Where, %{client_id: 2})
      assert_received {:scope_cache, true}

      assert rows1 == [[1, "Windows 7", 1], [2, "Windows 10", 1]]
      assert rows2 == [[3, "IOS", 2], [4, "OSX", 2]]

      entries =
        :ets.select_count(ScopedSource.cache_table(), [
          {{{Repo, R.Where, :_}, :_, :_}, [], [true]}
        ])

      assert entries == 1
    end

    test "create_cache/0 is idempotent" do
      assert :ok = ScopedSource.create_cache()
      assert :ok = ScopedSource.create_cache()
    end

    test "without the cache table queries still compile" do
      :ok = Supervisor.terminate_child(PgRest.Supervisor, PgRest.Cache)
      on_exit(fn -> Supervisor.restart_child(PgRest.Supervisor, PgRest.Cache) end)
      {_, rows} = run(R.Where, %{client_id: 1})
      assert length(rows) == 2
      assert_received {:scope_cache, false}
    end
  end

  describe "identity_scope?/2" do
    test "true for a plain resource, false for a scoped one; scope/2 runs once" do
      plain = ScopedSource.base_query(R.Plain, %{}, [])
      assert ScopedSource.identity_scope?(R.Plain, plain)

      ctx = %{client_id: 1, test_pid: self()}
      scoped = ScopedSource.base_query(R.Where, ctx, [])
      refute ScopedSource.identity_scope?(R.Where, scoped)

      assert_received {:scope_called, R.Where}
      refute_received {:scope_called, _}
    end
  end
end
