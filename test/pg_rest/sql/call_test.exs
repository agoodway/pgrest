defmodule PgRest.SQL.CallTest do
  use ExUnit.Case, async: true

  import Ecto.Query, only: [where: 3]

  alias PgRest.Compat.Repo
  alias PgRest.Compat.Resources.Projects
  alias PgRest.{Function, Plan}
  alias PgRest.Function.{Param, Return}
  alias PgRest.SQL.{Builder, Call}
  alias PgRest.Test.SQLResources.Where, as: ScopedProject

  defp function(name, params, returns) do
    %Function{schema: "test", name: name, params: params, returns: returns, volatility: :volatile}
  end

  defp add_them do
    function(
      "add_them",
      [%Param{name: "a", type: "integer"}, %Param{name: "b", type: "integer"}],
      %Return{kind: :scalar, type: "integer"}
    )
  end

  defp getproject do
    function(
      "getproject",
      [%Param{name: "id", type: "integer"}],
      %Return{kind: :composite, set?: true, type: "test.projects", resource: Projects}
    )
  end

  defp compile(function, args, scope \\ nil) do
    call = %Plan.Call{function: function, args: args, read_only?: true}
    {sql, builder} = Call.source(call, scope, Builder.new(repo: Repo))
    {IO.iodata_to_binary(sql), Enum.reverse(builder.params), builder}
  end

  test "direct arguments are text parameters cast to the parameter type" do
    {sql, params, _builder} = compile(add_them(), {:direct, %{"a" => "1"}})

    assert sql =~ ~s|(SELECT "test"."add_them"("a" := $1::text::integer) pgrst_scalar) pgrst_call|
    assert sql =~ "SELECT pgrst_call.pgrst_scalar FROM"
    assert params == ["1"]
    refute sql =~ "$2"
  end

  test "a JSON body is bound once and expanded with json_to_recordset" do
    {sql, params, _builder} = compile(getproject(), {:json, ~s({"id":1}), ["id"]})

    assert sql =~ "(SELECT $1::text::json AS json_data) pgrst_payload"
    assert sql =~ "json_to_record"
    assert sql =~ ~s|AS _("id" integer)|
    assert sql =~ ~s|LATERAL "test"."getproject"("id" := pgrst_body."id") pgrst_call|
    assert params == [~s({"id":1})]
  end

  test "a JSON body without arguments calls the function bare" do
    {sql, params, _builder} = compile(getproject(), {:json, "{}", []})
    assert sql =~ ~s|"test"."getproject"() pgrst_call|
    assert params == []
  end

  test "a single unnamed parameter takes the body" do
    function =
      function("unnamed_json_param", [%Param{name: "", type: "json"}], %Return{
        kind: :scalar,
        type: "json"
      })

    {sql, params, _builder} = compile(function, {:single, ~s({"A":1})})

    assert sql =~ ~s|"test"."unnamed_json_param"($1::text::json)|
    assert params == [~s({"A":1})]
  end

  test "a variadic argument binds the values natively as text[]" do
    function =
      function(
        "variadic_param",
        [%Param{name: "v", type: "text[]", variadic?: true, required?: false}],
        %Return{kind: :scalar, type: "text[]"}
      )

    {sql, params, _builder} = compile(function, {:direct, %{"v" => ["hi", "there"]}})

    assert sql =~ ~s|VARIADIC "v" := $1::text[]::text[]|
    assert params == [["hi", "there"]]

    {post_sql, _params, _builder} = compile(function, {:json, ~s({"v":["a"]}), ["v"]})
    assert post_sql =~ ~s|VARIADIC "v" := pgrst_body."v"|
  end

  test "no form casts a parameter without going through text" do
    forms = [
      {add_them(), {:direct, %{"a" => "1", "b" => "2"}}},
      {add_them(), {:json, ~s({"a":1,"b":2}), ["a", "b"]}},
      {getproject(), {:direct, %{"id" => "1"}}}
    ]

    for {function, args} <- forms do
      {sql, _params, _builder} = compile(function, args)
      refute sql =~ ~r/\$\d+::(integer|json)/, sql
    end
  end

  test "a resource result is exposed under its field names" do
    {sql, _params, _builder} = compile(getproject(), {:direct, %{"id" => "1"}})
    assert sql =~ ~s|pgrst_call."id" AS "id", pgrst_call."name" AS "name"|
  end

  describe ":stored_rows scope" do
    test "probes the scoped source by key and every mapped column" do
      query = where(ScopedProject, [p], p.client_id == ^1)

      {sql, params, builder} =
        compile(getproject(), {:direct, %{"id" => "1"}}, {ScopedProject, query})

      assert sql =~ "(SELECT pgrst_call.* FROM "
      assert sql =~ "EXISTS (SELECT 1 FROM ("
      assert sql =~ ~s|s WHERE (s."id") = (pgrst_call."id")|

      assert sql =~
               ~s|AND (s."id", s."name", s."client_id") IS NOT DISTINCT FROM | <>
                 ~s|(pgrst_call."id", pgrst_call."name", pgrst_call."client_id") OFFSET 0)|

      assert sql =~ ") pgrst_call"
      assert params == ["1", 1]
      assert Builder.param_count(builder) == 2
    end

    test "nil scope emits no probe" do
      {sql, _params, _builder} = compile(getproject(), {:direct, %{"id" => "1"}})
      refute sql =~ "EXISTS"
    end
  end
end
