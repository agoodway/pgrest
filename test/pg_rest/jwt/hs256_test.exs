defmodule PgRest.JWT.HS256Test do
  # `{:system, _}` cases write the environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias PgRest.Compat.JWT
  alias PgRest.Error
  alias PgRest.JWT.HS256

  @secret JWT.secret()
  @env "PGREST_HS256_TEST_SECRET"

  defp opts(extra \\ []), do: HS256.init(Keyword.merge([secret: @secret], extra))
  defp now, do: System.os_time(:second)

  defp decode_error(message, details \\ nil) do
    %Error{
      status: 401,
      code: "PGRST301",
      message: message,
      details: details,
      headers: [{"www-authenticate", invalid_token(message)}]
    }
  end

  defp claims_error(message) do
    %Error{
      status: 401,
      code: "PGRST303",
      message: message,
      headers: [{"www-authenticate", invalid_token(message)}]
    }
  end

  defp invalid_token(message),
    do: ~s|Bearer error="invalid_token", error_description="#{message}"|

  describe "verify/2 accepts" do
    test "a valid token, returning its claims" do
      token = JWT.sign(%{"role" => "authenticated", "sub" => "alice"})

      assert {:ok, %{"role" => "authenticated", "sub" => "alice"}} = HS256.verify(token, opts())
    end

    test "a token that expired within the 30 second leeway" do
      token = JWT.sign(%{"exp" => now() - 20})
      assert {:ok, _claims} = HS256.verify(token, opts())
    end

    test "null and missing time claims, and a matching or empty audience" do
      assert {:ok, _} = HS256.verify(JWT.sign(%{"exp" => nil, "nbf" => nil}), opts())
      assert {:ok, _} = HS256.verify(JWT.sign(%{"aud" => "x"}), opts(audience: "x"))
      assert {:ok, _} = HS256.verify(JWT.sign(%{"aud" => ["y", "x"]}), opts(audience: "x"))
      assert {:ok, _} = HS256.verify(JWT.sign(%{"aud" => []}), opts(audience: "x"))
      assert {:ok, _} = HS256.verify(JWT.sign(%{"aud" => "other"}), opts())
    end
  end

  describe "verify/2 rejects, with PostgREST's PGRST301 decode errors" do
    test "an empty token" do
      assert HS256.verify("", opts()) ==
               {:error, decode_error("Empty JWT is sent in Authorization header")}
    end

    test "a token without three parts" do
      assert HS256.verify("a.b", opts()) ==
               {:error, decode_error("Expected 3 parts in JWT; got 2")}

      assert HS256.verify("a.b.c.d", opts()) ==
               {:error, decode_error("Expected 3 parts in JWT; got 4")}
    end

    test "a wrong signature" do
      token = JWT.sign(%{"role" => "authenticated"}, String.duplicate("w", 32))

      assert HS256.verify(token, opts()) ==
               {:error,
                decode_error(
                  "No suitable key or wrong key type",
                  "None of the keys was able to decode the JWT"
                )}
    end

    test "alg none" do
      token = JWT.segment(%{"alg" => "none"}) <> "." <> JWT.segment(%{"role" => "x"}) <> "."

      assert HS256.verify(token, opts()) ==
               {:error,
                decode_error(
                  "Wrong or unsupported encoding algorithm",
                  "JWT is unsecured but expected 'alg' was not 'none'"
                )}
    end

    test "another algorithm, or a key id" do
      no_key =
        {:error,
         decode_error(
           "No suitable key or wrong key type",
           "No suitable key was found to decode the JWT"
         )}

      for header <- [%{"alg" => "HS512"}, %{"alg" => "RS256"}, %{"alg" => "HS256", "kid" => "k"}] do
        assert HS256.verify(JWT.sign_segments(JWT.segment(header), JWT.segment(%{})), opts()) ==
                 no_key
      end
    end

    test "undecodable segments" do
      failed = {:error, decode_error("JWT cryptographic operation failed")}
      header = JWT.segment(%{"alg" => "HS256"})

      assert HS256.verify(JWT.sign_segments("!!!", JWT.segment(%{})), opts()) == failed

      assert HS256.verify(
               JWT.sign_segments(JWT.segment(%{"typ" => "JWT"}), JWT.segment(%{})),
               opts()
             ) == failed

      assert HS256.verify(
               JWT.sign_segments(JWT.segment(%{"alg" => "hs256"}), JWT.segment(%{})),
               opts()
             ) == failed

      assert HS256.verify(JWT.sign_segments(header, "!!!"), opts()) == failed
      assert HS256.verify(JWT.sign_segments(header, JWT.segment(%{}) <> "=="), opts()) == failed
      assert HS256.verify(header <> "." <> JWT.segment(%{}) <> ".!!!", opts()) == failed
    end
  end

  describe "verify/2 rejects, with PostgREST's PGRST303 claims errors" do
    test "a payload that is not a JSON object" do
      header = JWT.segment(%{"alg" => "HS256"})
      parsing = {:error, claims_error("Parsing claims failed")}

      assert HS256.verify(JWT.sign_segments(header, JWT.segment([1])), opts()) == parsing

      assert HS256.verify(
               JWT.sign_segments(header, Base.url_encode64("x", padding: false)),
               opts()
             ) ==
               parsing
    end

    test "an expired token (60 s ago), or one with a fractional exp" do
      assert HS256.verify(JWT.sign(%{"exp" => now() - 60}), opts()) ==
               {:error, claims_error("JWT expired")}

      # PostgREST reads a non-integral time claim as 0.
      assert HS256.verify(JWT.sign(%{"exp" => now() + 100.5}), opts()) ==
               {:error, claims_error("JWT expired")}
    end

    test "nbf and iat in the future" do
      assert HS256.verify(JWT.sign(%{"nbf" => now() + 120}), opts()) ==
               {:error, claims_error("JWT not yet valid")}

      assert HS256.verify(JWT.sign(%{"iat" => now() + 120}), opts()) ==
               {:error, claims_error("JWT issued at future")}
    end

    test "time claims that are not numbers" do
      for claim <- ~w(exp nbf iat) do
        assert HS256.verify(JWT.sign(%{claim => "x"}), opts()) ==
                 {:error, claims_error("The JWT '#{claim}' claim must be a number")}
      end
    end

    test "an aud that is not a string or an array of strings" do
      message = "The JWT 'aud' claim must be a string or an array of strings"

      for aud <- [1, ["a", 1]] do
        assert HS256.verify(JWT.sign(%{"aud" => aud}), opts()) == {:error, claims_error(message)}
      end
    end

    test "an aud that does not match audience:" do
      assert HS256.verify(JWT.sign(%{"aud" => "y"}), opts(audience: "x")) ==
               {:error, claims_error("JWT not in audience")}

      assert HS256.verify(JWT.sign(%{"aud" => ["y"]}), opts(audience: "x")) ==
               {:error, claims_error("JWT not in audience")}
    end

    test "the signature before the claims" do
      token = JWT.sign(%{"exp" => 1}, String.duplicate("w", 32))
      assert {:error, %Error{code: "PGRST301"}} = HS256.verify(token, opts())
    end
  end

  describe "secret sources (resolved at verify time)" do
    test "{:system, var} reads the variable when verifying" do
      verify_opts = HS256.init(secret: {:system, @env})
      System.put_env(@env, @secret)
      on_exit(fn -> System.delete_env(@env) end)

      assert {:ok, _} = HS256.verify(JWT.sign(%{"role" => "anon"}), verify_opts)
    end

    test "an MFA and a zero-arity function" do
      token = JWT.sign(%{"role" => "anon"})

      assert {:ok, _} = HS256.verify(token, HS256.init(secret: {__MODULE__, :secret, []}))
      assert {:ok, _} = HS256.verify(token, HS256.init(secret: fn -> @secret end))
    end

    test "an unset variable is a 500 whose log line holds no secret bytes" do
      System.delete_env(@env)
      token = JWT.sign(%{"role" => "anon"})

      log =
        capture_log(fn ->
          assert {:error, %Error{status: 500, code: "PGRSTX00"}} =
                   HS256.verify(token, HS256.init(secret: {:system, @env}))
        end)

      assert log =~ "JWT secret"
      refute log =~ @secret
      refute log =~ token
    end

    test "a resolved secret under 32 bytes is a 500 without the value in the log" do
      short = "short-secret-value"

      log =
        capture_log(fn ->
          assert {:error, %Error{status: 500}} =
                   HS256.verify(JWT.sign(%{}, short), HS256.init(secret: fn -> short end))
        end)

      refute log =~ short
    end
  end

  describe "init/1" do
    test "raises for a literal secret under 32 bytes, a bad source or unknown keys" do
      assert_raise ArgumentError, ~r/32 bytes/, fn -> HS256.init(secret: "short") end
      assert_raise ArgumentError, fn -> HS256.init([]) end
      assert_raise ArgumentError, fn -> HS256.init(secret: 123) end
      assert_raise ArgumentError, fn -> HS256.init(secret: @secret, leeway: -1) end
      assert_raise ArgumentError, fn -> HS256.init(secret: @secret, audience: 1) end
      assert_raise ArgumentError, fn -> HS256.init(secret: @secret, nope: 1) end
    end

    test "never puts a literal secret in an error message" do
      error = assert_raise ArgumentError, fn -> HS256.init(secret: "tiny-secret") end
      refute Exception.message(error) =~ "tiny-secret"
    end

    test "defaults leeway to 30 and audience to nil" do
      assert opts() |> Keyword.take([:leeway, :audience]) |> Enum.sort() ==
               [audience: nil, leeway: 30]
    end
  end

  @doc false
  def secret, do: @secret
end
