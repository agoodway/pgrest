defmodule PgRest.PlugCase do
  @moduledoc false
  # Request helpers shared by the plug-level tests over the compat fixture.
  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias PgRest.Compat.Repo

  @doc """
  Sends a request through `PgRest.Plug` against the compat repo. A map or list `body` is
  sent as JSON, a binary as is. `plug_opts` are merged over `repo: PgRest.Compat.Repo`.
  """
  @spec request(String.t(), String.t(), term(), [{String.t(), String.t()}], keyword()) ::
          Plug.Conn.t()
  def request(method, path, body \\ nil, headers \\ [], plug_opts \\ []) do
    conn =
      method
      |> Plug.Test.conn(path, encode(body))
      |> put_content_type(body)

    headers
    |> Enum.reduce(conn, fn {key, value}, acc -> Plug.Conn.put_req_header(acc, key, value) end)
    |> PgRest.Plug.call(PgRest.Plug.init(Keyword.merge([repo: Repo], plug_opts)))
  end

  @doc "The first value of the response header `name`, or `nil`."
  @spec header(Plug.Conn.t(), String.t()) :: String.t() | nil
  def header(%Plug.Conn{} = conn, name),
    do: conn |> Plug.Conn.get_resp_header(name) |> List.first()

  @doc "The decoded JSON response body."
  @spec json(Plug.Conn.t()) :: term()
  def json(%Plug.Conn{resp_body: body}), do: Jason.decode!(body)

  @doc "Starts a `PgRest.Registry` with `modules` under the test supervisor."
  @spec register([module()]) :: pid()
  def register(modules), do: start_supervised!({PgRest.Registry, modules: modules})

  defp encode(nil), do: nil
  defp encode(body) when is_binary(body), do: body
  defp encode(body), do: Jason.encode!(body)

  defp put_content_type(conn, nil), do: conn

  defp put_content_type(conn, _body),
    do: Plug.Conn.put_req_header(conn, "content-type", "application/json")
end
