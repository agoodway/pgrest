defmodule PgRest.NegotiateTest do
  use ExUnit.Case, async: true

  alias PgRest.{Error, MediaType, Negotiate, Plan, Request}
  alias PgRest.Request.Accept

  defp choose(header, offered \\ [:json, :object, :array, :csv]),
    do: header |> Accept.parse() |> Negotiate.choose(offered)

  describe "choose/2" do
    test "an unknown type is PGRST107 listing the types as sent, q-sorted" do
      assert {:error, %Error{status: 406, code: "PGRST107", message: message}} =
               choose("text/unknowntype", [:json])

      assert message == "None of these media types are available: text/unknowntype"
    end

    test "*/* rescues an unknown type and is JSON" do
      assert {:ok, %MediaType{kind: :json}} = choose("text/unknowntype, */*", [:json])
      assert {:ok, %MediaType{kind: :json}} = choose(nil)
    end

    test "no Accept types at all is JSON" do
      assert {:ok, %MediaType{kind: :json}} = choose("")
    end

    test "the client's order wins over the server's, and q orders the client's" do
      assert {:ok, %{kind: :csv}} = choose("text/csv, application/json")
      assert {:ok, %{kind: :json}} = choose("text/csv;q=0.5, application/json")
      assert {:ok, %{kind: :csv}} = choose("text/csv, */*")
    end

    test "a kind that is not offered is skipped, and the message lists them by q" do
      assert {:ok, %{kind: :json}} =
               choose("application/vnd.pgrst.array+json, application/json", [:json])

      assert {:error, %Error{message: message}} = choose("text/foo; q=0.5, text/bar", [:json])
      assert message == "None of these media types are available: text/bar, text/foo"
    end

    test "geo+json is never offered" do
      assert {:error,
              %Error{message: "None of these media types are available: application/geo+json"}} =
               choose("application/geo+json")
    end

    test "the stripped object type keeps its flag" do
      assert {:ok, %{kind: :object, nulls_stripped?: true}} =
               choose("application/vnd.pgrst.object+json;nulls=stripped")
    end
  end

  describe "offered/1" do
    test "every endpoint offers json, object, array and csv" do
      assert Negotiate.offered() == [:json, :object, :array, :csv]
    end

    test "plan is offered only through the gate" do
      assert Negotiate.offered(plan?: true) == [:json, :object, :array, :csv, :plan]
      refute :plan in Negotiate.offered()
    end

    test "the plan type is a PGRST107 until the gate offers it" do
      assert {:error, %Error{code: "PGRST107", message: message}} =
               choose("application/vnd.pgrst.plan+json", Negotiate.offered())

      assert message ==
               "None of these media types are available: " <>
                 ~s(application/vnd.pgrst.plan+json; for="application/json")
    end
  end

  describe "the plan type" do
    @offered Negotiate.offered(plan?: true)

    test "is chosen when offered, for json, any, object, array and csv" do
      for header <- [
            "application/vnd.pgrst.plan",
            ~s(application/vnd.pgrst.plan; for="*/*"),
            ~s(application/vnd.pgrst.plan; for="application/vnd.pgrst.object"),
            ~s(application/vnd.pgrst.plan; for="application/vnd.pgrst.array+json;nulls=stripped"),
            ~s(application/vnd.pgrst.plan; for="text/csv")
          ] do
        assert {:ok, %MediaType{kind: :plan}} = choose(header, @offered), header
      end
    end

    test "a for= nothing serves is not offered, whatever the plan gate says" do
      for target <- ~w(text/xml application/octet-stream application/geo+json text/plain) do
        assert {:error, %Error{code: "PGRST107", message: message}} =
                 choose(~s(application/vnd.pgrst.plan+json; for="#{target}"), @offered)

        assert message ==
                 "None of these media types are available: " <>
                   ~s(application/vnd.pgrst.plan+json; for="#{target}")
      end

      assert {:error, %Error{}} =
               choose(~s(application/vnd.pgrst.plan; for="application/vnd.pgrst.plan"), @offered)
    end

    test "the next accepted type is the fallback" do
      assert {:ok, %MediaType{kind: :json}} =
               choose(~s(application/vnd.pgrst.plan; for="text/xml", application/json), @offered)
    end

    test "MediaType.body/1 is what the statement answers in" do
      for {header, kind} <- [
            {"application/vnd.pgrst.plan", :json},
            {~s(application/vnd.pgrst.plan; for="*/*"), :json},
            {~s(application/vnd.pgrst.plan; for="application/vnd.pgrst.object"), :object},
            {~s(application/vnd.pgrst.plan; for="text/csv"), :csv}
          ] do
        assert {:ok, plan} = choose(header, @offered)
        assert %MediaType{kind: ^kind} = MediaType.body(plan), header
      end

      assert %MediaType{kind: :csv} = MediaType.body(hd(Accept.parse("text/csv")))
    end

    test "Content-Type echoes the canonical name" do
      assert {:ok, plan} =
               choose(
                 ~s(application/vnd.pgrst.plan+json; for="application/vnd.pgrst.object"; options=wal|verbose),
                 @offered
               )

      assert MediaType.content_type(plan) ==
               ~s(application/vnd.pgrst.plan+json; for="application/vnd.pgrst.object+json"; ) <>
                 "options=verbose|wal; charset=utf-8"
    end
  end

  describe "resolve/5" do
    defmodule Loaded do
      use Ecto.Schema
      use PgRest.Resource, after_load: true

      @primary_key {:id, :integer, autogenerate: false}
      schema "loaded" do
        field(:name, :string)
      end

      @impl PgRest.Resource
      def after_load(row, _context), do: row
    end

    defmodule Hook do
      def authorize(_conn, PgRest.Compat.Resources.Projects, :explain, _context),
        do: {:error, "no"}

      def authorize(_conn, _resource, _operation, _context), do: :ok
    end

    @projects PgRest.Compat.Resources.Projects

    defp resolve(header, plan, context \\ %{plan_enabled: true}, opts \\ []) do
      request = %Request{accepts: Accept.parse(header), prefer: %PgRest.Prefer{}}
      Negotiate.resolve(request, plan, Plug.Test.conn(:get, "/"), context, opts)
    end

    test "csv and stripped nulls are not offered over an after_load/2 resource" do
      plan = %Plan.Read{resource: Loaded}

      assert {:error, %Error{code: "PGRST107", message: message}} = resolve("text/csv", plan)
      assert message == "None of these media types are available: text/csv"

      assert {:error, %Error{message: message}} =
               resolve("application/vnd.pgrst.array+json;nulls=stripped, text/csv", plan)

      assert message ==
               "None of these media types are available: " <>
                 "application/vnd.pgrst.array+json;nulls=stripped, text/csv"
    end

    test "a client that also accepts JSON falls back to it" do
      plan = %Plan.Read{resource: Loaded}

      assert {:ok, %{kind: :json}} = resolve("text/csv, application/json", plan)
      assert {:ok, %{kind: :json}} = resolve("text/csv, */*", plan)

      assert {:ok, %{kind: :array, nulls_stripped?: false}} =
               resolve("text/csv, application/vnd.pgrst.array+json", plan)
    end

    test "a plan without after_load/2, or none at all, keeps the choice" do
      assert {:ok, %{kind: :csv}} = resolve("text/csv", %Plan.Read{resource: nil})
      assert {:ok, %{kind: :csv}} = resolve("text/csv", nil)
    end

    test "the plan type is a fallback past the dropped CSV only through the gate" do
      plan = %Plan.Read{resource: Loaded}
      accept = "text/csv, application/vnd.pgrst.plan"

      assert {:ok, %{kind: :plan}} = resolve(accept, plan)
      assert {:error, %Error{code: "PGRST107"}} = resolve(accept, plan, %{plan_enabled: false})

      assert {:error, %Error{code: "PGRST107"}} =
               resolve(accept, plan, %{plan_enabled: true, authorization: Hook},
                 targets: [@projects]
               )
    end

    test "plan_enabled: true, or a function returning exactly true" do
      type = "application/vnd.pgrst.plan"

      for {setting, ok?} <- [
            {true, true},
            {false, false},
            {fn _conn, _context -> true end, true},
            {fn _conn, _context -> false end, false},
            {fn _conn, _context -> :yes end, false},
            {nil, false}
          ] do
        result = resolve(type, nil, %{plan_enabled: setting}, targets: [])
        assert match?({:ok, %{kind: :plan}}, result) == ok?, inspect(setting)
      end
    end

    test "every target needs :explain; a denial falls back to the next type or PGRST107" do
      context = %{plan_enabled: true, authorization: Hook}

      assert {:ok, %{kind: :plan}} =
               resolve("application/vnd.pgrst.plan", nil, context, targets: [])

      assert {:error, %Error{code: "PGRST107"}} =
               resolve("application/vnd.pgrst.plan", nil, context, targets: [@projects])

      assert {:ok, %{kind: :json}} =
               resolve("application/vnd.pgrst.plan, application/json", nil, context,
                 targets: [@projects]
               )
    end

    test "analyze of something that writes needs tx=rollback; a plain plan does not" do
      type = "application/vnd.pgrst.plan; options=analyze"
      opts = [targets: [], mutating?: true]

      assert {:error, %Error{code: "PGRST107"}} = resolve(type, nil, %{plan_enabled: true}, opts)

      assert {:ok, %{kind: :plan}} =
               resolve(type, nil, %{plan_enabled: true}, targets: [], mutating?: false)

      assert {:ok, %{kind: :plan}} =
               resolve("application/vnd.pgrst.plan", nil, %{plan_enabled: true}, opts)
    end

    test "the safe plan type is chosen when an unsafe analyze one precedes it" do
      accept =
        "application/vnd.pgrst.plan; options=analyze, application/vnd.pgrst.plan; options=verbose"

      assert {:ok, %{plan: %{options: [:verbose]}}} =
               resolve(accept, nil, %{plan_enabled: true}, targets: [], mutating?: true)
    end

    test "the plan_enabled function is not called without a plan type in Accept" do
      test = self()
      setting = fn _conn, _context -> send(test, :called) && true end

      assert {:ok, %{kind: :csv}} = resolve("text/csv", nil, %{plan_enabled: setting})
      refute_received :called

      assert {:ok, %{kind: :plan}} =
               resolve("application/vnd.pgrst.plan", nil, %{plan_enabled: setting}, targets: [])

      assert_received :called
    end
  end

  describe "negotiate/1" do
    test "is provisional: the plan type is never refused for the gate" do
      request = %Request{accepts: Accept.parse("application/vnd.pgrst.plan")}

      assert {:ok, %{kind: :plan}} = Negotiate.negotiate(request)
    end

    test "nothing acceptable fails early" do
      request = %Request{accepts: Accept.parse("text/unknown")}

      assert {:error, %Error{code: "PGRST107"}} = Negotiate.negotiate(request)
    end
  end
end
