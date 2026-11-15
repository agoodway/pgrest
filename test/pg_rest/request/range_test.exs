defmodule PgRest.Request.RangeTest do
  use ExUnit.Case, async: true

  alias PgRest.Request.Range

  defp from(method, headers, params), do: Range.from(method, headers, params)

  test "no range at all" do
    assert {:ok, %{offset: 0, limit: nil}} = from("GET", [], [])
  end

  test "Range header" do
    assert {:ok, %{offset: 0, limit: 10}} = from("GET", [{"range", "0-9"}], [])
    assert {:ok, %{offset: 5, limit: nil}} = from("GET", [{"range", "5-"}], [])
    assert {:ok, %{offset: 0, limit: nil}} = from("GET", [{"range", "abc"}], [])
  end

  test "Range header is ignored for every method but GET" do
    for method <- ~w(HEAD POST PATCH DELETE) do
      assert {:ok, %{offset: 0, limit: nil}} = from(method, [{"range", "0-9"}], [])
    end
  end

  test "limit and offset" do
    assert {:ok, %{offset: 2, limit: 3}} = from("GET", [], [{"limit", "3"}, {"offset", "2"}])
    assert {:ok, %{offset: 12, limit: nil}} = from("GET", [], [{"offset", "12"}])
    assert {:ok, %{offset: 0, limit: 4}} = from("GET", [], [{"limit", "4"}])
    assert {:ok, %{offset: 0, limit: nil}} = from("GET", [], [{"limit", "abc"}])
    assert {:ok, %{offset: 100, limit: nil}} = from("GET", [], [{"offset", "100"}])
  end

  test "an unparseable limit counts as limit=0 only when an offset is present (recorded)" do
    assert {:ok, %{offset: 0, limit: 0}} = from("GET", [], [{"limit", "abc"}, {"offset", "0"}])

    assert {:error, %PgRest.Error{status: 416}} =
             from("GET", [], [{"limit", "abc"}, {"offset", "5"}])

    assert {:ok, %{offset: 0, limit: nil}} = from("GET", [], [{"limit", "abc"}])
  end

  test "the last of repeated limit params wins" do
    assert {:ok, %{limit: 7}} = from("GET", [], [{"limit", "3"}, {"limit", "7"}])
  end

  test "header and limit/offset ranges are intersected" do
    assert {:ok, %{offset: 2, limit: 3}} =
             from("GET", [{"range", "0-4"}], [{"limit", "5"}, {"offset", "2"}])

    assert {:ok, %{offset: 1, limit: 2}} =
             from("GET", [{"range", "0-9"}], [{"limit", "2"}, {"offset", "1"}])
  end

  test "disjoint ranges are 416 PGRST103 with the negative-limit details" do
    assert {:error, %PgRest.Error{status: 416, code: "PGRST103"} = error} =
             from("GET", [{"range", "0-2"}], [{"limit", "3"}, {"offset", "10"}])

    assert error.message == "Requested range not satisfiable"
    assert error.details == "Limit should be greater than or equal to zero."
  end

  test "an inverted Range header is 416 with the lower/upper details" do
    assert {:error, %PgRest.Error{status: 416, code: "PGRST103", details: details}} =
             from("GET", [{"range", "9-0"}], [])

    assert details ==
             "The lower boundary must be lower than or equal to the upper boundary in the Range header."
  end

  test "limit=0 bypasses the Range header and gives an empty page" do
    assert {:ok, %{offset: 0, limit: 0}} = from("GET", [], [{"limit", "0"}])
    assert {:ok, %{offset: 0, limit: 0}} = from("GET", [{"range", "0-4"}], [{"limit", "0"}])
  end

  test "limit=0 with a positive offset is not the zero-limit case (recorded: 416)" do
    assert {:error, %PgRest.Error{status: 416, code: "PGRST103"}} =
             from("GET", [], [{"limit", "0"}, {"offset", "3"}])
  end

  test "negative limit is 416" do
    assert {:error, %PgRest.Error{status: 416, code: "PGRST103", details: details}} =
             from("GET", [], [{"limit", "-1"}])

    assert details == "Limit should be greater than or equal to zero."
  end

  test "negative offsets clamp to zero as recorded" do
    assert {:ok, %{offset: 0, limit: nil}} = from("GET", [], [{"offset", "-1"}])
    assert {:ok, %{offset: 0, limit: 2}} = from("GET", [], [{"limit", "3"}, {"offset", "-1"}])
    assert {:ok, %{offset: 0, limit: 0}} = from("GET", [], [{"limit", "1"}, {"offset", "-1"}])

    assert {:error, %PgRest.Error{status: 416}} =
             from("GET", [], [{"limit", "2"}, {"offset", "-5"}])
  end

  test "PUT rejects limit/offset with PGRST114" do
    assert {:error, %PgRest.Error{status: 400, code: "PGRST114"} = error} =
             from("PUT", [], [{"limit", "1"}])

    assert error.message == "limit/offset querystring parameters are not allowed for PUT"
    assert {:ok, %{offset: 0, limit: nil}} = from("PUT", [], [])
  end
end
