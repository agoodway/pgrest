defmodule PgRest.CatalogTest do
  # Not async: counts queries through a repo-wide telemetry event and clears a shared cache.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PgRest.Catalog
  alias PgRest.Compat.Repo

  defmodule FailingRepo do
    @moduledoc false
    # Stands in for a repo whose catalog query fails with the SQLSTATE in :pgrest_catalog_failure.
    def in_transaction?, do: false

    def transaction(_fun, _opts) do
      send(Application.fetch_env!(:pgrest, :pgrest_catalog_test_pid), :attempted)
      code = Application.fetch_env!(:pgrest, :pgrest_catalog_failure)
      raise Postgrex.Error, postgres: %{code: code, message: "boom", severity: "ERROR"}
    end
  end

  setup do
    Catalog.forget(Repo)
    on_exit(fn -> Catalog.forget(Repo) end)
  end

  @doc false
  def handle_query(_event, _measurements, %{query: query}, test) do
    if self() == test and String.contains?(query, "pg_attribute"), do: send(test, :catalog_query)
  end

  defp count_catalog_queries(fun) do
    test = self()
    id = {__MODULE__, System.unique_integer()}

    :telemetry.attach(id, [:pg_rest, :compat, :repo, :query], &__MODULE__.handle_query/4, test)

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    receive_all(0)
  end

  defp receive_all(n) do
    receive do
      :catalog_query -> receive_all(n + 1)
    after
      0 -> n
    end
  end

  describe "failures" do
    setup do
      Application.put_env(:pgrest, :pgrest_catalog_test_pid, self())
      on_exit(fn -> Catalog.forget(FailingRepo) end)
    end

    defp fail_with(code), do: Application.put_env(:pgrest, :pgrest_catalog_failure, code)

    test "a privilege failure warns once per repo and is cached as empty" do
      fail_with("42501")

      log =
        capture_log(fn ->
          assert Catalog.column_types(FailingRepo, "test", "a") == %{}
          assert Catalog.column_types(FailingRepo, "test", "a") == %{}
          assert Catalog.column_types(FailingRepo, "test", "b") == %{}
        end)

      assert_received :attempted
      assert_received :attempted
      refute_received :attempted
      assert [_one_warning] = Regex.scan(~r/could not read the catalog/, log)
    end

    test "a transient failure is re-raised and does not poison the cache" do
      fail_with("57014")
      assert_raise Postgrex.Error, fn -> Catalog.column_types(FailingRepo, "test", "a") end
      assert_raise Postgrex.Error, fn -> Catalog.column_types(FailingRepo, "test", "a") end
      assert_received :attempted
      assert_received :attempted
    end
  end

  describe "column_types/3" do
    test "maps type_cases columns to their format_type text" do
      assert %{
               "status" => "test.status_enum",
               "email" => email,
               "qty" => "integer",
               "at" => "timestamp with time zone",
               "price" => "numeric(10,2)"
             } = Catalog.column_types(Repo, "test", "type_cases")

      assert email in ["citext", "public.citext"]
    end

    test "column_categories/3 returns the typcategory letters" do
      assert %{"status" => "E", "email" => "S", "qty" => "N", "at" => "D", "id" => "N"} =
               Catalog.column_categories(Repo, "test", "type_cases")
    end

    test "an unknown table yields an empty map" do
      assert Catalog.column_types(Repo, "test", "no_such_table") == %{}
    end

    test "two calls hit the database once" do
      assert count_catalog_queries(fn ->
               Catalog.column_types(Repo, "test", "type_cases")
               Catalog.column_types(Repo, "test", "type_cases")
             end) == 1
    end

    test "forget/1 clears the cache" do
      assert count_catalog_queries(fn ->
               Catalog.column_types(Repo, "test", "type_cases")
               Catalog.forget(Repo)
               Catalog.column_types(Repo, "test", "type_cases")
             end) == 2
    end

    test "raises inside a transaction" do
      assert {:error, :raised} =
               Repo.transaction(fn ->
                 try do
                   Catalog.column_types(Repo, "test", "type_cases")
                 rescue
                   ArgumentError -> Repo.rollback(:raised)
                 end
               end)
    end

    test "does not leak the empty search_path into the caller" do
      Catalog.column_types(Repo, "test", "type_cases")
      assert %{rows: [[path]]} = Repo.query!("SHOW search_path")
      assert path != ""
    end
  end
end

defmodule PgRest.CatalogFactsTest do
  # Not async: counts queries through a repo-wide telemetry event and clears a shared cache.
  use ExUnit.Case, async: false

  alias PgRest.Catalog
  alias PgRest.Catalog.Facts
  alias PgRest.Compat.SupabaseRepo

  setup do
    Catalog.forget(SupabaseRepo)
    on_exit(fn -> Catalog.forget(SupabaseRepo) end)
  end

  @doc false
  def handle_query(_event, _measurements, %{query: query}, test) do
    cond do
      self() != test -> :ok
      String.contains?(query, "pg_timezone_names") -> send(test, {:query, :facts})
      String.contains?(query, "pg_attrdef") -> send(test, {:query, :defaults})
      true -> :ok
    end
  end

  defp count_queries(fun) do
    test = self()
    id = {__MODULE__, System.unique_integer()}

    :telemetry.attach(
      id,
      [:pg_rest, :compat, :supabase_repo, :query],
      &__MODULE__.handle_query/4,
      test
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end

    drain(%{})
  end

  defp drain(counts) do
    receive do
      {:query, kind} -> drain(Map.update(counts, kind, 1, &(&1 + 1)))
    after
      0 -> counts
    end
  end

  test "reads the server facts" do
    assert %Facts{timezones: zones, server_version_num: version, bypasses_rls?: true} =
             Catalog.facts(SupabaseRepo)

    assert MapSet.member?(zones, "America/Los_Angeles")
    assert MapSet.member?(zones, "UTC")
    assert is_integer(version) and version >= 160_000
  end

  test "reads the settings of the roles the login is a member of, as PostgREST (I4)" do
    Catalog.forget(PgRest.Compat.AuthenticatorRepo)

    assert %Facts{role_settings: settings} = Catalog.facts(PgRest.Compat.AuthenticatorRepo)

    assert settings["anon"] == [
             {"statement_timeout", "3s"},
             {"plan_cache_mode", "force_custom_plan"}
           ]

    assert settings["authenticated"] == [
             {"statement_timeout", "8s"},
             {"plan_cache_mode", "force_custom_plan"}
           ]

    refute Map.has_key?(settings, "service_role")
  end

  test "two calls hit the database once" do
    assert count_queries(fn ->
             Catalog.facts(SupabaseRepo)
             Catalog.facts(SupabaseRepo)
           end) == %{facts: 1}
  end

  test "records the login role (session_user), not the current role" do
    SupabaseRepo.checkout(fn ->
      SupabaseRepo.query!("SET ROLE anon")

      try do
        assert %{rows: [["anon"]]} = SupabaseRepo.query!("SELECT current_user::text")
        assert %Facts{bypasses_rls?: true} = Catalog.facts(SupabaseRepo)
      after
        SupabaseRepo.query!("RESET ROLE")
      end
    end)
  end

  test "coexists with column_defaults/3 and forget/1 clears both" do
    load = fn ->
      Catalog.facts(SupabaseRepo)
      Catalog.column_defaults(SupabaseRepo, "public", "messages")
    end

    assert count_queries(fn ->
             load.()
             load.()
             Catalog.forget(SupabaseRepo)
             load.()
           end) == %{facts: 2, defaults: 2}
  end
end
