defmodule PgRest.Integration.Repo do
  @moduledoc false
  use Ecto.Repo, otp_app: :pgrest, adapter: Ecto.Adapters.Postgres
end
