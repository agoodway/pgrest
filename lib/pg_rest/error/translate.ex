defmodule PgRest.Error.Translate do
  @moduledoc """
  Translates exceptions into `PgRest.Error`, mapping Postgres SQLSTATEs to HTTP
  statuses the way PostgREST does.

  Message, details and hint come from Postgres. Any other exception becomes a
  generic 500 that never exposes the exception's text.

  PT SQLSTATEs carry a custom HTTP status. PGRST SQLSTATEs decode MESSAGE JSON
  (code, message, optional details/hint) and DETAIL JSON (status and headers,
  optional status_text); malformed payloads return PGRST121.

  ## Differences from PostgREST

  DETAIL's status_text is validated but not sent as a custom HTTP reason phrase.
  PostgREST sends it; PgRest leaves the phrase to the host HTTP server.
  """

  require Logger

  alias PgRest.Error

  @type role :: :anon | :authenticated

  @raise_hints %{
    "MESSAGE" =>
      "MESSAGE must be a JSON object with obligatory keys: 'code', 'message' and optional keys: 'details', 'hint'.",
    "DETAIL" =>
      "DETAIL must be a JSON object with obligatory keys: 'status', 'headers' and optional key: 'status_text'."
  }

  # Constraint violations whose details quote row or column values.
  @detail_leaking ~w(23502 23503 23505 23514 23P01)

  @doc """
  Builds a `PgRest.Error` from an exception.

  ## Options

    * `:scrub_details?` - when `true`, drops `details` for SQLSTATEs 23502, 23503,
      23505, 23514 and 23P01 (default `false`). Set it when the effective source is
      not the identity scope or a column allowlist narrows the resource, as
      Postgres does under row-level security.
  """
  @spec from_exception(Exception.t() | atom(), role(), keyword()) :: Error.t()
  def from_exception(exception, role, opts \\ [])

  def from_exception(%Postgrex.Error{postgres: %{pg_code: "PGRST"} = pg}, _role, _opts),
    do: raised_error(pg)

  def from_exception(%Postgrex.Error{postgres: %{pg_code: code} = pg}, role, opts) do
    %Error{
      status: http_status(pg, role),
      code: code,
      message: pg.message,
      details: details(pg, code, Keyword.get(opts, :scrub_details?, false)),
      hint: Map.get(pg, :hint)
    }
  end

  def from_exception(%Error{} = error, _role, _opts), do: error
  def from_exception(%Postgrex.Error{}, _role, _opts), do: Error.connection_error()

  def from_exception(%DBConnection.ConnectionError{reason: :queue_timeout}, _role, _opts),
    do: Error.pool_timeout()

  def from_exception(%DBConnection.ConnectionError{}, _role, _opts), do: Error.connection_error()
  def from_exception(_exception, _role, _opts), do: Error.internal()

  @doc """
  `from_exception/3` that also reports what was caught, for catch-alls. The log line carries
  the exception module (or `:exit`) and `context` only, never the message, SQL or
  parameters. Connection failures are logged as warnings, unexpected exceptions as errors,
  Postgres errors not at all.
  """
  @spec from_exception_logged(Exception.t() | atom(), role(), keyword()) :: Error.t()
  def from_exception_logged(exception, role, opts \\ []) do
    context = Keyword.get(opts, :context, "serving a request")
    report(kind(exception), exception, context)
    from_exception(exception, role, Keyword.delete(opts, :context))
  end

  @doc """
  Runs `fun`, turning a database or connection failure into `{:error, %PgRest.Error{}}`
  (translated for the request's `role`). Other exceptions propagate.
  """
  @spec guard_db((-> result), role(), keyword()) :: result | {:error, Error.t()}
        when result: term()
  def guard_db(fun, role, opts \\ []) do
    fun.()
  rescue
    exception in [Postgrex.Error, DBConnection.ConnectionError] ->
      {:error,
       from_exception_logged(
         exception,
         role,
         Keyword.put(opts, :context, "preparing the request")
       )}
  end

  @doc """
  What kind of failure `exception` is: `:database` (Postgres or a `PgRest.Error`),
  `:connection` (driver or pool) or `:internal` (anything unexpected).
  """
  @spec kind(term()) :: :database | :connection | :internal
  def kind(%Postgrex.Error{postgres: %{}}), do: :database
  def kind(%Error{}), do: :database
  def kind(%Postgrex.Error{}), do: :connection
  def kind(%DBConnection.ConnectionError{}), do: :connection
  def kind(_exception), do: :internal

  defp report(:database, _exception, _context), do: :ok

  defp report(:connection, exception, context),
    do: Logger.warning("PgRest: #{describe(exception)} while #{context}")

  defp report(:internal, exception, context),
    do: Logger.error("PgRest: unexpected #{describe(exception)} while #{context}")

  # Only module names and atoms are ever logged, never terms that may hold data.
  defp describe(%module{}), do: inspect(module)
  defp describe(atom) when is_atom(atom), do: inspect(atom)
  defp describe(_other), do: "term"

  defp raised_error(pg) do
    with {:ok, body} <- raise_field(Map.get(pg, :message), "MESSAGE"),
         {:ok, detail} <- raise_field(Map.get(pg, :detail), "DETAIL") do
      %Error{
        status: detail["status"],
        code: body["code"],
        message: body["message"],
        details: body["details"],
        hint: body["hint"],
        headers: Map.to_list(Map.get(detail, "headers", %{})),
        custom_headers?: true
      }
    else
      {:error, error} -> error
    end
  end

  defp raise_field(raw, field) do
    with true <- is_binary(raw),
         {:ok, %{} = value} <- Jason.decode(raw),
         true <- raise_shape?(value, field) do
      {:ok, value}
    else
      _invalid -> {:error, invalid_raise(raw, field)}
    end
  end

  defp raise_shape?(%{"code" => code, "message" => message} = body, "MESSAGE"),
    do:
      is_binary(code) and is_binary(message) and
        Enum.all?(~w(details hint), &(is_nil(body[&1]) or is_binary(body[&1])))

  defp raise_shape?(%{"status" => status, "headers" => headers} = detail, "DETAIL"),
    do:
      is_integer(status) and is_map(headers) and
        Enum.all?(headers, fn {_name, value} -> is_binary(value) end) and
        (is_nil(detail["status_text"]) or is_binary(detail["status_text"]))

  defp raise_shape?(_value, _field), do: false

  defp invalid_raise(raw, field) do
    %Error{
      status: 500,
      code: "PGRST121",
      message: ~s|Could not parse JSON in the "RAISE SQLSTATE 'PGRST'" error|,
      details:
        if(is_nil(raw),
          do: "#{field} is missing in the RAISE statement",
          else: "Invalid JSON value for #{field}: '#{raw}'"
        ),
      hint: Map.fetch!(@raise_hints, field)
    }
  end

  defp details(_pg, code, true) when code in @detail_leaking, do: nil
  defp details(pg, _code, _scrub?), do: Map.get(pg, :detail)

  # 21000 is a client error only for pg-safeupdate; any other cardinality violation is a 500.
  defp http_status(%{pg_code: "21000", message: message}, _role) when is_binary(message) do
    if String.ends_with?(message, "requires a WHERE clause"), do: 400, else: 500
  end

  defp http_status(%{pg_code: "21000"}, _role), do: 500

  # A role that does not exist (a token's role claim) is a 401, any other invalid parameter a 400.
  defp http_status(%{pg_code: "22023", message: message}, _role) when is_binary(message) do
    if String.starts_with?(message, "role") and String.ends_with?(message, "does not exist"),
      do: 401,
      else: 400
  end

  defp http_status(%{pg_code: code}, role), do: status(code, role)

  defp status(code, _role) when code in ~w(23503 23505), do: 409

  defp status("25006", _role), do: 405
  defp status(code, _role) when code in ~w(42883 42P01), do: 404
  defp status(code, _role) when code in ~w(42P17 53400), do: 500
  defp status("57P01", _role), do: 503
  defp status("42501", :anon), do: 401
  defp status("42501", _role), do: 403
  defp status("P0001", _role), do: 400
  defp status(<<"PT", digits::binary-size(3)>>, _role), do: custom_status(digits)
  defp status(<<"PT", _::binary>>, _role), do: 500
  defp status(<<class::binary-size(2), _::binary>>, _role), do: class_status(class)
  defp status(_code, _role), do: 400

  defp custom_status(digits) do
    case Integer.parse(digits) do
      {status, ""} when status in 100..999 -> status
      _ -> 500
    end
  end

  defp class_status("08"), do: 503
  defp class_status("53"), do: 503
  defp class_status(class) when class in ~w(0L 0P 28), do: 403
  defp class_status(class) when class in ~w(09 25 2D 38 39 3B 40 54 55 57 58 F0 HV XX), do: 500
  defp class_status("P0"), do: 500
  defp class_status(_class), do: 400
end
