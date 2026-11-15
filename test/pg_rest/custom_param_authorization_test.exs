defmodule PgRest.CustomParamAuthorizationTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import PgRest.PlugCase

  alias PgRest.SQL.ScopedSource

  defmodule KeylessClients do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, custom_params: ["q", "or_name", "prefix", "invalid"]

    @primary_key false
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
    end

    @impl true
    def handle_param("q", value, query, _ctx), do: where(query, [c], c.name == ^value)
    def handle_param("or_name", value, query, _ctx), do: or_where(query, [c], c.name == ^value)

    def handle_param("prefix", value, query, _ctx),
      do: %{query | from: %{query.from | prefix: value}}

    def handle_param("invalid", _value, query, _ctx), do: limit(query, 1)
  end

  defmodule NarrowingPolicy do
    @moduledoc false
    @behaviour PgRest.Authorization
    @impl true
    def authorize_query(_conn, _resource, :read, query, _ctx),
      do: {:ok, where(query, [c], c.name == "Microsoft")}
  end

  setup do
    register([KeylessClients])
    :ok
  end

  test "a keyless identity resource supports a custom-filtered GET" do
    assert request("GET", "/clients").status == 200
    conn = request("GET", "/clients?q=Microsoft")
    assert conn.status == 200
    assert json(conn) == [%{"name" => "Microsoft"}]
  end

  test "a keyless identity parameter cannot change the prefix" do
    assert_raise ArgumentError, ~r/may not change the base scope's prefix/, fn ->
      ScopedSource.base_query(KeylessClients, %{}, [{"prefix", "public"}])
    end
  end

  test "identity custom parameters still obey the predicate contract" do
    assert_raise ArgumentError, ~r/may only add where\/join\/distinct/, fn ->
      ScopedSource.base_query(KeylessClients, %{}, [{"invalid", "1"}])
    end
  end

  test "a changed keyless restricted source is refused rather than widened" do
    restricted = where(KeylessClients, [c], c.name == "Microsoft")

    for param <- [{"q", "Microsoft"}, {"or_name", "Apple"}] do
      assert {:error, %{code: "42501"}} =
               ScopedSource.with_params(restricted, KeylessClients, %{}, [param])
    end
  end

  test "a narrowing hook on a keyless resource stays fail closed with custom parameters" do
    conn = request("GET", "/clients?or_name=Apple", nil, [], authorization: NarrowingPolicy)
    assert conn.status == 401
    assert json(conn)["code"] == "42501"
  end
end
