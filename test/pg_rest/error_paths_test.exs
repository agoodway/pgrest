defmodule PgRest.ErrorPathsTest do
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [json: 1, register: 1, request: 3, request: 5]

  alias PgRest.Compat.Resources

  import ExUnit.CaptureLog

  defmodule Boom do
    @moduledoc false
    # A resource whose changeset raises a plain exception carrying text that must not leak.
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def changeset(_struct, _attrs, _context), do: raise("secret internal detail")
  end

  defmodule ForeignKeyBoom do
    @moduledoc false
    # The changeset raises what the driver raises for a foreign key violation.
    defmacro __using__(_opts) do
      quote do
        use Ecto.Schema
        use PgRest.Resource

        @primary_key {:id, :integer, autogenerate: false}
        @schema_prefix "test"
        schema "clients" do
          field(:name, :string)
        end

        @impl PgRest.Resource
        def changeset(_struct, _attrs, _context) do
          raise Postgrex.Error,
            postgres: %{
              code: "23503",
              message: "violates foreign key constraint",
              detail: "Key (client_id)=(999) is not present in table clients.",
              severity: "ERROR"
            }
        end
      end
    end
  end

  defmodule OpenFk do
    @moduledoc false
    use ForeignKeyBoom
  end

  defmodule ScopedFk do
    @moduledoc false
    use ForeignKeyBoom
    import Ecto.Query

    @impl PgRest.Resource
    def scope(query, _context), do: where(query, [c], c.id > 0)
  end

  describe "an exception outside the database" do
    test "becomes a generic 500 with the four PostgREST keys" do
      register([Boom])

      log =
        capture_log(fn ->
          conn = request("POST", "/clients", %{"id" => 100, "name" => "x"})
          send(self(), {:conn, conn})
        end)

      assert_received {:conn, conn}
      assert conn.status == 500

      assert Jason.decode!(conn.resp_body) == %{
               "code" => "PGRSTX00",
               "message" => "Internal server error",
               "details" => nil,
               "hint" => nil
             }

      refute conn.resp_body =~ "secret"
      refute log =~ "secret"
    end
  end

  describe "S-H5 through the rescue path" do
    test "a foreign key violation keeps details on the identity scope" do
      register([OpenFk])
      conn = request("POST", "/clients", %{"id" => 100, "name" => "x"})

      assert conn.status == 409
      assert %{"code" => "23503", "details" => details} = Jason.decode!(conn.resp_body)
      assert is_binary(details)
    end

    test "a foreign key violation has no details on a scoped resource" do
      register([ScopedFk])
      conn = request("POST", "/clients", %{"id" => 100, "name" => "x"})

      assert conn.status == 409
      assert %{"code" => "23503", "details" => nil} = Jason.decode!(conn.resp_body)
    end
  end

  defmodule ExitRepo do
    @moduledoc false
    # A repo whose pool process is gone: every call exits.
    def in_transaction?, do: false
    def transaction(_fun, _opts), do: exit({:noproc, {GenServer, :call, [:pool]}})
    def query(_sql, _params, _opts), do: exit({:noproc, {GenServer, :call, [:pool]}})
    def query!(_sql, _params, _opts), do: exit({:noproc, {GenServer, :call, [:pool]}})
  end

  describe "an exit" do
    test "becomes the generic 500 and is logged by kind only" do
      register(Resources.all())

      log =
        capture_log(fn ->
          conn =
            request("GET", "/clients", nil, [], repo: ExitRepo)

          send(self(), {:conn, conn})
        end)

      assert_received {:conn, conn}
      assert conn.status == 500
      assert %{"code" => "PGRSTX00", "message" => "Internal server error"} = json(conn)
      assert log =~ "unexpected :exit"
      refute log =~ "noproc"
    end
  end

  describe "a registry that cannot answer" do
    test "is PostgREST's 503 PGRST002 (no schema cache yet), not a crash" do
      register([Resources.Clients])
      stop_supervised!(PgRest.Registry)

      conn = request("GET", "/clients", nil)

      assert conn.status == 503

      assert %{
               "code" => "PGRST002",
               "message" => "Could not query the database for the schema cache. Retrying."
             } = json(conn)
    end
  end

  describe "malformed request text" do
    test "an undecodable percent escape is a 400, not a 500" do
      register([Resources.Items])
      conn = request("GET", "/items?id=eq.%zz", nil)

      assert conn.status == 400
      assert %{"code" => code} = Jason.decode!(conn.resp_body)
      assert String.starts_with?(code, "PGRST")
    end
  end
end
