defmodule PgRest.ResponseGucs do
  @moduledoc """
  The `response.headers` and `response.status` GUCs a function, a trigger or a
  `pre_request` function sets, as PostgREST's `Response.hs` handles them.

  Every read, write and call statement selects both GUCs after its main CTE, in the same
  statement and transaction (`response_headers`, `response_status`, `NULL` when unset or
  empty). `decode/2` validates the raw values; `status/2` picks the status to send (the GUC status
  replaces the generated one) and `apply/2` overlays the headers on the response: a generated
  header is dropped when a GUC header has the same name (case-insensitively), and every GUC
  header is then added in order, so repeated names (two `Set-Cookie`s) are all kept.

  A statement that fails is never decoded: its GUCs are rolled back with it. A malformed GUC
  is a 500 (`PGRST111`, `PGRST112`) and rolls the transaction back like any other error.

  ## Differences from PostgREST

  Only response.status values in 200..999 are accepted. PostgREST may send an
  unfinished informational response or a malformed status line outside this range.
  Header names and values are validated to prevent response splitting.
  """

  alias PgRest.Error
  alias PgRest.Planner.Result

  @type decoded :: %{headers: [{String.t(), String.t()}], status: pos_integer() | nil}

  @none %{headers: [], status: nil}

  # RFC 9110 `tchar`: the characters an HTTP header name is made of.
  @token_chars ~c"!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

  @doc """
  The SQL select list of the two columns, `response_headers` then `response_status`: appended
  to the select of every read, write and call statement.
  """
  @spec columns() :: String.t()
  def columns do
    "nullif(current_setting('response.headers', true), '') AS response_headers, " <>
      "nullif(current_setting('response.status', true), '') AS response_status"
  end

  @doc "The decoded value for \"no override\": no header and no status."
  @spec none() :: decoded()
  def none, do: @none

  @doc """
  Decodes the raw GUC values. `nil` is no override. The status is checked first, as
  PostgREST does (`overrideStatusHeaders`), so two malformed GUCs answer `PGRST112`.

  Headers are also rejected (`PGRST111`) when a name is empty or not an HTTP token, or a
  name or value holds a CR, LF, NUL or other control character: `apply/2` writes them to the
  response without Plug's validation, so a value built from request data must not be able to
  split the response. PostgREST has no such check (whether Warp rejects such headers itself is unverified).
  """
  @spec decode(String.t() | nil, String.t() | nil) :: {:ok, decoded()} | {:error, Error.t()}
  def decode(headers_raw, status_raw) do
    with {:ok, status} <- decode_status(status_raw),
         {:ok, headers} <- decode_headers(headers_raw) do
      {:ok, %{headers: headers, status: status}}
    end
  end

  defp decode_headers(nil), do: {:ok, []}

  defp decode_headers(raw) do
    with {:ok, list} when is_list(list) <- Jason.decode(raw),
         {:ok, _headers} = ok <- Result.map_ok(list, &header/1) do
      ok
    else
      _invalid -> {:error, Error.response_guc(:headers)}
    end
  end

  defp header(%{} = object) when map_size(object) == 1, do: object |> Map.to_list() |> pair()
  defp header(_other), do: {:error, :header}

  defp pair([{name, value}]) when is_binary(value) do
    if token?(name) and field_value?(value), do: {:ok, {name, value}}, else: {:error, :header}
  end

  defp pair(_other), do: {:error, :header}

  defp token?(""), do: false
  defp token?(name), do: name |> :binary.bin_to_list() |> Enum.all?(&(&1 in @token_chars))

  # HTAB, SP..~ and obs-text (>= 0x80, as UTF-8 text uses); never CR, LF, NUL, DEL or other
  # control characters.
  defp field_value?(value),
    do:
      value |> :binary.bin_to_list() |> Enum.all?(&(&1 == ?\t or &1 in 0x20..0x7E or &1 >= 0x80))

  defp decode_status(nil), do: {:ok, nil}

  # PostgREST reads the leading digits (`403abc` is 403; a sign or a leading space is an
  # error). A status outside 200..999 is an error too, unlike PostgREST: below 200 is no final
  # response (1xx) or a malformed status line, above 999 cannot be written.
  defp decode_status(raw) do
    with <<digit, _rest::binary>> when digit in ?0..?9 <- raw,
         {status, _trailing} when status in 200..999 <- Integer.parse(raw) do
      {:ok, status}
    else
      _invalid -> {:error, Error.response_guc(:status)}
    end
  end

  @doc "The status to send: the GUC status when one is set, else `default`."
  @spec status(decoded(), pos_integer()) :: pos_integer()
  def status(%{status: status}, default), do: status || default

  @doc """
  Overlays the decoded GUC headers on a response `conn` that is not sent yet: generated
  headers a GUC header names are dropped (names compare case-insensitively), and every GUC
  header is appended in order, so repeated names are all kept. The status is the caller's to
  send, through `status/2`.
  """
  @spec apply(Plug.Conn.t(), decoded()) :: Plug.Conn.t()
  def apply(%Plug.Conn{} = conn, %{headers: headers}) do
    added = Enum.map(headers, fn {name, value} -> {String.downcase(name), value} end)
    names = MapSet.new(added, fn {name, _value} -> name end)

    kept = Enum.reject(conn.resp_headers, fn {name, _value} -> MapSet.member?(names, name) end)

    %{conn | resp_headers: kept ++ added}
  end
end
