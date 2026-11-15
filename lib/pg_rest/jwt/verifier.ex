defmodule PgRest.JWT.Verifier do
  @moduledoc """
  Verifies the bearer token of an RLS-mode request (`PgRest.Plug`'s `rls: [jwt: {module, opts}]`).

  `verify/2` returns the token's claims, or the `PgRest.Error` to answer with (PostgREST's 401
  `PGRST301`/`PGRST303`, built with `PgRest.Error.invalid_token/3`). `init/1`, when exported,
  validates `opts` once, when the plug is initialized, and returns what `verify/2` receives.
  `PgRest.JWT.HS256` is the built-in verifier.
  """

  @callback init(opts :: keyword()) :: keyword()
  @callback verify(token :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, PgRest.Error.t()}

  @optional_callbacks init: 1
end
