defmodule PgRest.GeneratedNameCollisionTest do
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [json: 1, register: 1, request: 5]

  alias PgRest.Compat.Repo

  # Test-only tables whose column names equal names PgRest generates in SQL: Postgres binds
  # a bare name to a column before a row alias, so these only work while the generated SQL
  # qualifies its row references.
  @schema "pgrst_collide_test"

  defmodule Parent do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "pgrst_collide_test"
    schema "cparents" do
      field(:name, :string)
    end
  end

  defmodule Child do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "pgrst_collide_test"
    schema "cchildren" do
      # Literally the alias the planner gives the first embed's lateral.
      field(:pgrst_e1, :string)
      belongs_to(:cparent, Parent, type: :integer, foreign_key: :parent_id)
    end
  end

  defmodule KeyK do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:k, :integer, autogenerate: false}
    @schema_prefix "pgrst_collide_test"
    schema "kt" do
      field(:name, :string)
    end
  end

  setup_all do
    Repo.query!("DROP SCHEMA IF EXISTS #{@schema} CASCADE")
    Repo.query!("CREATE SCHEMA #{@schema}")

    for sql <- [
          "CREATE TABLE #{@schema}.cparents (id int PRIMARY KEY, name text)",
          """
          CREATE TABLE #{@schema}.cchildren (
            id int PRIMARY KEY,
            pgrst_e1 text,
            parent_id int REFERENCES #{@schema}.cparents (id)
          )
          """,
          "CREATE TABLE #{@schema}.kt (k int PRIMARY KEY, name text)",
          "INSERT INTO #{@schema}.cparents VALUES (1, 'p1')",
          "INSERT INTO #{@schema}.cchildren VALUES (1, 'x', 1), (2, 'y', NULL)"
        ] do
      Repo.query!(sql)
    end

    on_exit(fn -> Repo.query!("DROP SCHEMA IF EXISTS #{@schema} CASCADE") end)
    :ok
  end

  setup do
    register([Parent, Child, KeyK])
    :ok
  end

  test "an embed null filter reads the lateral, not a same-named column of the parent" do
    path = "/cchildren?select=id,cparent(id)&order=id"

    conn = request("GET", path <> "&cparent=is.null", nil, [], [])
    assert [%{"id" => 2}] = json(conn)

    conn = request("GET", path <> "&cparent=not.is.null", nil, [], [])
    assert [%{"id" => 1}] = json(conn)
  end

  test "a primary key column named k still yields the Location header" do
    conn =
      request("POST", "/kt", %{"k" => 7, "name" => "a"}, [{"prefer", "return=headers-only"}], [])

    assert conn.status == 201
    assert Plug.Conn.get_resp_header(conn, "location") == ["/kt?k=eq.7"]
  end
end
