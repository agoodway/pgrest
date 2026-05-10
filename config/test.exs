import Config

# Integration test repo — only started when running `mix test.integration`
config :pgrest, ecto_repos: [PgRest.Integration.Repo]

config :pgrest, PgRest.Integration.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  database: "pgrest_integration_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2
