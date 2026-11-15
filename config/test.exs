import Config

db_port = String.to_integer(System.get_env("PGREST_DB_PORT", "54320"))

shared_repo_opts = [
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: db_port
]

# Compat database: recreated by PgRest.Compat.Fixture.load!/0, no sandbox.
config :pgrest,
       PgRest.Compat.Repo,
       shared_repo_opts ++ [database: "pgrest_compat", pool_size: 10, log: false]

# Supabase-shaped database (roles, RLS): recreated by Fixture.load!/0, no sandbox.
# The authenticator repo connects as PostgREST's login role, which holds no privileges itself.
config :pgrest,
       PgRest.Compat.SupabaseRepo,
       shared_repo_opts ++ [database: "pgrest_supabase", pool_size: 10, log: false]

config :pgrest,
       PgRest.Compat.AuthenticatorRepo,
       Keyword.merge(shared_repo_opts,
         username: "authenticator",
         password: "authenticator",
         database: "pgrest_supabase",
         pool_size: 10,
         log: false
       )

# One authenticator connection, so consecutive RLS requests reuse it (test/pg_rest/rls_test.exs).
config :pgrest,
       PgRest.Compat.SingleAuthenticatorRepo,
       Keyword.merge(shared_repo_opts,
         username: "authenticator",
         password: "authenticator",
         database: "pgrest_supabase",
         pool_size: 1,
         log: false
       )

# pg-safeupdate database (compose profile `safeupdate`): recreated by Fixture.load!/0 when
# its server is reachable. One connection, no sandbox.
config :pgrest,
       PgRest.Compat.SafeupdateRepo,
       Keyword.merge(shared_repo_opts,
         port: String.to_integer(System.get_env("PGREST_SAFEUPDATE_DB_PORT", "54325")),
         database: "pgrest_safeupdate",
         pool_size: 1,
         log: false
       )
