ExUnit.start(exclude: [:differential, :js])

# Postgrex logs "unknown oid" at debug level whenever the fixture adds types. Silence that one
# emitter only: the log-leak checks (repo_calls_test, error_paths_test) need every other log.
Logger.put_module_level(Postgrex.Protocol, :warning)

# The Supabase-shaped PostgREST's JWT secret (docker-compose.yml), which
# PgRest.Compat.SupabaseRouter reads at request time.
System.put_env("PGREST_COMPAT_JWT_SECRET", "reallyreallyreallyreallyverysafe")

# Compat database for the PostgREST comparison harness (test/compat).
:ok = PgRest.Compat.Fixture.load!()

# The safeupdate tests need the optional `db_safeupdate` server (compose profile `safeupdate`);
# skip them when it is down, whether or not they were asked for with --include.
unless PgRest.Compat.Fixture.safeupdate_loaded?(), do: ExUnit.configure(exclude: [:safeupdate])
