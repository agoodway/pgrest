defmodule PgRest.Grammar.Common do
  @moduledoc """
  Building blocks shared by the PostgREST grammars: quoted values, identifiers,
  field names with JSON paths, tree paths, the cast-name rule, and error helpers.

  The `defcombinator` pieces are reused by other grammar modules through
  `parsec({PgRest.Grammar.Common, name})`.
  """

  import NimbleParsec

  alias PgRest.AST.Field
  alias PgRest.Error

  @blank_chars [?\s, ?\t]
  @name_expecting "field name (* or [a..z0..9_$])"

  # One definition of a cast type name: words of `[A-Za-z_][A-Za-z0-9_$]*` separated by
  # single spaces (`character varying`), at most 63 bytes. `$` only appears inside a word.
  @cast_name ~r/\A[A-Za-z_][A-Za-z0-9_$]*( [A-Za-z_][A-Za-z0-9_$]*)*\z/
  # The characters a cast can be made of, used to take the run to validate.
  @cast_chars ~r/\A[A-Za-z0-9_ $]*/
  @max_cast_name_bytes 63

  # letter | digit | "_" | " " | "$", with every non-ASCII code point accepted as a letter.
  @ident_chars [?a..?z, ?A..?Z, ?0..?9, ?_, ?\s, ?$, 128..0x10FFFF]

  @join {IO, :iodata_to_binary, []}
  @trim {String, :trim, []}

  @control_names ~w(NUL SOH STX ETX EOT ENQ ACK a b t n v f r SO SI DLE DC1 DC2 DC3 DC4 NAK SYN
                    ETB CAN EM SUB ESC FS GS RS US)

  defcombinator(:blank, ascii_string(@blank_chars, min: 1))

  # A "..." value where backslash escapes the next character.
  defcombinator(
    :quoted_value,
    ignore(string(~s(")))
    |> repeat(
      choice([
        utf8_string([not: ?\\, not: ?"], min: 1),
        ignore(string("\\")) |> utf8_string([], 1)
      ])
    )
    |> ignore(string(~s(")))
    |> reduce(@join)
  )

  # Everything up to the next `,` or `)`, possibly empty: an unquoted list/logic value.
  defcombinator(
    :raw_value,
    optional(utf8_string([not: ?,, not: ?)], min: 1)) |> reduce(@join)
  )

  defcombinator(:identifier, utf8_string(@ident_chars, min: 1) |> map(@trim))

  # Pieces separated by a dash that does not start a `->` / `->>` arrow.
  sep_by_dash = fn piece ->
    dash = string("-") |> lookahead_not(string(">")) |> ignore()

    piece
    |> repeat(dash |> concat(piece))
    |> reduce({Enum, :join, ["-"]})
  end

  defcombinator(
    :field_name,
    choice([parsec(:quoted_value), sep_by_dash.(parsec(:identifier))])
  )

  key_ident =
    [not: ?(, not: ?-, not: ?:, not: ?., not: ?,, not: ?>, not: ?)]
    |> utf8_string(min: 1)
    |> map(@trim)

  index =
    optional(string("-"))
    |> ascii_string([?0..?9], min: 1)
    |> lookahead(choice([string("->"), string("::"), string("."), string(","), eos()]))
    |> reduce({__MODULE__, :to_index, []})

  json_operand = choice([index, choice([parsec(:quoted_value), sep_by_dash.(key_ident)])])

  json_step =
    [string("->>") |> replace(:double_arrow), string("->") |> replace(:arrow)]
    |> choice()
    |> concat(json_operand)
    |> reduce({List, :to_tuple, []})

  defcombinator(:json_path, repeat(json_step))

  defcombinator(
    :field,
    parsec(:field_name) |> parsec(:json_path) |> reduce({__MODULE__, :build_field, []})
  )

  names = parsec(:field_name) |> repeat(ignore(string(".")) |> parsec(:field_name))

  defparsecp(:names_p, names)

  # Upstream `pTreePath`: dotted names (embed path, last is the column) plus a JSON path.
  defparsecp(
    :tree_path_p,
    names |> parsec(:json_path) |> reduce({__MODULE__, :build_tree_path, []})
  )

  defparsecp(
    :field_with_blanks,
    ignore(optional(parsec(:blank))) |> parsec(:field) |> ignore(optional(parsec(:blank)))
  )

  @doc false
  @spec to_index([String.t()]) :: integer()
  def to_index(parts), do: parts |> Enum.join() |> String.to_integer()

  @doc false
  @spec build_field([String.t() | Field.json_step()]) :: Field.t()
  def build_field([name | json_path]), do: %Field{name: name, json_path: json_path}

  @doc false
  @spec build_tree_path([String.t() | Field.json_step()]) :: {[String.t()], Field.t()}
  def build_tree_path(parts) do
    {names, json_path} = Enum.split_while(parts, &is_binary/1)
    {embeds, [column]} = Enum.split(names, -1)
    {embeds, %Field{name: column, json_path: json_path}}
  end

  @doc """
  Parses a field (name plus JSON path), ignoring spaces and tabs around it.

  Returns the field and the unparsed rest, or `{:error, input}` when no field starts
  the input.
  """
  @spec parse_field(String.t()) :: {:ok, Field.t(), String.t()} | {:error, String.t()}
  def parse_field(input) do
    case input |> field_with_blanks() |> unwrap(input) do
      {:ok, [field], rest} -> {:ok, field, rest}
      {:error, _rest} = error -> error
    end
  end

  @doc """
  Like `parse_field/1`, but a failure is `{:fail, input, expecting}`.
  """
  @spec parse_field(String.t(), String.t()) ::
          {:ok, Field.t(), String.t()} | {:fail, String.t(), String.t()}
  def parse_field(input, expecting) do
    case parse_field(input) do
      {:ok, _field, "->>-" <> rest} -> {:fail, rest, "digit"}
      {:ok, _field, "->-" <> rest} -> {:fail, rest, "digit"}
      {:error, rest} -> {:fail, rest, expecting}
      parsed -> parsed
    end
  end

  @doc """
  Parses a bare name (no JSON path), returning it and the rest, or `:no_match`.
  """
  @spec parse_name(String.t()) :: {:ok, String.t(), String.t()} | :no_match
  def parse_name(input) do
    case parse_field(input) do
      {:ok, %Field{name: name, json_path: []}, rest} -> {:ok, name, rest}
      _ -> :no_match
    end
  end

  @doc """
  Parses a query-string key such as `a.b.col->x` into its embed path and column field
  (upstream `pTreePath`). The whole key must be consumed.
  """
  @spec parse_tree_path(String.t()) :: {:ok, {[String.t()], Field.t()}} | {:error, Error.t()}
  def parse_tree_path(key) do
    with :ok <- reject_nul(key),
         {:ok, [{embeds, field}], ""} <- key |> tree_path_p() |> unwrap(key),
         :ok <- validate_field(field),
         :ok <- reject_nul(embeds) do
      {:ok, {embeds, field}}
    else
      {:ok, _parsed, rest} -> {:error, path_error("tree path", key, rest)}
      {:error, %Error{}} = error -> error
      {:error, rest} -> {:error, path_error("tree path", key, rest)}
    end
  end

  @doc """
  Parses dotted names (`client.not.or`), consuming the whole text. Returns the names or
  a `PGRST100` error naming `what`.
  """
  @spec parse_names(String.t(), String.t()) :: {:ok, [String.t()]} | {:error, Error.t()}
  def parse_names(key, what) do
    with :ok <- reject_nul(key) do
      case key |> names_p() |> unwrap(key) do
        {:ok, names, ""} -> {:ok, names}
        {:ok, _names, rest} -> {:error, path_error(what, key, rest)}
        {:error, rest} -> {:error, path_error(what, key, rest)}
      end
    end
  end

  defp path_error(what, key, rest),
    do: syntax_error(what, key, key, rest, @name_expecting)

  @doc false
  @spec unwrap(tuple(), String.t()) :: {:ok, list(), String.t()} | {:error, String.t()}
  def unwrap({:ok, acc, rest, _context, _position, _offset}, _input), do: {:ok, acc, rest}
  def unwrap({:error, _reason, _rest, _context, _position, _offset}, input), do: {:error, input}

  @doc """
  Whether `name` is an acceptable cast type name (see the module attributes for the
  rule). This is the single definition used by the select grammar and `Builder.cast/2`.
  """
  @spec cast_name?(term()) :: boolean()
  def cast_name?(name) when is_binary(name) and byte_size(name) <= @max_cast_name_bytes,
    do: Regex.match?(@cast_name, name)

  def cast_name?(_name), do: false

  @doc """
  Takes the cast name at the start of `rest` (after a `::`) and validates it with
  `cast_name?/1`. Returns the name and the rest with blanks skipped.
  """
  @spec take_cast(String.t()) :: {:ok, String.t(), String.t()} | {:fail, String.t(), String.t()}
  def take_cast(rest) do
    [run] = Regex.run(@cast_chars, rest)
    name = String.trim(run)

    cond do
      name == "" ->
        {:fail, rest, "letter or digit"}

      cast_name?(name) ->
        {:ok, name,
         skip_blanks(binary_part(rest, byte_size(run), byte_size(rest) - byte_size(run)))}

      true ->
        {:fail, rest, "valid type name"}
    end
  end

  @doc """
  Rejects a text (or a list of texts) that contains a NUL byte, for identifiers.
  """
  @spec reject_nul(String.t() | [String.t()]) :: :ok | {:error, Error.t()}
  def reject_nul(texts) do
    if texts |> List.wrap() |> Enum.any?(&String.contains?(&1, <<0>>)),
      do:
        {:error,
         Error.parse_error("Invalid identifier", "Identifiers cannot contain a NUL byte.")},
      else: :ok
  end

  @doc """
  Rejects a field whose name or JSON-path keys contain a NUL byte.
  """
  @spec validate_field(Field.t()) :: :ok | {:error, Error.t()}
  def validate_field(%Field{name: name, json_path: json_path}),
    do: reject_nul([name | for({_arrow, key} <- json_path, is_binary(key), do: key)])

  @doc "The expectation text for a missing field name."
  @spec name_expecting() :: String.t()
  def name_expecting, do: @name_expecting

  @doc """
  Builds a PostgREST-style parse error: the message names the parsed `what` and the
  column of the failure, the details say what was found and what was expected.

  `full_input` is the text the parser saw, `rest` the unparsed remainder at the failure
  point, `shown` the text echoed in the message. Option `quote: :string` shows the
  unexpected character as a string (`"x"`) even where Parsec would show a character.
  """
  @spec syntax_error(String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          Error.t()
  def syntax_error(what, shown, full_input, rest, expecting, opts \\ []) do
    consumed = binary_part(full_input, 0, byte_size(full_input) - byte_size(rest))
    column = length(for <<_::utf8 <- consumed>>, do: 1) + 1

    Error.parse_error(
      "\"failed to parse #{what} (#{shown})\" (line 1, column #{column})",
      "unexpected #{unexpected(rest, expecting, opts)} expecting #{expecting}"
    )
  end

  @doc false
  @spec skip_blanks(String.t()) :: String.t()
  def skip_blanks(<<char, rest::binary>>) when char in @blank_chars, do: skip_blanks(rest)
  def skip_blanks(rest), do: rest

  defp unexpected("", _expecting, _opts), do: "end of input"

  defp unexpected(rest, expecting, opts) do
    case mismatch(rest, expecting) do
      nil -> "end of input"
      char -> hs_show(char, quote_char(expecting, opts))
    end
  end

  # Parsec shows a lone character in single quotes when the failed alternative was a
  # character parser (the expectation ends the input), otherwise as a string.
  defp quote_char(expecting, opts) do
    if opts[:quote] != :string and String.ends_with?(expecting, "end of input"), do: ?', else: ?"
  end

  # Parsec's `string` reports the first character that differs from the first expected
  # literal, not the first character of the input.
  defp mismatch(rest, expecting) do
    case Regex.run(~r/\A"([^"]+)"/, expecting, capture: :all_but_first) do
      [literal] -> first_difference(String.codepoints(rest), String.codepoints(literal), rest)
      nil -> first_codepoint(rest)
    end
  end

  defp first_difference([same | rest], [same | literal], input),
    do: first_difference(rest, literal, input)

  defp first_difference([char | _rest], [_other | _literal], _input), do: char
  defp first_difference([], [_ | _], _input), do: nil
  defp first_difference(_rest, [], input), do: first_codepoint(input)

  defp first_codepoint(<<char::utf8, _::binary>>), do: <<char::utf8>>
  defp first_codepoint(<<_invalid, _::binary>>), do: <<0xFFFD::utf8>>

  # Haskell `show` for a string (`"`) or a character (`'`).
  defp hs_show(text, quote), do: <<quote>> <> hs_escape(text, quote) <> <<quote>>

  defp hs_escape(<<>>, _quote), do: ""
  defp hs_escape(<<quote, rest::binary>>, quote), do: <<?\\, quote>> <> hs_escape(rest, quote)
  defp hs_escape(<<?\\, rest::binary>>, quote), do: "\\\\" <> hs_escape(rest, quote)

  defp hs_escape(<<char::utf8, rest::binary>>, quote) when char in 32..126,
    do: <<char::utf8>> <> hs_escape(rest, quote)

  defp hs_escape(<<14::utf8, ?H, rest::binary>>, quote), do: "\\SO\\&H" <> hs_escape(rest, quote)

  defp hs_escape(<<char::utf8, rest::binary>>, quote) when char < 32,
    do: "\\" <> Enum.at(@control_names, char) <> hs_escape(rest, quote)

  defp hs_escape(<<127::utf8, rest::binary>>, quote), do: "\\DEL" <> hs_escape(rest, quote)

  defp hs_escape(<<char::utf8, rest::binary>>, quote),
    do: "\\#{char}" <> hs_gap(rest) <> hs_escape(rest, quote)

  # Invalid UTF-8 decodes to U+FFFD upstream.
  defp hs_escape(<<_invalid, rest::binary>>, quote),
    do: "\\65533" <> hs_gap(rest) <> hs_escape(rest, quote)

  # `\&` separates a numeric escape from a digit that follows it.
  defp hs_gap(<<digit, _::binary>>) when digit in ?0..?9, do: "\\&"
  defp hs_gap(_rest), do: ""
end
