defmodule PgRest.AuthorizationContextTest do
  use ExUnit.Case, async: false
  import Ecto.Query
  import PgRest.PlugCase

  alias PgRest.Authorization.Apply
  alias PgRest.Compat.Resources
  alias PgRest.Test.{Policies, TelemetryProbe}

  @internal [
    :write_policies,
    :payload_columns,
    :write_check_source,
    :read_check_source,
    :authorization_nodes,
    :source_query
  ]

  defmodule Client do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, custom_params: ["q"], after_load: true
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
    end

    @impl true
    def scope(query, ctx) do
      send(ctx.test_pid, {:context, :scope, ctx})
      query
    end

    @impl true
    def handle_param("q", value, query, ctx) do
      send(ctx.test_pid, {:context, :handle_param, ctx})
      where(query, [c], c.name == ^value)
    end

    @impl true
    def changeset(row, attrs, ctx) do
      send(ctx.test_pid, {:context, :changeset, ctx})
      Ecto.Changeset.cast(row, attrs, [:id, :name], force_changes: true)
    end

    @impl true
    def after_load(row, ctx) do
      send(ctx.test_pid, {:context, :after_load, ctx})
      row
    end
  end

  defmodule Policy do
    @moduledoc false
    @behaviour PgRest.Authorization
    @impl true
    def authorize(_conn, _resource, _op, ctx) do
      send(ctx.test_pid, {:context, :authorize, ctx})
      :ok
    end

    @impl true
    def authorize_query(_conn, _resource, op, query, ctx) do
      send(ctx.test_pid, {:context, :authorize_query, ctx})
      {:ok, query_for(op, query, ctx), count: true, aggregates: true, columns: columns(op, ctx)}
    end

    defp query_for(:explain, query, %{explain_false?: true}), do: where(query, false)
    defp query_for(_op, query, _ctx), do: query
    defp columns(:read, ctx), do: Map.get(ctx, :read_columns, :all)
    defp columns(_op, ctx), do: Map.get(ctx, :write_columns, :all)
  end

  test "user callbacks never receive internal authorization state" do
    register([Client])
    ctx = %{test_pid: self(), user_marker: :kept}

    opts = [
      authorization: Policy,
      tx_end: :commit_allow_override,
      context_builder: fn _, options ->
        send(self(), {:builder_options, options})
        ctx
      end,
      plan_enabled: fn _, context ->
        send(self(), {:context, :plan_enabled, context})
        true
      end
    ]

    conn =
      request(
        "PATCH",
        "/clients?id=eq.1&q=Microsoft",
        %{"name" => "changed"},
        [{"prefer", "return=representation,tx=rollback"}],
        opts
      )

    assert conn.status == 200, conn.resp_body
    assert json(conn) == [%{"id" => 1, "name" => "changed"}]

    plan =
      request(
        "GET",
        "/clients?select=id&limit=1",
        nil,
        [{"accept", "application/vnd.pgrst.plan+json"}],
        opts
      )

    assert plan.status == 200, plan.resp_body

    contexts = contexts()

    assert MapSet.new(contexts, &elem(&1, 0)) ==
             MapSet.new([
               :scope,
               :handle_param,
               :changeset,
               :after_load,
               :authorize,
               :authorize_query,
               :plan_enabled
             ])

    for {callback, context} <- contexts do
      assert context.user_marker == :kept
      assert Map.take(context, @internal) == %{}, "internal state reached #{callback}"
    end

    assert_received {:builder_options, options}
    assert Map.take(options, @internal) == %{}
  end

  test "builder keys that resemble internal state remain user data" do
    register([Client])
    ctx = Map.merge(Map.new(@internal, &{&1, :forged}), %{test_pid: self(), user_marker: :kept})

    conn =
      request("GET", "/clients?select=id", nil, [],
        authorization: Policy,
        context_builder: fn _, _ -> ctx end
      )

    assert conn.status == 200

    for {_callback, context} <- contexts(),
        do: assert(Map.take(context, @internal) == Map.take(ctx, @internal))
  end

  test "read columns remain independent of write payload columns" do
    register([Client])
    ctx = %{test_pid: self(), write_columns: ["name"]}

    conn =
      request(
        "PATCH",
        "/clients?id=eq.1",
        %{"name" => "changed"},
        [{"prefer", "return=representation,tx=rollback"}],
        authorization: Policy,
        tx_end: :commit_allow_override,
        context_builder: fn _, _ -> ctx end
      )

    assert conn.status == 200
    assert json(conn) == [%{"id" => 1, "name" => "changed"}]
  end

  test "unchanged keyless hook queries are granted without an intersection" do
    base = Ecto.Queryable.to_query(Resources.NoPk)

    assert {:ok, %{query: ^base}} =
             Apply.source(
               Plug.Test.conn(:get, "/no_pk"),
               Policies.BareQuery,
               Resources.NoPk,
               :read,
               base,
               %{}
             )
  end

  test "EXPLAIN admission does not replace the statement being explained" do
    register([Client])
    TelemetryProbe.attach([:pgrest, :query, :start])

    conn =
      request("GET", "/clients?select=id", nil, [{"accept", "application/vnd.pgrst.plan+json"}],
        authorization: Policy,
        plan_enabled: true,
        context_builder: fn _, _ -> %{test_pid: self(), explain_false?: true} end
      )

    assert conn.status == 200

    assert [{_event, _measure, %{sql: sql}}] =
             Enum.filter(TelemetryProbe.drain(), fn {_, _, meta} ->
               String.starts_with?(meta.sql, "EXPLAIN")
             end)

    refute sql =~ "WHERE FALSE"
    refute sql =~ "WHERE false"
  end

  defp contexts do
    receive do
      {:context, callback, ctx} -> [{callback, ctx} | contexts()]
    after
      0 -> []
    end
  end
end
