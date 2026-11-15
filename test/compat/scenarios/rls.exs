# RLS mode against the Supabase fixture: JWT role switching, policies on
# `rls_notes`, 401 vs 403, request GUCs and the `public.check_request` pre-request. Ported from
# PostgREST's AuthSpec (JWT errors, the bearer scheme), test/io/test_auth.py (a nonexistent
# role) and the supabase-js RLS cases. Tokens are signed when the file loads, so time claims
# are relative to the run (the 30 s skew is unit-tested: a token aged that close would expire
# between load and replay). Every mutation rolls back.
alias PgRest.Compat.JWT

rb = {"prefer", "tx=rollback"}
now = System.os_time(:second)
bearer = fn claims -> {"authorization", "Bearer " <> JWT.sign(claims)} end
user = fn sub -> bearer.(%{"role" => "authenticated", "sub" => sub}) end
challenge = ["www-authenticate"]

base = %{fixture: :supabase}

[
  # --- policies --------------------------------------------------------------------------------
  %{id: "rls/anon-notes", path: "/rls_notes"},
  %{
    id: "rls/alice-notes",
    path: "/rls_notes?select=owner,slug&order=slug",
    headers: [user.("alice")]
  },
  %{
    id: "rls/bob-notes",
    path: "/rls_notes?select=owner,slug&order=slug",
    headers: [user.("bob")]
  },
  %{
    id: "rls/anon-insert",
    method: "POST",
    path: "/rls_notes",
    headers: [rb],
    body: %{body: "x", slug: "anon"},
    stateful: true,
    response_headers: challenge
  },
  %{
    id: "rls/alice-insert-for-bob",
    method: "POST",
    path: "/rls_notes",
    headers: [user.("alice"), rb],
    body: %{owner: "bob", body: "x", slug: "forged"},
    stateful: true
  },
  %{
    id: "rls/alice-insert-own",
    method: "POST",
    path: "/rls_notes?select=owner,body",
    headers: [user.("alice"), rb, {"prefer", "return=representation"}],
    body: %{body: "mine", slug: "mine"},
    stateful: true
  },
  %{
    id: "rls/alice-patch-bob",
    method: "PATCH",
    path: "/rls_notes?slug=eq.b1",
    headers: [user.("alice"), rb],
    body: %{body: "changed"},
    stateful: true
  },
  %{
    id: "rls/alice-patch-own",
    method: "PATCH",
    path: "/rls_notes?slug=eq.a1&select=slug,body",
    headers: [user.("alice"), rb, {"prefer", "return=representation"}],
    body: %{body: "changed"},
    stateful: true
  },
  %{
    id: "rls/bob-delete-alice",
    method: "DELETE",
    path: "/rls_notes?owner=eq.alice",
    headers: [user.("bob"), rb, {"prefer", "count=exact"}],
    stateful: true
  },

  # --- 401 vs 403 --------------------------------------------------------------------------------
  %{id: "rls/private-docs-anon", path: "/private_docs", response_headers: challenge},
  %{
    id: "rls/private-docs-authenticated",
    path: "/private_docs",
    headers: [user.("alice")],
    response_headers: challenge
  },
  %{
    id: "rls/privileged-hello-anon",
    method: "POST",
    path: "/rpc/privileged_hello",
    body: %{name: "x"},
    response_headers: challenge
  },
  %{
    id: "rls/privileged-hello-authenticated",
    method: "POST",
    path: "/rpc/privileged_hello",
    headers: [user.("alice")],
    body: %{name: "x"}
  },

  # --- request GUCs and pre-request ----------------------------------------------------------
  %{id: "rls/whoami-anon", path: "/rpc/whoami"},
  %{id: "rls/whoami-alice", path: "/rpc/whoami", headers: [user.("alice")]},
  %{
    id: "rls/request-info",
    path: "/rpc/request_info",
    headers: [{"x-custom", "custom value"}, {"cookie", "sid=abc"}]
  },
  %{id: "rls/request-info-post", method: "POST", path: "/rpc/request_info", body: %{}},
  %{id: "rls/banned", path: "/rls_notes", headers: [{"x-banned", "true"}]},
  %{id: "rls/banned-rpc", path: "/rpc/whoami", headers: [user.("alice"), {"x-banned", "true"}]},
  %{
    id: "rls/pre-request-gucs",
    path: "/rls_notes",
    headers: [{"x-set-guc", "true"}],
    response_headers: ["x-pre-request"]
  },

  # --- JWT errors (AuthSpec) -------------------------------------------------------------------
  %{
    id: "rls/jwt-empty-bearer",
    path: "/rls_notes",
    headers: [{"authorization", "Bearer "}],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-two-parts",
    path: "/rls_notes",
    headers: [{"authorization", "Bearer a.b"}],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-expired",
    path: "/rls_notes",
    headers: [bearer.(%{"role" => "authenticated", "exp" => now - 60})],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-exp-future",
    path: "/rls_notes?select=slug&order=slug",
    headers: [bearer.(%{"role" => "authenticated", "sub" => "bob", "exp" => now + 3600})]
  },
  %{
    id: "rls/jwt-nbf-future",
    path: "/rls_notes",
    headers: [bearer.(%{"role" => "authenticated", "nbf" => now + 600})],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-iat-future",
    path: "/rls_notes",
    headers: [bearer.(%{"role" => "authenticated", "iat" => now + 600})],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-exp-not-number",
    path: "/rls_notes",
    headers: [bearer.(%{"role" => "authenticated", "exp" => "never"})],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-nbf-not-number",
    path: "/rls_notes",
    headers: [bearer.(%{"role" => "authenticated", "nbf" => "soon"})],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-iat-not-number",
    path: "/rls_notes",
    headers: [bearer.(%{"role" => "authenticated", "iat" => true})],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-aud-not-string",
    path: "/rls_notes",
    headers: [bearer.(%{"role" => "authenticated", "aud" => 1})],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-aud-array-not-strings",
    path: "/rls_notes",
    headers: [bearer.(%{"role" => "authenticated", "aud" => ["a", 1]})],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-wrong-signature",
    path: "/rls_notes",
    headers: [
      {"authorization",
       "Bearer " <> JWT.sign(%{"role" => "authenticated"}, String.duplicate("w", 32))}
    ],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-alg-none",
    path: "/rls_notes",
    headers: [
      {"authorization",
       "Bearer " <> JWT.segment(%{"alg" => "none"}) <> "." <> JWT.segment(%{"role" => "x"}) <> "."}
    ],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-garbage",
    path: "/rls_notes",
    headers: [{"authorization", "Bearer aaa.bbb.ccc"}],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-claims-not-object",
    path: "/rls_notes",
    headers: [
      {"authorization",
       "Bearer " <> JWT.sign_segments(JWT.segment(%{"alg" => "HS256"}), JWT.segment([1]))}
    ],
    response_headers: challenge
  },
  %{
    id: "rls/jwt-bearer-lowercase",
    path: "/rls_notes?select=slug&order=slug",
    headers: [
      {"authorization", "bearer " <> JWT.sign(%{"role" => "authenticated", "sub" => "bob"})}
    ]
  },
  %{
    id: "rls/jwt-bearer-capitalized",
    path: "/rls_notes?select=slug&order=slug",
    headers: [
      {"authorization", "Bearer " <> JWT.sign(%{"role" => "authenticated", "sub" => "bob"})}
    ]
  },
  %{id: "rls/jwt-basic-scheme", path: "/rpc/whoami", headers: [{"authorization", "Basic abc"}]},
  %{id: "rls/jwt-no-role-claim", path: "/rpc/whoami", headers: [bearer.(%{"sub" => "alice"})]},
  %{id: "rls/jwt-bad-path", path: "/a/b/c", headers: [{"authorization", "Bearer a.b"}]},

  # --- roles ---------------------------------------------------------------------------------
  %{
    id: "rls/nonexistent-role",
    path: "/rls_notes",
    headers: [bearer.(%{"role" => "not_existing"})],
    response_headers: challenge
  },
  %{
    id: "rls/role-not-a-string",
    path: "/rls_notes",
    headers: [bearer.(%{"role" => 123})],
    response_headers: challenge
  },
  # --- per-role settings (ALTER ROLE ... SET, roles.sql) ----------------------------------------
  %{id: "rls/role-settings-anon", path: "/rpc/current_statement_timeout"},
  %{
    id: "rls/role-settings-authenticated",
    path: "/rpc/current_statement_timeout",
    headers: [user.("alice")]
  },
  %{
    id: "rls/role-settings-service-role",
    path: "/rpc/current_statement_timeout",
    headers: [bearer.(%{"role" => "service_role"})]
  },
  %{id: "rls/service-role", path: "/rpc/whoami", headers: [bearer.(%{"role" => "service_role"})]}
]
|> Enum.map(&Map.merge(base, &1))
