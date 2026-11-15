defmodule PgRest.Prefer do
  @moduledoc """
  The parsed `Prefer` request header.

  `nil` means the client did not send that preference; `handling` defaults to
  `:lenient` and `handling_sent` tells whether the client sent one. Tokens PgRest does
  not recognize are kept in `unknown`, and every token in `tokens` (request order), so
  `PgRest.Request.Prefer.validate/2` can list the invalid ones in the order they were sent.
  `max_affected` is any integer the client sent (`0` included) and `nil` when it did not
  parse. Built by `PgRest.Request.Prefer.parse/1`.
  """

  defstruct return: nil,
            count: nil,
            resolution: nil,
            missing: nil,
            handling: :lenient,
            handling_sent: false,
            tx: nil,
            max_affected: nil,
            timezone: nil,
            unknown: [],
            tokens: []

  @type t :: %__MODULE__{
          return: :minimal | :headers_only | :representation | nil,
          count: :exact | :planned | :estimated | nil,
          resolution: :merge_duplicates | :ignore_duplicates | nil,
          missing: :default | :null | nil,
          handling: :lenient | :strict,
          handling_sent: boolean(),
          tx: :commit | :rollback | nil,
          max_affected: integer() | nil,
          timezone: String.t() | nil,
          unknown: [String.t()],
          tokens: [String.t()]
        }
end
