defmodule PgRest.ErrorTest do
  use ExUnit.Case, async: true

  alias PgRest.Error
  alias PgRest.Error.Translate

  defp pg_error(pg_code, fields \\ []) do
    postgres =
      Map.merge(
        %{
          code: :unique_violation,
          pg_code: pg_code,
          message: "duplicate key value violates unique constraint",
          detail: "Key (id)=(1) already exists.",
          hint: nil
        },
        Map.new(fields)
      )

    %Postgrex.Error{postgres: postgres}
  end

  describe "parse_error/2" do
    test "is a 400 PGRST100 with optional details" do
      assert %Error{status: 400, code: "PGRST100", message: "bad", details: nil, hint: nil} =
               Error.parse_error("bad")

      assert %Error{details: "why"} = Error.parse_error("bad", "why")
    end
  end

  describe "from_exception/3 with Postgrex errors" do
    test "maps a unique violation to 409 with Postgres' own fields" do
      assert %Error{
               status: 409,
               code: "23505",
               message: "duplicate key value violates unique constraint",
               details: "Key (id)=(1) already exists.",
               hint: nil
             } = Translate.from_exception(pg_error("23505"), :anon, [])
    end

    test "carries the Postgres hint" do
      error = Translate.from_exception(pg_error("22P02", hint: "Try a number."), :anon, [])
      assert error.hint == "Try a number."
    end

    for {code, status} <- [
          {"23503", 409},
          {"22P02", 400},
          {"23502", 400},
          {"P0001", 400},
          {"42P01", 404},
          {"42883", 404},
          {"42P17", 500},
          {"25006", 405},
          {"08006", 503},
          {"53300", 503},
          {"53400", 500},
          {"28000", 403},
          {"0P000", 403},
          {"40001", 500},
          {"P0002", 500},
          {"57014", 500},
          {"57P01", 503},
          {"XX000", 500},
          {"42703", 400},
          {"PT402", 402}
        ] do
      test "SQLSTATE #{code} maps to HTTP #{status}" do
        assert Translate.from_exception(pg_error(unquote(code)), :anon, []).status ==
                 unquote(status)
      end
    end

    test "42501 is 401 for anon and 403 for authenticated" do
      assert Translate.from_exception(pg_error("42501"), :anon, []).status == 401
      assert Translate.from_exception(pg_error("42501"), :authenticated, []).status == 403
    end

    test "a malformed PT code falls back to 500" do
      assert Translate.from_exception(pg_error("PTabc"), :anon, []).status == 500
    end

    test "21000 is 400 only for safeupdate messages" do
      safeupdate = pg_error("21000", message: "DELETE requires a WHERE clause")
      subquery = pg_error("21000", message: "more than one row returned by a subquery")

      assert Translate.from_exception(safeupdate, :anon, []).status == 400
      assert Translate.from_exception(subquery, :anon, []).status == 500
    end

    test "21000 with a nil message does not crash and is a 500" do
      assert Translate.from_exception(pg_error("21000", message: nil), :anon, []).status == 500
    end
  end

  describe "scrub_details?" do
    test "defaults to keeping details" do
      assert Translate.from_exception(pg_error("23505"), :anon, []).details =~ "Key (id)"
    end

    for code <- ~w(23502 23503 23505 23514 23P01) do
      test "drops details for #{code} but keeps message and hint" do
        error =
          Translate.from_exception(
            pg_error(unquote(code), hint: "h"),
            :anon,
            scrub_details?: true
          )

        assert error.details == nil
        assert error.message == "duplicate key value violates unique constraint"
        assert error.hint == "h"
      end
    end

    test "keeps details for 22P02" do
      error = Translate.from_exception(pg_error("22P02"), :anon, scrub_details?: true)
      assert error.details == "Key (id)=(1) already exists."
    end
  end

  describe "from_exception/3 with other exceptions" do
    test "returns a generic 500 and never leaks the exception" do
      error =
        Translate.from_exception(%RuntimeError{message: "secret SQL select * from x"}, :anon, [])

      assert %Error{status: 500, code: "PGRSTX00", details: nil, hint: nil} = error
      refute error.message =~ "secret"
    end

    test "a PgRest.Error passes through unchanged" do
      error = %Error{status: 413, code: "54000", message: "too big"}
      assert Translate.from_exception(error, :anon, scrub_details?: true) == error
    end

    test "a pool checkout timeout is a 504" do
      error =
        Translate.from_exception(%DBConnection.ConnectionError{reason: :queue_timeout}, :anon, [])

      assert %Error{status: 504, code: "PGRST003"} = error
      assert error.message == "Timed out acquiring connection from connection pool."
    end

    test "a Postgrex error without a postgres map is a 503 connection error" do
      error = Translate.from_exception(%Postgrex.Error{message: "tcp recv: closed"}, :anon, [])
      assert %Error{status: 503, code: "PGRST000", message: "Database connection error."} = error
      refute inspect(error) =~ "tcp"
    end
  end

  describe "to_body/1" do
    test "always has the four keys, nil as null" do
      body = Error.to_body(%Error{status: 400, code: "PGRST100", message: "bad"})

      assert body == %{"code" => "PGRST100", "message" => "bad", "details" => nil, "hint" => nil}
      assert Jason.encode!(body) =~ ~s("details":null)
    end

    test "exposes message through Exception.message/1" do
      assert Exception.message(%Error{status: 400, code: "X", message: "boom"}) == "boom"
    end
  end
end
