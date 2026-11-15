defmodule PgRest.BodyReader do
  @moduledoc """
  A `Plug.Parsers` body reader that keeps the raw request body.

      plug Plug.Parsers,
        parsers: [:json],
        json_decoder: Jason,
        body_reader: {PgRest.BodyReader, :read_body, []}

  The bytes accumulate in `conn.private[:pgrest_raw_body]`. `PgRest.Request`
  uses them when present, which lets writes pass the original JSON to Postgres
  instead of re-encoding the decoded payload.
  """

  @doc "Delegates to `Plug.Conn.read_body/2`, caching every chunk read."
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, chunk, conn} when status in [:ok, :more] ->
        {status, chunk, accumulate(conn, chunk)}

      other ->
        other
    end
  end

  defp accumulate(conn, chunk) do
    previous = Map.get(conn.private, :pgrest_raw_body, "")
    Plug.Conn.put_private(conn, :pgrest_raw_body, previous <> chunk)
  end
end
