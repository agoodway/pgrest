defmodule PgRest.Compat.AuthenticatorRepo do
  @moduledoc false
  use Ecto.Repo, otp_app: :pgrest, adapter: Ecto.Adapters.Postgres
end

defmodule PgRest.Compat.SingleAuthenticatorRepo do
  @moduledoc false
  # `AuthenticatorRepo` with one connection, so consecutive RLS requests share it
  # (test/pg_rest/rls_test.exs starts it).
  use Ecto.Repo, otp_app: :pgrest, adapter: Ecto.Adapters.Postgres
end
