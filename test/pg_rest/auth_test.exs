defmodule PgRest.AuthTest do
  use ExUnit.Case, async: true

  alias PgRest.{Auth, Error}
  alias PgRest.Compat.JWT

  @secret JWT.secret()
  @roles ["anon", "authenticated", "service_role"]

  defp rls(extra \\ []),
    do: Auth.init(Keyword.merge([roles: @roles, jwt: {PgRest.JWT.HS256, secret: @secret}], extra))

  defp conn(authorization \\ nil) do
    conn = Plug.Test.conn("GET", "/rls_notes")

    if authorization,
      do: Plug.Conn.put_req_header(conn, "authorization", authorization),
      else: conn
  end

  defp bearer(claims), do: conn("Bearer " <> JWT.sign(claims))
  defp resolve(conn, rls), do: Auth.resolve(conn, rls, %{}, &Auth.default_anonymous?/2)

  describe "init/1" do
    test "requires a non-empty roles: allowlist and jwt:" do
      assert_raise ArgumentError, ~r/roles/, fn -> Auth.init(jwt: :context) end
      assert_raise ArgumentError, ~r/roles/, fn -> Auth.init(roles: [], jwt: :context) end
      assert_raise ArgumentError, ~r/jwt/, fn -> Auth.init(roles: ["anon"]) end
    end

    test "rejects pseudo-roles in roles:" do
      for pseudo <- ~w(none session_user current_user public) do
        assert_raise ArgumentError, ~r/#{pseudo}/, fn ->
          Auth.init(roles: ["anon", pseudo], jwt: :context)
        end
      end
    end

    test "requires a non-nil default_role: to be in roles:" do
      assert_raise ArgumentError, ~r/default_role/, fn ->
        Auth.init(roles: ["authenticated"], jwt: :context)
      end

      assert %{default_role: nil} =
               Auth.init(roles: ["authenticated"], jwt: :context, default_role: nil)
    end

    test "validates role_claim:, pre_request:, allow_privileged_login: and unknown keys" do
      assert_raise ArgumentError, fn -> rls(role_claim: []) end
      assert_raise ArgumentError, fn -> rls(role_claim: 1) end
      assert_raise ArgumentError, fn -> rls(pre_request: "no_schema") end
      assert_raise ArgumentError, fn -> rls(pre_request: ".fn") end
      assert_raise ArgumentError, fn -> rls(allow_privileged_login: "yes") end
      assert_raise ArgumentError, fn -> rls(nope: 1) end
      assert_raise ArgumentError, fn -> rls(jwt: {String, []}) end
    end

    test "never inspects a value that is not a keyword list (M7)" do
      error = assert_raise ArgumentError, fn -> Auth.init(%{secret: "s3cret-in-a-map"}) end
      refute Exception.message(error) =~ "s3cret"
    end

    test "runs the verifier's init/1 (a short literal secret raises)" do
      assert_raise ArgumentError, ~r/32 bytes/, fn ->
        rls(jwt: {PgRest.JWT.HS256, secret: "x"})
      end
    end

    test "splits pre_request: on the first dot and quotes both identifiers" do
      assert %{pre_request: ~s|SELECT "public"."check.request"()|} =
               rls(pre_request: "public.check.request")
    end

    test "fills the defaults" do
      assert %{role_claim: ["role"], default_role: "anon", pre_request: nil} = rls()
      assert %{allow_privileged_login: false} = rls()
    end

    test "PgRest.Plug.init/1 validates rls: through it" do
      assert_raise ArgumentError, ~r/roles/, fn ->
        PgRest.Plug.init(repo: PgRest.Compat.Repo, rls: [roles: ["anon", "none"], jwt: :context])
      end
    end
  end

  describe "resolve/4 in RLS mode" do
    test "no Authorization header is the default role" do
      assert {:ok, %{db_role: "anon", claims: %{"role" => "anon"}, authenticated?: false}} =
               resolve(conn(), rls())
    end

    test "a token's role claim, inserted into the claims" do
      assert {:ok, %{db_role: "authenticated", authenticated?: true, claims: claims}} =
               resolve(bearer(%{"role" => "authenticated", "sub" => "alice"}), rls())

      assert claims == %{"role" => "authenticated", "sub" => "alice"}
    end

    test "a token without a role claim is the default role" do
      assert {:ok, %{db_role: "anon", authenticated?: false, claims: %{"sub" => "alice"}}} =
               resolve(bearer(%{"sub" => "alice"}), rls())
    end

    test "the bearer scheme is case-insensitive; other schemes are anonymous" do
      token = JWT.sign(%{"role" => "authenticated"})

      for header <- ["bearer " <> token, "BEARER   " <> token] do
        assert {:ok, %{db_role: "authenticated"}} = resolve(conn(header), rls())
      end

      assert {:ok, %{db_role: "anon"}} = resolve(conn("Basic abc"), rls())
      assert {:error, %Error{code: "PGRST301"}} = resolve(conn("Bearer"), rls())
    end

    test "verifier errors are returned" do
      assert {:error, %Error{status: 401, message: "Expected 3 parts in JWT; got 2"}} =
               resolve(conn("Bearer a.b"), rls())
    end

    test "a role outside the allowlist is PostgREST's 401 22023, pseudo-roles included" do
      for role <- ~w(none session_user postgres nope) do
        assert resolve(bearer(%{"role" => role}), rls()) ==
                 {:error,
                  %Error{status: 401, code: "22023", message: ~s|role "#{role}" does not exist|}}
      end
    end

    test "a role claim that is not a string is its JSON text, as in PostgREST" do
      assert {:error, %Error{message: ~s|role "123" does not exist|}} =
               resolve(bearer(%{"role" => 123}), rls())

      assert {:error, %Error{message: ~s|role "null" does not exist|}} =
               resolve(bearer(%{"role" => nil}), rls())
    end

    test "a key-path role_claim: is accepted only when the role is in roles:" do
      claims = %{"user_metadata" => %{"role" => "service_role"}}
      path = ["user_metadata", "role"]

      assert {:ok, %{db_role: "service_role", claims: %{"role" => "service_role"}}} =
               resolve(bearer(claims), rls(role_claim: path))

      assert {:error, %Error{code: "22023"}} =
               resolve(bearer(claims), rls(role_claim: path, roles: ["anon", "authenticated"]))
    end

    test "no default_role: makes an anonymous request PGRST302" do
      no_anon = rls(roles: ["authenticated"], default_role: nil)

      assert resolve(conn(), no_anon) == {:error, Error.token_required()}
      assert resolve(bearer(%{"sub" => "x"}), no_anon) == {:error, Error.token_required()}

      assert {:ok, %{db_role: "authenticated", authenticated?: true}} =
               resolve(bearer(%{"role" => "authenticated"}), no_anon)
    end

    test "jwt: :context takes the claims the context builder verified" do
      context_rls = Auth.init(roles: @roles, jwt: :context)

      assert {:ok, %{db_role: "authenticated", claims: %{"sub" => "bob"}}} =
               Auth.resolve(
                 conn("Bearer ignored"),
                 context_rls,
                 %{jwt_claims: %{"role" => "authenticated", "sub" => "bob"}},
                 &Auth.default_anonymous?/2
               )

      assert {:ok, %{db_role: "anon"}} =
               Auth.resolve(conn(), context_rls, %{}, &Auth.default_anonymous?/2)
    end
  end

  describe "resolve/4 without RLS mode" do
    test "authenticated? is the negation of anonymous?" do
      assert {:ok, %{claims: %{}, db_role: nil, authenticated?: false}} =
               Auth.resolve(conn(), nil, %{role: nil}, &Auth.default_anonymous?/2)

      assert {:ok, %{authenticated?: true}} =
               Auth.resolve(conn(), nil, %{role: :admin}, &Auth.default_anonymous?/2)

      assert {:ok, %{authenticated?: true}} =
               Auth.resolve(conn(), nil, %{}, fn _conn, _context -> false end)
    end

    test "default_anonymous?/2 treats nil, :anon and \"anon\" roles as anonymous" do
      for role <- [nil, :anon, "anon"], do: assert(Auth.default_anonymous?(conn(), %{role: role}))
      refute Auth.default_anonymous?(conn(), %{role: "user"})
    end
  end

  describe "role/1" do
    test "is :authenticated only for an authenticated request" do
      assert Auth.role(%{authenticated?: true}) == :authenticated
      assert Auth.role(%{authenticated?: false}) == :anon
      assert Auth.role(nil) == :anon
    end
  end
end
