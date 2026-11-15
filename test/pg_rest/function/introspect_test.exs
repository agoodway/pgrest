defmodule PgRest.Function.IntrospectTest do
  use ExUnit.Case, async: true

  alias PgRest.Compat.{Functions, Repo, Resources, SupabaseRepo}
  alias PgRest.Function
  alias PgRest.Function.{Introspect, Param, Return}

  defmodule DownRepo do
    @moduledoc false
    def in_transaction?, do: false
    def transaction(fun, _opts), do: {:ok, fun.()}

    def query!(_sql, _params, _opts),
      do: raise(DBConnection.ConnectionError, "connection not available")
  end

  defp configs(modules), do: Enum.map(modules, & &1.__pgrest_config__())

  defp load!(repo, schemas, filter, modules \\ []) do
    assert {:ok, functions} = Introspect.load(repo, schemas, configs(modules), filter)
    functions
  end

  defp by_name(functions, name), do: Enum.filter(functions, &(&1.name == name))
  defp names(functions), do: functions |> Enum.map(& &1.name) |> Enum.uniq() |> Enum.sort()

  describe "the test fixture" do
    setup do
      %{functions: load!(Repo, ["test"], %{}, Resources.all())}
    end

    test "add_them: two required integer params, a volatile integer scalar (upstream)", %{
      functions: functions
    } do
      assert [
               %Function{
                 schema: "test",
                 params: [
                   %Param{name: "a", type: "integer", required?: true, variadic?: false},
                   %Param{name: "b", type: "integer", required?: true, variadic?: false}
                 ],
                 returns: %Return{kind: :scalar, set?: false, type: "integer"},
                 volatility: :volatile,
                 result_scope: :stored_rows,
                 module: nil
               }
             ] = by_name(functions, "add_them")
    end

    test "getallprojects: a set of the registered Projects resource", %{
      functions: functions
    } do
      assert [
               %Function{
                 params: [],
                 returns: %Return{
                   kind: :composite,
                   set?: true,
                   resource: Resources.Projects,
                   columns: [{"id", "integer"}, {"name", "text"}, {"client_id", "integer"}]
                 },
                 volatility: :volatile
               }
             ] = by_name(functions, "getallprojects")
    end

    test "upstream volatility: sayhello and noparamsproc immutable, getitemrange stable", %{
      functions: functions
    } do
      assert [%Function{volatility: :immutable}] = by_name(functions, "sayhello")
      assert [%Function{volatility: :immutable, params: []}] = by_name(functions, "noparamsproc")

      assert [
               %Function{
                 volatility: :stable,
                 params: [
                   %Param{name: "min", type: "bigint"},
                   %Param{name: "max", type: "bigint"}
                 ],
                 returns: %Return{kind: :composite, set?: true, resource: Resources.Items}
               }
             ] = by_name(functions, "getitemrange")
    end

    test "variadic_param: the last param is variadic and optional", %{functions: functions} do
      assert [%Function{params: [%Param{name: "v", type: "text[]"} = v]}] =
               by_name(functions, "variadic_param")

      assert v.variadic?
      refute v.required?

      assert [%Function{returns: %Return{kind: :scalar, type: "text[]"}}] =
               by_name(functions, "variadic_param")
    end

    test "OUT and INOUT params make a composite, even a single one", %{functions: functions} do
      assert [
               %Function{
                 params: [%Param{name: "num"}],
                 returns: %Return{kind: :composite, columns: [{"num_plus_one", "integer"}]}
               }
             ] = by_name(functions, "single_out_param")

      assert [
               %Function{
                 params: [%Param{name: "num", type: "integer"}],
                 returns: %Return{kind: :composite, columns: [{"num", "integer"}]}
               }
             ] = by_name(functions, "single_inout_param")

      assert [
               %Function{
                 params: [],
                 returns: %Return{
                   kind: :composite,
                   type: "record",
                   columns: [{"my_json", "json"}, {"num", "integer"}, {"str", "text"}]
                 }
               }
             ] = by_name(functions, "many_out_params")
    end

    test "unnamed params, overloads, void and volatility", %{functions: functions} do
      assert [%Function{params: [%Param{name: "", type: "json"}]}] =
               by_name(functions, "unnamed_json_param")

      assert [_, _, _] = overloads = by_name(functions, "overloaded_same_args")

      text_overload = [
        %Param{name: "arg", type: "text"},
        %Param{name: "num", type: "integer", required?: false}
      ]

      assert text_overload in Enum.map(overloads, & &1.params)

      assert [%Function{returns: %Return{kind: :void, type: "void"}}] =
               by_name(functions, "ret_void")

      assert [%Function{volatility: :volatile}] = by_name(functions, "callcounter")
      assert [%Function{volatility: :volatile}] = by_name(functions, "getproject")
    end

    test "a composite of an unregistered table carries no resource" do
      [%Function{returns: returns}] = Repo |> load!(["test"], %{}) |> by_name("getallprojects")
      assert %Return{kind: :composite, resource: nil, columns: [_, _, _]} = returns
    end
  end

  describe "always skipped" do
    test "extension-owned and trigger-returning functions never appear" do
      filters = [
        %{},
        %{only: ["similarity", "touch_updated_at", "add_them"]},
        %{except: ["add_them"]},
        %{as_role: ["postgres"]}
      ]

      for filter <- filters do
        found = Repo |> load!(["test"], filter) |> names()
        refute "similarity" in found, inspect(filter)
        refute "touch_updated_at" in found, inspect(filter)
      end
    end
  end

  describe "filters" do
    test "only: keeps exactly the listed names; except: drops them" do
      assert ["add_them"] = Repo |> load!(["test"], %{only: ["add_them"]}) |> names()

      all = Repo |> load!(["test"], %{}) |> names()
      rest = Repo |> load!(["test"], %{except: ["add_them"]}) |> names()
      assert rest == all -- ["add_them"]
    end

    test "the compat only: list holds every ported function" do
      found = Repo |> load!(["test"], %{only: Functions.test_functions()}) |> names()
      assert found == Enum.sort(Functions.test_functions())
    end

    test "as_role: keeps a function any listed role may EXECUTE" do
      anon = SupabaseRepo |> load!(["public"], %{as_role: ["anon"]}) |> names()
      refute "privileged_hello" in anon
      assert "get_status" in anon

      both = SupabaseRepo |> load!(["public"], %{as_role: ["anon", "authenticated"]}) |> names()
      assert "privileged_hello" in both
    end
  end

  describe "the supabase fixture" do
    setup do
      %{functions: load!(SupabaseRepo, ["public"], %{}, PgRest.Compat.Supabase.Resources.all())}
    end

    test "a TABLE function is a composite set of its columns, with no resource", %{
      functions: functions
    } do
      assert [
               %Function{
                 returns: %Return{
                   kind: :composite,
                   set?: true,
                   columns: [{"username", "text"}, {"status", "public.user_status"}],
                   categories: %{"username" => "S", "status" => "E"},
                   resource: nil
                 }
               }
             ] = by_name(functions, "get_username_and_status")
    end

    test "void and optional params", %{functions: functions} do
      assert [%Function{params: [], returns: %Return{kind: :void}}] =
               by_name(functions, "void_func")

      assert [%Function{params: [%Param{name: "param", type: "text", required?: false}]}] =
               by_name(functions, "function_with_optional_param")
    end

    test "a setof a registered table carries its resource", %{functions: functions} do
      assert [%Function{returns: %Return{resource: PgRest.Compat.Supabase.User, set?: true}}] =
               by_name(functions, "set_users_offline")
    end
  end

  test "a connection failure is an error, not a raise" do
    assert {:error, %DBConnection.ConnectionError{} = error} =
             Introspect.load(DownRepo, ["test"], [], %{})

    assert Introspect.transient?(error)
  end
end
