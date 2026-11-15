defmodule PgRest.Request.AcceptTest do
  use ExUnit.Case, async: true

  alias PgRest.MediaType
  alias PgRest.Request.Accept

  defp kinds(header), do: header |> Accept.parse() |> Enum.map(& &1.kind)

  test "a missing header is */*, an empty one lists nothing" do
    assert [%MediaType{kind: :any, raw: "*/*"}] = Accept.parse(nil)
    assert Accept.parse("") == []
  end

  test "types are sorted by q, highest first, stably" do
    assert [%{kind: :json}, %{kind: :csv, q: 0.5}] =
             Accept.parse("text/csv;q=0.5, application/json")

    assert ["text/b", "text/c", "text/a"] ==
             "text/a;q=0.1, text/b, text/c" |> Accept.parse() |> Enum.map(& &1.raw)
  end

  test "raw is the canonical name of a known type, the spaceless text of another" do
    header =
      "Application/JSON, TEXT/CSV;version=1, application/vnd.pgrst.object, " <>
        "text/plain; charset=utf-8, text/foo; version=1; q=0.5"

    assert header |> Accept.parse() |> Enum.map(& &1.raw) |> Enum.sort() ==
             Enum.sort([
               "application/json",
               "text/csv",
               "application/vnd.pgrst.object+json",
               "text/plain",
               "text/foo;version=1"
             ])
  end

  test "only a lowercase ;q= is a quality, and it ends the type" do
    assert [%{raw: "text/foo", q: 0.5}] = Accept.parse("text/foo; q=0.5; version=1")
    assert [%{raw: "text/foo;Q=0.5", q: 1.0}] = Accept.parse("text/foo;Q=0.5")
  end

  test "equal q: the more specific type first (parameters for, * against), then header order" do
    assert kinds("*/*, text/csv") == [:csv, :any]
    assert kinds("application/json, text/csv;version=1") == [:csv, :json]
    assert kinds("text/csv, application/json") == [:csv, :json]
    assert kinds("text/csv;q=0.5, */*") == [:any, :csv]

    assert ["text/bar;a=b", "text/foo", "text/baz"] ==
             "text/foo, text/bar;a=b, text/baz;q=0.5" |> Accept.parse() |> Enum.map(& &1.raw)
  end

  test "matching is case-insensitive" do
    assert kinds("Application/JSON, TEXT/CSV, Application/Vnd.Pgrst.Object+Json") ==
             [:json, :csv, :object]
  end

  test "the object and array types, with and without +json" do
    assert kinds(
             "application/vnd.pgrst.object, application/vnd.pgrst.object+json," <>
               "application/vnd.pgrst.array, application/vnd.pgrst.array+json"
           ) == [:object, :object, :array, :array]
  end

  test "nulls=stripped counts on the array and object types only, exactly" do
    stripped? = fn header ->
      [media] = Accept.parse(header)
      media.nulls_stripped?
    end

    assert stripped?.("application/vnd.pgrst.array+json;nulls=stripped")
    assert stripped?.("application/vnd.pgrst.object;nulls=stripped")
    refute stripped?.("application/vnd.pgrst.array+json")
    refute stripped?.("application/json;nulls=stripped")
    refute stripped?.("text/csv;nulls=stripped")
    refute stripped?.("application/vnd.pgrst.object+json;nulls=STRIPPED")
    assert stripped?.("application/vnd.pgrst.object+json;NULLS=stripped")
    assert stripped?.(~s|application/vnd.pgrst.array+json;nulls="stripped"|)
  end

  test "an unknown type, application/*, and geo+json are :other" do
    assert kinds("text/unknowntype, application/*, application/geo+json") == [
             :other,
             :other,
             :other
           ]
  end

  describe "the plan type" do
    test "format, for and options" do
      header =
        ~s|application/vnd.pgrst.plan+json; for="application/vnd.pgrst.object"; options=analyze\|buffers;|

      assert [%MediaType{kind: :plan, plan: plan}] = Accept.parse(header)

      assert %{format: :json, for: %MediaType{kind: :object}, options: [:analyze, :buffers]} =
               plan
    end

    test "text is the default format, +text names it" do
      assert [%{plan: %{format: :text, for: %MediaType{kind: :json}, options: []}}] =
               Accept.parse("application/vnd.pgrst.plan")

      assert [%{plan: %{format: :text}}] = Accept.parse("application/vnd.pgrst.plan+text")
    end

    test "supabase-js sends an empty options value and a trailing semicolon" do
      assert [%{plan: %{format: :json, options: []}}] =
               Accept.parse("application/vnd.pgrst.plan+json;options=;")
    end

    test "a quoted for may carry parameters, unknown options are ignored" do
      header =
        ~s|application/vnd.pgrst.plan+json; for="application/vnd.pgrst.array+json;nulls=stripped"; options=wal\|nope|

      assert [%{plan: %{for: %MediaType{kind: :array, nulls_stripped?: true}, options: [:wal]}}] =
               Accept.parse(header)
    end

    test "raw is PostgREST's canonical name: format, for= and options in canonical order" do
      for {header, raw} <- [
            {"application/vnd.pgrst.plan",
             ~s(application/vnd.pgrst.plan+text; for="application/json")},
            {~s(application/vnd.pgrst.plan+json;for="application/vnd.pgrst.object"),
             ~s(application/vnd.pgrst.plan+json; for="application/vnd.pgrst.object+json")},
            {~s(application/vnd.pgrst.plan; for="application/vnd.pgrst.array+json;nulls=stripped"),
             ~s(application/vnd.pgrst.plan+text; for="application/vnd.pgrst.array+json;nulls=stripped")},
            {~s(application/vnd.pgrst.plan; for="application/vnd.pgrst.array"),
             ~s(application/vnd.pgrst.plan+text; for="application/json")},
            {~s(application/vnd.pgrst.plan+json; for="TEXT/CSV"),
             ~s(application/vnd.pgrst.plan+json; for="text/csv")},
            {~s(application/vnd.pgrst.plan+json; for="*/*"),
             ~s(application/vnd.pgrst.plan+json; for="*/*")},
            {~s(application/vnd.pgrst.plan+json; for="text/xml"; options=wal\|verbose\|analyze),
             ~s(application/vnd.pgrst.plan+json; for="text/xml"; options=analyze\|verbose\|wal)},
            {"application/vnd.pgrst.plan+json; options=;",
             ~s(application/vnd.pgrst.plan+json; for="application/json")},
            {~s(application/vnd.pgrst.plan; for="application/vnd.pgrst.plan"),
             ~s(application/vnd.pgrst.plan+text; for="application/vnd.pgrst.plan+text; for="application/json"")}
          ] do
        assert [%MediaType{raw: ^raw}] = Accept.parse(header), header
      end
    end

    test "option names are exact: a differently cased one is ignored, as upstream" do
      assert [%{plan: %{options: [:verbose]}}] =
               Accept.parse("application/vnd.pgrst.plan; options=Analyze|verbose")
    end

    test "a comma inside quotes does not split the header" do
      assert [%{kind: :plan}, %{kind: :json}] =
               Accept.parse(~s|application/vnd.pgrst.plan; for="a,b", application/json|)
    end
  end
end
