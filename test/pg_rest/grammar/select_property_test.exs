defmodule PgRest.Grammar.SelectPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PgRest.AST.{Aggregate, SelectField}
  alias PgRest.Grammar.{Common, Select}
  alias PgRest.SQL.Builder

  @bad_chars ~c|();"'-/*.\\<>=|

  defp cast_char_gen do
    [?a..?z, ?A..?Z, ?0..?9, [?_, ?\s, ?$]] |> Enum.concat() |> member_of()
  end

  defp candidate_gen do
    gen all(
          head <- member_of(Enum.concat([?a..?z, [?_]])),
          rest <- list_of(cast_char_gen(), max_length: 70),
          array? <- boolean()
        ) do
      IO.iodata_to_binary([head, rest, if(array?, do: "[]", else: "")])
    end
  end

  property "every cast the shared rule accepts parses, and only those" do
    check all(name <- candidate_gen()) do
      result = Select.parse("id::" <> name)

      trimmed = String.trim_trailing(name)

      if Common.cast_name?(trimmed) do
        assert {:ok, [%SelectField{cast: ^trimmed}]} = result

        # Every cast the grammar accepts must also pass Builder.cast/2's own check (they
        # share Common.cast_name?/1), so a parsed cast can never raise at SQL emission.
        assert IO.iodata_to_binary(Builder.cast("x", trimmed)) == "CAST(x AS #{trimmed})"
      else
        assert {:error, %PgRest.Error{code: "PGRST100"}} = result
      end
    end
  end

  property "every aggregate cast the grammar accepts matches the cast rule and emits one CAST" do
    check all(
            input_cast <- one_of([constant(nil), binary(max_length: 70)]),
            cast <- one_of([constant(nil), binary(max_length: 70)])
          ) do
      input =
        IO.iodata_to_binary([
          "id",
          if(input_cast, do: ["::", input_cast], else: []),
          ".sum()",
          if(cast, do: ["::", cast], else: [])
        ])

      case Select.parse(input) do
        {:ok, items} ->
          for %Aggregate{} = agg <- items, type <- [agg.input_cast, agg.cast], type != nil do
            assert Common.cast_name?(type)
            assert IO.iodata_to_binary(Builder.cast("x", type)) == "CAST(x AS #{type})"
          end

        {:error, error} ->
          assert %PgRest.Error{status: 400, code: "PGRST100"} = error
      end
    end
  end

  # Near-valid type names: identifier words joined by one or two spaces, `$`, an optional `[]`,
  # lengths around the 63-byte limit, and sometimes an injected `)`, `;`, quote, comma or `--`.
  defp near_cast_gen do
    word = string(Enum.concat([?a..?z, ?A..?Z, [?_]]), min_length: 1, max_length: 8)

    gen all(
          words <- list_of(word, min_length: 1, max_length: 4),
          sep <- member_of([" ", "  "]),
          dollar? <- boolean(),
          array? <- boolean(),
          pad <- integer(0..66),
          inject <- member_of([nil, nil, nil, ")", ";", "'", ~s("), ",", "--"])
        ) do
      base = Enum.join(words, sep) <> if(dollar?, do: "$1", else: "")
      padded = base <> String.duplicate("x", max(pad - byte_size(base), 0))
      IO.iodata_to_binary([padded, if(array?, do: "[]", else: ""), inject || ""])
    end
  end

  property "near-valid aggregate casts: accepted ones are exactly the cast rule's" do
    check all(cast <- near_cast_gen(), input <- member_of([:input, :result])) do
      select = if input == :input, do: "id::#{cast}.sum()", else: "id.sum()::#{cast}"
      trimmed = String.trim(cast)

      case Select.parse(select) do
        {:ok, [%Aggregate{} = agg | _rest]} ->
          type = if input == :input, do: agg.input_cast, else: agg.cast
          assert Common.cast_name?(type)
          assert IO.iodata_to_binary(Builder.cast("x", type)) == "CAST(x AS #{type})"

        {:error, error} ->
          assert %PgRest.Error{status: 400, code: "PGRST100"} = error
          refute Common.cast_name?(trimmed)
      end
    end
  end

  property "a character outside the cast set is always a 400" do
    check all(
            head <- member_of(Enum.concat([?a..?z, [?_]])),
            rest <- list_of(cast_char_gen(), max_length: 20),
            bad <- member_of(@bad_chars),
            tail <- string([?a..?z], max_length: 3)
          ) do
      input = IO.iodata_to_binary(["id::", head, rest, bad, tail])
      assert {:error, %PgRest.Error{status: 400, code: "PGRST100"}} = Select.parse(input)
    end
  end
end
