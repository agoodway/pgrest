-- TEST HARNESS ONLY. Cluster-wide roles of the Supabase-shaped fixture.
-- Mounted into the db container's initdb.d so PostgREST can log in as `authenticator`
-- on its very first start, and run again by Fixture.load!/0 (idempotent) for a db
-- container that predates this file.

DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'anon') THEN
    CREATE ROLE anon NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'service_role') THEN
    CREATE ROLE service_role NOLOGIN;
  END IF;
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'authenticator') THEN
    CREATE ROLE authenticator LOGIN NOINHERIT PASSWORD 'authenticator';
  END IF;
END
$$;

GRANT anon, authenticated, service_role TO authenticator;

-- Supabase's per-role statement timeouts, which PostgREST (and PgRest's RLS mode) apply when
-- switching to the role.
ALTER ROLE anon SET statement_timeout = '3s';
ALTER ROLE authenticated SET statement_timeout = '8s';

-- PostgREST v14.18 shares named plans across roles. SQL function inlining can
-- retain authenticated EXECUTE privileges in a generic plan used later by anon.
-- Replan its parameterized RPC statements for each request; keep the upstream
-- SQL/VOLATILE fixture unchanged. PgRest's separate executor regression uses
-- plan_cache_mode=auto and verifies generic plans, so this does not mask its cache.
ALTER ROLE anon SET plan_cache_mode = 'force_custom_plan';
ALTER ROLE authenticated SET plan_cache_mode = 'force_custom_plan';
