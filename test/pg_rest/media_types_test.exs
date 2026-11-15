defmodule PgRest.MediaTypesTest do
  # Not async: registries over the shared compat fixture, and committed writes.
  use ExUnit.Case, async: false

  import PgRest.PlugCase, only: [header: 2, json: 1, register: 1, request: 5]

  alias PgRest.{Catalog, MediaType}
  alias PgRest.Compat.{Functions, Repo, Resources}
  alias PgRest.Test.{PlugResources, TelemetryProbe}

  @opts [tx_end: :commit_allow_override]

  defp call(method, path, headers, body \\ nil, opts \\ []),
    do: request(method, path, body, headers, Keyword.merge(@opts, opts))

  defp accept(type), do: [{"accept", type}]

  describe "Content-Type" do
    setup do
      start_supervised!({PgRest.Registry, modules: Resources.all()})
      :ok
    end

    test "spacing is PostgREST's" do
      for {type, expected} <- [
            {"application/json", "application/json; charset=utf-8"},
            {"application/vnd.pgrst.object+json",
             "application/vnd.pgrst.object+json; charset=utf-8"},
            {"application/vnd.pgrst.object+json;nulls=stripped",
             "application/vnd.pgrst.object+json;nulls=stripped; charset=utf-8"},
            {"application/vnd.pgrst.array+json;nulls=stripped",
             "application/vnd.pgrst.array+json;nulls=stripped; charset=utf-8"},
            {"application/vnd.pgrst.array+json", "application/json; charset=utf-8"},
            {"text/csv", "text/csv; charset=utf-8"}
          ] do
        conn = call("GET", "/organizations?limit=1&select=id", accept(type))

        assert conn.status == 200, type
        assert header(conn, "content-type") == expected, type
      end
    end

    test "content_type/1 of the default is JSON" do
      assert MediaType.content_type(MediaType.json()) == "application/json; charset=utf-8"
    end

    test "an error body is JSON whatever was asked for" do
      conn = call("GET", "/organizations?id=bad", accept("text/csv"))

      assert conn.status == 400
      assert header(conn, "content-type") == "application/json; charset=utf-8"
      assert json(conn)["code"] == "PGRST100"
    end

    test "geo+json is a PGRST107" do
      conn = call("GET", "/projects", accept("application/geo+json"))

      assert conn.status == 406

      assert json(conn) == %{
               "code" => "PGRST107",
               "details" => nil,
               "hint" => nil,
               "message" => "None of these media types are available: application/geo+json"
             }
    end

    test "the plan type is a PGRST107 while plan_enabled is false (the default)" do
      conn = call("GET", "/projects", accept("application/vnd.pgrst.plan+json"))

      assert conn.status == 406
      assert json(conn)["code"] == "PGRST107"
    end

    test "CSV: header, then one line per row" do
      conn = call("GET", "/clients?select=id,name&order=id&limit=2", accept("text/csv"))

      assert conn.resp_body == "id,name\n1,Microsoft\n2,Apple"
    end

    test "HEAD with CSV has no body" do
      conn = call("HEAD", "/clients?select=id", accept("text/csv"))

      assert conn.status == 200
      assert conn.resp_body == ""
      assert header(conn, "content-type") == "text/csv; charset=utf-8"
    end

    test "stripped nulls reach embedded and JSON-column values" do
      conn =
        call(
          "GET",
          "/organizations?select=id,referee(id,referee)&id=eq.3",
          accept("application/vnd.pgrst.array+json;nulls=stripped")
        )

      assert json(conn) == [%{"id" => 3, "referee" => %{"id" => 1}}]
    end

    test "the object type still needs exactly one row, stripped or not" do
      conn =
        call(
          "GET",
          "/organizations?select=id",
          accept("application/vnd.pgrst.object+json;nulls=stripped")
        )

      assert conn.status == 406
      assert json(conn)["code"] == "PGRST116"
      assert header(conn, "content-type") == "application/json; charset=utf-8"
    end
  end

  # The static CSV header carries select= aliases, which are request text.
  describe "the CSV header names are bound, never spliced" do
    setup do
      start_supervised!(
        {PgRest.Registry,
         modules: Resources.all(), introspect: [repo: Repo, only: Functions.test_functions()]}
      )

      TelemetryProbe.attach([:pgrest, :query, :start])
      :ok
    end

    @alias "x\\',(select pg_sleep(5))--"
    @evil "x\\\\',(select pg_sleep(5))--"
    @quoted URI.encode_www_form(~s|"| <> @evil <> ~s|"|)

    defp sql_texts, do: for({_e, _m, %{sql: sql}} <- TelemetryProbe.drain(), do: sql)

    test "an RPC alias with a quote and a backslash is a correct header, not a SQL literal" do
      conn = call("GET", "/rpc/getallprojects?select=#{@quoted}:name&limit=0", accept("text/csv"))

      assert conn.status == 200
      assert conn.resp_body == @alias <> "\n"
      refute Enum.any?(sql_texts(), &String.contains?(&1, "'x"))
    end

    test "a write alias is a correct header, even with standard_conforming_strings off" do
      # Catalog loads must finish before the caller-owned transaction begins.
      Catalog.forget(Repo)
      assert call("GET", "/projects?select=name&limit=0", accept("text/csv")).status == 200

      Repo.transaction(fn ->
        Repo.query!("SET LOCAL standard_conforming_strings = off")

        conn =
          call(
            "POST",
            "/projects?select=#{@quoted}:name",
            [{"accept", "text/csv"}, {"prefer", "return=representation, tx=rollback"}],
            %{"id" => 900, "name" => "new", "client_id" => 1}
          )

        assert conn.status == 201
        assert conn.resp_body == @alias <> "\nnew"
        Repo.rollback(:done)
      end)

      refute Enum.any?(sql_texts(), &String.contains?(&1, "'x"))
    end
  end

  describe "an RPC runs once" do
    setup do
      start_supervised!(
        {PgRest.Registry,
         modules: Resources.all(), introspect: [repo: Repo, only: Functions.test_functions()]}
      )

      :ok
    end

    # The sequence advances outside the transaction, so it counts executions even though the
    # POST rolls back.
    test "as CSV with an exact count and a window" do
      before = callcounter_value()

      conn =
        call(
          "POST",
          "/rpc/callcounter?limit=1",
          [{"accept", "text/csv"}, {"prefer", "count=exact, tx=rollback"}]
        )

      assert conn.status == 200
      assert conn.resp_body == "pgrst_scalar\n#{before + 1}"
      assert callcounter_value() == before + 1
    end

    test "as stripped nulls with an exact count" do
      before = callcounter_value()

      conn =
        call(
          "POST",
          "/rpc/callcounter",
          [
            {"accept", "application/vnd.pgrst.object+json;nulls=stripped"},
            {"prefer", "count=exact, tx=rollback"}
          ]
        )

      assert conn.status == 200
      assert callcounter_value() == before + 1
    end

    test "a void function is a 204 whatever the type" do
      conn = call("POST", "/rpc/ret_void", [{"accept", "text/csv"}, {"prefer", "tx=rollback"}])

      assert conn.status == 204
      assert conn.resp_body == ""
      assert header(conn, "content-type") == nil
    end

    defp callcounter_value do
      %{rows: [[value, called?]]} =
        Repo.query!("SELECT last_value, is_called FROM test.callcounter_count")

      if called?, do: value, else: value - 1
    end
  end

  # `after_load/2` works on decoded JSON rows: CSV, or rows stripped of nulls, would leave it
  # nothing to work on, so the request is refused (PGRST107) before any write.
  describe "an after_load/2 resource" do
    setup do
      register([PlugResources.TrimProjects, PlugResources.TrimClients, PlugResources.TrimTasks])
      :ok
    end

    test "is not answered as CSV" do
      conn = call("GET", "/projects?select=id", accept("text/csv"))

      assert conn.status == 406
      assert json(conn)["code"] == "PGRST107"
      assert json(conn)["message"] == "None of these media types are available: text/csv"
    end

    test "is not answered with the nulls stripped" do
      conn =
        call(
          "GET",
          "/projects?select=id",
          accept("application/vnd.pgrst.array+json;nulls=stripped")
        )

      assert conn.status == 406
      assert json(conn)["code"] == "PGRST107"
    end

    test "a write asking for CSV representation is refused before it runs" do
      conn =
        call(
          "POST",
          "/projects",
          [{"accept", "text/csv"}, {"prefer", "return=representation"}],
          %{"id" => 900, "name" => "never", "client_id" => 1}
        )

      assert conn.status == 406
      assert %{rows: [[0]]} = Repo.query!("SELECT count(*) FROM test.projects WHERE id = 900")
    end

    test "a client that also accepts JSON falls back to it, on a read and a write" do
      conn = call("GET", "/projects?select=id&limit=1", accept("text/csv, application/json"))
      assert conn.status == 200
      assert header(conn, "content-type") == "application/json; charset=utf-8"

      conn =
        call(
          "PATCH",
          "/projects?id=eq.1&select=id",
          [
            {"accept", "application/vnd.pgrst.array+json;nulls=stripped, */*"},
            {"prefer", "return=representation, tx=rollback"}
          ],
          %{"name" => "same"}
        )

      assert conn.status == 200
      assert header(conn, "content-type") == "application/json; charset=utf-8"
    end

    test "PATCH and DELETE asking only for CSV are refused before they run" do
      patch =
        call(
          "PATCH",
          "/projects?id=eq.1",
          [{"accept", "text/csv"}, {"prefer", "return=representation"}],
          %{
            "name" => "never"
          }
        )

      delete =
        call("DELETE", "/projects?id=eq.5", [
          {"accept", "text/csv"},
          {"prefer", "return=representation"}
        ])

      assert {patch.status, delete.status} == {406, 406}
      assert %{rows: [[1]]} = Repo.query!("SELECT count(*) FROM test.projects WHERE id = 5")
      assert %{rows: [["Windows 7"]]} = Repo.query!("SELECT name FROM test.projects WHERE id = 1")
    end

    test "an after_load/2 resource only in an embed refuses CSV too" do
      conn = call("GET", "/tasks?select=id,projects(id)&limit=1", accept("text/csv"))

      assert conn.status == 406
      assert json(conn)["code"] == "PGRST107"
    end

    test "still answers JSON" do
      conn = call("GET", "/projects?select=id&limit=1", accept("application/json"))

      assert conn.status == 200
    end
  end
end
