defmodule PgRest.SQL.PlaceholdersPropertyTest do
  # Sync: uses the named compiled-SQL cache table.
  use ExUnit.Case
  use ExUnitProperties

  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias PgRest.Compat.Repo
  alias PgRest.SQL.{Builder, ScopedSource}
  alias PgRest.Test.SQLResources.Plain

  # Where fragments that mix bound parameters with `$1` text hidden in every token kind
  # the tokenizer has to skip. Each is true for every row, whatever `v` is.
  defp fragments,
    do: [
      fn v -> dynamic([p], fragment("? || '$1' <> ?", p.name, ^v)) end,
      fn v -> dynamic([p], fragment("? <> ('it''s $1' || ?)", p.name, ^v)) end,
      fn v -> dynamic([p], fragment(~S"? <> (E'\'$1' || ?)", p.name, ^v)) end,
      fn v -> dynamic([p], fragment("? <> ($$ $1 $$ || ?)", p.name, ^v)) end,
      fn v -> dynamic([p], fragment("? <> ($q$ $1 ' $q$ || ?)", p.name, ^v)) end,
      fn v -> dynamic([p], fragment("? <> ? /* $1 /* $2 */ */", p.name, ^v)) end,
      fn v -> dynamic([p], fragment("(? <> ?) -- $1 $2\n", p.name, ^v)) end,
      fn v -> dynamic([p], fragment(~S|? <> ? AND (SELECT 1 AS "col$1") = 1|, p.name, ^v)) end
    ]

  defp value_gen do
    string([?a..?z, ?$, ?', ?1, ?2, ?\s, ?-, ?/, ?*, ?\\], max_length: 8)
  end

  property "spliced queries return the rows of the unspliced Ecto query" do
    check all(
            picks <- list_of(integer(0..(length(fragments()) - 1)), min_length: 1, max_length: 5),
            values <- list_of(value_gen(), length: 5),
            client_id <- member_of([1, 2]),
            lead <- integer(0..6),
            max_runs: 60
          ) do
      query =
        Enum.zip(picks, values)
        |> Enum.reduce(from(p in Plain, where: p.client_id == ^client_id), fn {i, v}, q ->
          where(q, ^Enum.at(fragments(), i).(v))
        end)

      expected = Repo.all(from(p in query, select: p.id, order_by: p.id))

      builder = Builder.new(repo: Repo)

      {guards, builder} =
        Enum.map_reduce(1..lead//1, builder, fn i, b ->
          {ph, b} = Builder.param(b, i, "integer", :native)
          {[ph, " IS NOT NULL"], b}
        end)

      {splice, builder} = ScopedSource.compile(query, Plain, builder)
      where = if guards == [], do: "", else: [" WHERE ", Enum.intersperse(guards, " AND ")]

      {sql, params} =
        Builder.to_sql(builder, ["SELECT id FROM ", splice, " s", where, " ORDER BY id"])

      assert expected != []
      assert Enum.map(SQL.query!(Repo, sql, params).rows, &hd/1) == expected
    end
  end
end
