defmodule PgRest.JWT.HS256 do
  @moduledoc """
  HS256 bearer-token verification (`PgRest.JWT.Verifier`), with PostgREST's errors and claim
  rules: `exp`, `nbf` and `iat` are checked with `:leeway` seconds of clock skew, `aud` against
  `:audience` when one is set.

  ## Options

    * `:secret` (required) - at least 32 bytes: a binary, `{:system, "ENV_VAR"}`,
      `{module, function, args}` or a zero-arity function. A source other than a binary is
      resolved on every verification, so the secret need not exist when the router compiles.
      A literal binary under 32 bytes raises at init; a resolved secret that is missing or
      too short is a 500, logged without its value.
    * `:audience` - the expected `aud` (default `nil`: any `aud` that is a string or an array
      of strings)
    * `:leeway` - seconds of clock skew (default `30`, PostgREST's)

  ## Differences from PostgREST

    * A missing or short secret is a generic 500 `PGRSTX00`; PostgREST answers `PGRST300`
      `Server lacks JWT secret`. Only a server-side message is logged, never the value.
  """

  @behaviour PgRest.JWT.Verifier

  alias PgRest.{Error, Options}

  require Logger

  @min_bytes 32
  @keys [:secret, :audience, :leeway]
  # JWS algorithms other than HS256: PostgREST has no key for them.
  @other_algs ~w(HS384 HS512 RS256 RS384 RS512 ES256 ES384 ES512 PS256 PS384 PS512 EdDSA)
  @time_claims [{"exp", :past}, {"nbf", :future}, {"iat", :future}]

  @impl PgRest.JWT.Verifier
  @spec init(keyword()) :: keyword()
  def init(opts) do
    unless Keyword.keyword?(opts),
      do: raise(ArgumentError, "PgRest.JWT.HS256 options must be a keyword list")

    Options.validate_keys!(opts, @keys, "PgRest.JWT.HS256")

    opts = Keyword.merge([audience: nil, leeway: 30], opts)
    secret_source!(Keyword.get(opts, :secret))

    unless is_nil(opts[:audience]) or is_binary(opts[:audience]),
      do: raise(ArgumentError, "PgRest.JWT.HS256 :audience must be a string or nil")

    unless is_integer(opts[:leeway]) and opts[:leeway] >= 0,
      do: raise(ArgumentError, "PgRest.JWT.HS256 :leeway must be a non-negative integer")

    opts
  end

  defp secret_source!(secret) when is_binary(secret) and byte_size(secret) >= @min_bytes, do: :ok

  defp secret_source!(secret) when is_binary(secret),
    do: raise(ArgumentError, "PgRest.JWT.HS256 :secret must be at least #{@min_bytes} bytes")

  defp secret_source!({:system, var}) when is_binary(var), do: :ok
  defp secret_source!({m, f, a}) when is_atom(m) and is_atom(f) and is_list(a), do: :ok
  defp secret_source!(fun) when is_function(fun, 0), do: :ok

  defp secret_source!(_other) do
    raise ArgumentError,
          "PgRest.JWT.HS256 requires :secret: a binary, {:system, var}, an MFA or a function"
  end

  @impl PgRest.JWT.Verifier
  @spec verify(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def verify("", _opts), do: decode_error("Empty JWT is sent in Authorization header")

  def verify(token, opts) do
    with {:ok, [header, payload, signature]} <- parts(token),
         {:ok, %{} = fields} <- json(header),
         :ok <- algorithm(fields),
         {:ok, mac} <- base64(signature),
         {:ok, body} <- base64(payload),
         {:ok, secret} <- secret(opts[:secret]),
         :ok <- signature(header <> "." <> payload, mac, secret),
         {:ok, claims} <- claims(body),
         :ok <- validate(claims, opts) do
      {:ok, claims}
    end
  end

  defp parts(token) do
    case String.split(token, ".") do
      [_, _, _] = parts -> {:ok, parts}
      parts -> decode_error("Expected 3 parts in JWT; got #{length(parts)}")
    end
  end

  # PostgREST's JOSE library fails every undecodable segment with `BadCrypto`.
  defp json(segment) do
    with {:ok, binary} <- base64(segment),
         {:ok, %{} = map} <- Jason.decode(binary) do
      {:ok, map}
    else
      _ -> crypto_failed()
    end
  end

  # Unpadded base64url, as RFC 7515 requires.
  defp base64(segment) do
    with false <- String.contains?(segment, "="),
         {:ok, binary} <- Base.url_decode64(segment, padding: false) do
      {:ok, binary}
    else
      _ -> crypto_failed()
    end
  end

  defp algorithm(%{"alg" => "none"}),
    do:
      decode_error(
        "Wrong or unsupported encoding algorithm",
        "JWT is unsecured but expected 'alg' was not 'none'"
      )

  defp algorithm(%{"alg" => "HS256", "kid" => _}), do: no_key()
  defp algorithm(%{"alg" => "HS256"}), do: :ok
  defp algorithm(%{"alg" => alg}) when alg in @other_algs, do: no_key()
  defp algorithm(_fields), do: crypto_failed()

  defp secret(source) do
    case resolve(source) do
      secret when is_binary(secret) and byte_size(secret) >= @min_bytes ->
        {:ok, secret}

      _missing ->
        Logger.error(
          "PgRest.JWT.HS256: the JWT secret is missing or shorter than #{@min_bytes} bytes"
        )

        {:error, Error.internal()}
    end
  end

  defp resolve({:system, var}), do: System.get_env(var)
  defp resolve({m, f, a}), do: apply(m, f, a)
  defp resolve(fun) when is_function(fun, 0), do: fun.()
  defp resolve(secret), do: secret

  defp signature(input, mac, secret) do
    expected = :crypto.mac(:hmac, :sha256, secret, input)

    if Plug.Crypto.secure_compare(expected, mac),
      do: :ok,
      else:
        decode_error(
          "No suitable key or wrong key type",
          "None of the keys was able to decode the JWT"
        )
  end

  defp claims(body) do
    case Jason.decode(body) do
      {:ok, %{} = claims} -> {:ok, claims}
      _ -> claims_error("Parsing claims failed")
    end
  end

  # PostgREST's order: exp, nbf, iat, then aud; the first failure wins.
  defp validate(claims, opts) do
    now = System.os_time(:second)

    with :ok <- times(claims, now, opts[:leeway]),
         do: audience(Map.get(claims, "aud"), opts[:audience])
  end

  defp times(claims, now, leeway) do
    Enum.reduce_while(@time_claims, :ok, fn {name, direction}, :ok ->
      case time_claim(Map.get(claims, name), direction, now, leeway) do
        :ok -> {:cont, :ok}
        {:error, kind} -> {:halt, time_error(name, kind)}
      end
    end)
  end

  defp time_claim(nil, _direction, _now, _leeway), do: :ok

  defp time_claim(value, direction, now, leeway) when is_number(value) do
    if out_of_range?(direction, seconds(value), now, leeway), do: {:error, :range}, else: :ok
  end

  defp time_claim(_value, _direction, _now, _leeway), do: {:error, :type}

  defp out_of_range?(:past, seconds, now, leeway), do: now - leeway > seconds
  defp out_of_range?(:future, seconds, now, leeway), do: now + leeway < seconds

  # PostgREST reads a number that is not a 64-bit integer as 0 (so a fractional `exp` has
  # expired).
  @int64 -0x8000000000000000..0x7FFFFFFFFFFFFFFF
  defp seconds(value) when is_integer(value) and value in @int64, do: value
  defp seconds(value) when is_float(value) and value == trunc(value), do: seconds(trunc(value))
  defp seconds(_value), do: 0

  defp time_error(name, :type), do: claims_error("The JWT '#{name}' claim must be a number")
  defp time_error("exp", :range), do: claims_error("JWT expired")
  defp time_error("nbf", :range), do: claims_error("JWT not yet valid")
  defp time_error("iat", :range), do: claims_error("JWT issued at future")

  defp audience(nil, _expected), do: :ok

  defp audience(aud, expected) when is_binary(aud),
    do: audience_match(aud == expected or is_nil(expected))

  defp audience(auds, expected) when is_list(auds) do
    if Enum.all?(auds, &is_binary/1),
      do: audience_match(auds == [] or is_nil(expected) or expected in auds),
      else: aud_type_error()
  end

  defp audience(_aud, _expected), do: aud_type_error()

  defp audience_match(true), do: :ok
  defp audience_match(false), do: claims_error("JWT not in audience")

  defp aud_type_error,
    do: claims_error("The JWT 'aud' claim must be a string or an array of strings")

  defp no_key,
    do:
      decode_error(
        "No suitable key or wrong key type",
        "No suitable key was found to decode the JWT"
      )

  defp crypto_failed, do: decode_error("JWT cryptographic operation failed")

  defp decode_error(message, details \\ nil),
    do: {:error, Error.invalid_token(:decode, message, details)}

  defp claims_error(message), do: {:error, Error.invalid_token(:claims, message)}
end
