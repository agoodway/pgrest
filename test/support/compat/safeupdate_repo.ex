defmodule PgRest.Compat.SafeupdateRepo do
  @moduledoc """
  Repo for `pgrest_safeupdate` on the pg-safeupdate Postgres (`db_safeupdate`, compose
  profile `safeupdate`). Pool of one, no sandbox, so a `LOAD 'safeupdate'` stays on the
  one connection the tests use.
  """
  use Ecto.Repo, otp_app: :pgrest, adapter: Ecto.Adapters.Postgres
end
