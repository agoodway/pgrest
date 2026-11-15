defmodule PgRest.Compat.PublicRepo do
  @moduledoc false
  # The compat database through a repo whose `search_path` is `public` only.
  use Ecto.Repo, otp_app: :pgrest, adapter: Ecto.Adapters.Postgres
end
