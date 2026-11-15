defmodule PgRest.Integration.Router do
  @moduledoc false
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  forward("/rest/v1", to: PgRest.Compat.Router)

  match _ do
    send_resp(conn, 404, "not found")
  end
end
