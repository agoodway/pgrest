defmodule PgRest.Compat.SafeupdateDbTest do
  # SQL level: pins the SQLSTATE and message texts the `safeupdate` scenarios expect to the
  # real pg-safeupdate extension. Needs `docker compose --profile safeupdate up -d`.
  use ExUnit.Case, async: false

  alias PgRest.Compat.SafeupdateRepo

  @moduletag :safeupdate

  # `LOAD` is per session, so the pool's one connection keeps the extension once loaded; the
  # extension-free half runs on its own fresh connection.
  defp rolled_back(fun) do
    {:error, result} = SafeupdateRepo.transaction(fn -> SafeupdateRepo.rollback(fun.()) end)
    result
  end

  defp load_safeupdate!, do: SafeupdateRepo.query!("LOAD 'safeupdate'")

  describe "with safeupdate loaded" do
    test "UPDATE without WHERE is a 21000 error" do
      error =
        assert_raise Postgrex.Error, fn ->
          rolled_back(fn ->
            load_safeupdate!()
            SafeupdateRepo.query!("UPDATE test.safe_update_items SET name = 'New name'")
          end)
        end

      assert %Postgrex.Error{
               postgres: %{pg_code: "21000", message: "UPDATE requires a WHERE clause"}
             } = error
    end

    test "DELETE without WHERE is a 21000 error" do
      error =
        assert_raise Postgrex.Error, fn ->
          rolled_back(fn ->
            load_safeupdate!()
            SafeupdateRepo.query!("DELETE FROM test.safe_delete_items")
          end)
        end

      assert %Postgrex.Error{
               postgres: %{pg_code: "21000", message: "DELETE requires a WHERE clause"}
             } = error
    end

    test "UPDATE and DELETE with a WHERE clause succeed" do
      assert [2, 2] ==
               rolled_back(fn ->
                 load_safeupdate!()

                 %{num_rows: updated} =
                   SafeupdateRepo.query!(
                     "UPDATE test.safe_update_items SET name = 'New name' WHERE id > 0"
                   )

                 %{num_rows: deleted} =
                   SafeupdateRepo.query!("DELETE FROM test.safe_delete_items WHERE id > 0")

                 [updated, deleted]
               end)
    end
  end

  describe "without safeupdate loaded (a fresh connection)" do
    setup do
      opts =
        Keyword.take(SafeupdateRepo.config(), [:hostname, :port, :username, :password, :database])

      %{conn: start_supervised!({Postgrex, opts})}
    end

    test "UPDATE and DELETE without WHERE succeed", %{conn: conn} do
      Postgrex.transaction(conn, fn conn ->
        assert %{num_rows: 2} =
                 Postgrex.query!(conn, "UPDATE test.unsafe_update_items SET name = 'x'", [])

        assert %{num_rows: 2} = Postgrex.query!(conn, "DELETE FROM test.unsafe_delete_items", [])
        DBConnection.rollback(conn, :done)
      end)
    end
  end
end
