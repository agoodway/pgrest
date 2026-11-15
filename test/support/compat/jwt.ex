defmodule PgRest.Compat.JWT do
  @moduledoc """
  Signs HS256 JWTs for the Supabase-shaped PostgREST instance. Test harness only.
  """

  @secret "reallyreallyreallyreallyverysafe"

  @doc "The shared secret of the Supabase-shaped PostgREST (docker-compose.yml)."
  @spec secret() :: binary()
  def secret, do: @secret

  @doc "Signs `claims` as a compact HS256 JWS."
  @spec sign(map(), binary()) :: String.t()
  def sign(claims, secret \\ @secret),
    do: sign_segments(segment(%{"alg" => "HS256", "typ" => "JWT"}), segment(claims), secret)

  @doc "Signs raw header and payload segments, for malformed tokens."
  @spec sign_segments(String.t(), String.t(), binary()) :: String.t()
  def sign_segments(header, payload, secret \\ @secret) do
    input = header <> "." <> payload
    input <> "." <> Base.url_encode64(:crypto.mac(:hmac, :sha256, secret, input), padding: false)
  end

  @doc "A JSON term as an unpadded base64url token segment."
  @spec segment(term()) :: String.t()
  def segment(term), do: term |> Jason.encode!() |> Base.url_encode64(padding: false)
end
