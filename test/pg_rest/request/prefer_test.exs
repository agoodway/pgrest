defmodule PgRest.Request.PreferTest do
  use ExUnit.Case, async: true

  alias PgRest.Catalog.Facts
  alias PgRest.{Error, Prefer}
  alias PgRest.Request.Prefer, as: Parser

  test "defaults" do
    assert Parser.parse([]) == %Prefer{handling: :lenient, unknown: []}
  end

  test "parses tokens with whitespace around tokens" do
    assert Parser.parse(["return=representation,   count=exact  ", "tx=rollback"]) ==
             %Prefer{
               return: :representation,
               count: :exact,
               tx: :rollback,
               handling: :lenient,
               unknown: [],
               tokens: ["return=representation", "count=exact", "tx=rollback"]
             }
  end

  test "remembers whether the client sent handling" do
    refute Parser.parse(["count=exact"]).handling_sent
    assert %{handling: :lenient, handling_sent: true} = Parser.parse(["handling=lenient"])

    assert %{handling: :strict, handling_sent: true} =
             Parser.parse(["count=exact, handling=strict"])

    refute Parser.parse(["handling=bogus"]).handling_sent
  end

  test "parses every recognized value" do
    prefer =
      Parser.parse([
        "resolution=ignore-duplicates, missing=null, handling=strict",
        "return=headers-only,count=estimated,timezone=America/Chicago,max-affected=5"
      ])

    assert %Prefer{
             resolution: :ignore_duplicates,
             missing: :null,
             handling: :strict,
             return: :headers_only,
             count: :estimated,
             timezone: "America/Chicago",
             max_affected: 5
           } = prefer

    assert Parser.parse(["resolution=merge-duplicates", "missing=default", "return=minimal"])
           |> Map.take([:resolution, :missing, :return]) ==
             %{resolution: :merge_duplicates, missing: :default, return: :minimal}

    assert Parser.parse(["count=planned"]).count == :planned
  end

  test "unrecognized tokens are collected, including whitespace around =" do
    assert Parser.parse(["foo=bar"]).unknown == ["foo=bar"]
    assert Parser.parse(["return=bogus, anything"]).unknown == ["return=bogus", "anything"]

    prefer = Parser.parse(["count = exact"])
    assert prefer.count == nil
    assert prefer.unknown == ["count = exact"]
  end

  test "an empty token from a trailing comma is unknown; an empty header is nothing" do
    assert Parser.parse(["count=exact,"]).unknown == [""]
    assert Parser.parse([""]).unknown == []
  end

  test "timezone= and max-affected= are never unknown; the first token claims the slot" do
    prefer = Parser.parse(["max-affected=abc, max-affected=5, timezone=UTC"])
    assert prefer.max_affected == nil
    assert prefer.timezone == "UTC"
    assert prefer.unknown == []

    # PostgREST reads any integer, `0` included (`max-affected=0` rejects any affected row).
    assert Parser.parse(["max-affected=0"]).max_affected == 0
    assert Parser.parse(["max-affected=-1"]).max_affected == -1
    assert Parser.parse(["max-affected=+1"]).max_affected == nil
    assert Parser.parse(["max-affected=0"]).unknown == []
  end

  test "an unrecognized value of a known key is unknown, as the raw token" do
    assert Parser.parse(["return=foo"]).unknown == ["return=foo"]
    assert Parser.parse(["count=bogus", "tx=maybe"]).unknown == ["count=bogus", "tx=maybe"]
    assert Parser.parse(["max-affected=abc"]).unknown == []
  end

  test "the first recognized value wins, across tokens and headers" do
    assert Parser.parse(["return=minimal, return=representation"]).return == :minimal
    assert Parser.parse(["tx=commit", "tx=rollback"]).tx == :commit
    assert Parser.parse(["return=bogus, return=minimal"]).return == :minimal
    assert Parser.parse(["timezone=UTC, timezone=Asia/Tokyo"]).timezone == "UTC"
  end

  describe "applied_header/2" do
    test "renders only applied keys in PostgREST order" do
      prefer =
        Parser.parse([
          "tx=rollback, count=exact, return=representation, resolution=merge-duplicates"
        ])

      assert Parser.applied_header(prefer, [:tx, :count, :return, :resolution]) ==
               "resolution=merge-duplicates, return=representation, count=exact, tx=rollback"

      assert Parser.applied_header(prefer, [:count]) == "count=exact"
    end

    test "nil when nothing applied or the applied preference is unset" do
      assert Parser.applied_header(Parser.parse([]), []) == nil
      assert Parser.applied_header(Parser.parse(["count=exact"]), [:return]) == nil
    end

    test "handling, timezone and max-affected (only under strict)" do
      prefer = Parser.parse(["handling=strict, timezone=UTC, max-affected=3"])

      assert Parser.applied_header(prefer, [:max_affected, :timezone, :handling]) ==
               "handling=strict, timezone=UTC, max-affected=3"

      lenient = Parser.parse(["max-affected=3"])
      assert Parser.applied_header(lenient, [:max_affected]) == nil
    end
  end

  describe "validate/2" do
    @facts %Facts{
      timezones: MapSet.new(["UTC", "America/Los_Angeles"]),
      server_version_num: 140_000,
      bypasses_rls?: false
    }

    defp validate(headers), do: headers |> Parser.parse() |> Parser.validate(@facts)

    test "lenient accepts anything unknown" do
      assert {:ok, %Prefer{unknown: ["anything"]}} = validate(["anything"])
      assert {:ok, %Prefer{handling: :lenient}} = validate(["handling=lenient, anything"])
    end

    test "strict with an unknown token is PGRST122 listing them in request order" do
      assert {:error,
              %Error{
                status: 400,
                code: "PGRST122",
                message: "Invalid preferences given with handling=strict",
                details: "Invalid preferences: anything"
              }} = validate(["handling=strict, anything"])

      assert {:error, %Error{details: "Invalid preferences: something, else"}} =
               validate(["handling=strict", "something, else"])
    end

    test "strict with only valid preferences passes" do
      assert {:ok, %Prefer{handling: :strict, timezone: "UTC", max_affected: 5}} =
               validate(["handling=strict, timezone=UTC, max-affected=5, return=minimal"])
    end

    test "a timezone outside the server's names is dropped when lenient" do
      assert {:ok, %Prefer{timezone: nil, unknown: []}} = validate(["timezone=Invalid/Timezone"])

      assert {:ok, %Prefer{timezone: nil}} =
               validate(["handling=lenient, timezone=Invalid/Timezone"])
    end

    test "a valid timezone is kept" do
      assert {:ok, %Prefer{timezone: "America/Los_Angeles"}} =
               validate(["timezone=America/Los_Angeles"])
    end

    test "strict with an invalid timezone names the token, mixed with unknown ones in order" do
      assert {:error,
              %Error{code: "PGRST122", details: "Invalid preferences: timezone=Invalid/Timezone"}} =
               validate(["handling=strict, timezone=Invalid/Timezone"])

      assert {:error, %Error{details: "Invalid preferences: nope, timezone=Nowhere, later"}} =
               validate(["handling=strict, nope, timezone=Nowhere, later"])
    end

    test "the first timezone token decides, like PostgREST" do
      assert {:ok, %Prefer{timezone: "UTC"}} =
               validate(["handling=strict, timezone=UTC, timezone=Nowhere"])

      assert {:error, %Error{details: "Invalid preferences: timezone=Nowhere, timezone=UTC"}} =
               validate(["handling=strict, timezone=Nowhere, timezone=UTC"])
    end
  end
end
