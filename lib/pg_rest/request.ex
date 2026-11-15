defmodule PgRest.Request do
  @moduledoc """
  A parsed HTTP request: ordered params, `Prefer`, `Range` and the JSON body.

  ## Body sources

  `from_conn/2` takes the body from the first of these that applies:

    1. `conn.private[:pgrest_raw_body]`, cached by `PgRest.BodyReader`. `raw_body`
       is those bytes and `body` their decoded JSON.
    2. `conn.body_params` from `Plug.Parsers` without the reader. An array payload
       (`%{"_json" => [...]}`) is unwrapped, a scalar becomes `[]`, an object is
       used as is, and `raw_body` is `nil`. Plug.Parsers' own `:length` governs the
       size limit on this path, not `:max_body_bytes`. Plug.Parsers wraps every
       non-object payload under `"_json"`, so here a genuine object body
       `{"_json": 5}` is indistinguishable from the scalar `5` and also becomes
       `[]`; use `PgRest.BodyReader` (path 1, which decodes the raw bytes) to
       avoid that.
    3. An unparsed body, read with `Plug.Conn.read_body/2`. `raw_body` keeps the bytes.

  Only POST, PUT and PATCH decode a body; for other methods `body` is `nil` (a
  cached or read `raw_body` is kept). A scalar JSON payload (`5`, `"x"`, `null`)
  becomes an empty array, as in PostgREST; empty or invalid JSON is a 400 `PGRST102`.

  ## Schema profile

  `PgRest.Plug` resolves the profile once (`profile/2`) and passes it as the `:profile` option:
  `schema` is the schema the request targets and `profile_negotiated?` tells the responder to
  send `Content-Profile`. Without the option, `schema` is `nil`.

  ## Options

    * `:profile` - `{schema, negotiated?}` from `profile/2`.
    * `:tx_end` - `:commit` (default) ignores `Prefer: tx=...`;
      `:commit_allow_override` honors it.
    * `:max_body_bytes` - body size limit (default `8_000_000`); larger bodies are
      a 413.
    * `:rpc_body` - for a `POST /rpc/<fn>`: `:json` reads an empty body as `{}` (a call
      without arguments); `:raw` keeps a non-JSON body (`text/plain`, `text/xml`,
      `application/octet-stream`) undecoded in `raw_body`, with `body` `nil`. Such a body
      needs the raw bytes (`PgRest.BodyReader`, or no `Plug.Parsers` for it).

  ## Differences from PostgREST

  Strict invalid preferences return PGRST122 before select planning. When both are
  invalid, PostgREST v14.18 reports the select error first.
  """

  alias PgRest.{Auth, Error, MediaType, Options, Prefer}
  alias PgRest.Authorization.State
  alias PgRest.Registry.Snapshot
  alias PgRest.Request.{Accept, QueryString, Range}
  alias PgRest.Request.Prefer, as: PreferParser

  @body_methods ~w(POST PUT PATCH)
  @content_profile_methods ~w(POST PATCH PUT DELETE)

  defstruct [
    :method,
    :path,
    :params,
    :prefer,
    :range,
    :body,
    :raw_body,
    :conn,
    :schema,
    :db_role,
    authorization_state: State.empty(),
    accepts: [],
    profile_negotiated?: false,
    claims: %{},
    authenticated?: false
  ]

  @type t :: %__MODULE__{
          method: String.t(),
          path: [String.t()],
          params: [{String.t(), String.t() | nil}],
          prefer: Prefer.t(),
          authorization_state: State.t(),
          accepts: [MediaType.t()],
          range: Range.t(),
          body: term(),
          raw_body: binary() | nil,
          conn: Plug.Conn.t(),
          schema: String.t() | nil,
          profile_negotiated?: boolean(),
          claims: map(),
          db_role: String.t() | nil,
          authenticated?: boolean()
        }

  @doc """
  Builds a request from a `Plug.Conn`. `claims`, `db_role` and `authenticated?` come from the
  `PgRest.Auth` resolution `PgRest.Plug` stores in `conn.private[:pgrest_auth]` (anonymous
  without one).
  """
  @spec from_conn(Plug.Conn.t(), keyword() | map()) :: {:ok, t()} | {:error, Error.t()}
  def from_conn(%Plug.Conn{} = conn, opts) do
    {schema, negotiated?} = Access.get(opts, :profile, {nil, false})
    auth = Map.get_lazy(conn.private, :pgrest_auth, &Auth.anonymous/0)

    with {:ok, params} <- QueryString.parse(conn.query_string),
         {:ok, range} <- Range.from(conn.method, conn.req_headers, params),
         {:ok, body, raw_body, conn} <- read_body(conn, opts) do
      request = %__MODULE__{
        method: conn.method,
        path: conn.path_info,
        params: params,
        prefer: prefer(conn, opts),
        accepts: Accept.parse(first_header(conn, "accept")),
        range: range,
        body: body,
        raw_body: raw_body,
        conn: conn,
        schema: schema,
        profile_negotiated?: negotiated?
      }

      {:ok, put_auth(request, auth)}
    end
  end

  @doc "Sets the request's `claims`, `db_role` and `authenticated?` from a `PgRest.Auth` resolution."
  @spec put_auth(t(), Auth.t()) :: t()
  def put_auth(%__MODULE__{} = request, %{claims: claims, db_role: role, authenticated?: authed?}),
      do: %{request | claims: claims, db_role: role, authenticated?: authed?}

  @doc """
  The body bytes of a request: `raw_body` when it was cached or read, else the decoded `body`
  encoded once with `Jason.encode!/1`.
  """
  @spec body_bytes(t()) :: binary()
  def body_bytes(%__MODULE__{raw_body: raw}) when is_binary(raw), do: raw
  def body_bytes(%__MODULE__{body: body}), do: Jason.encode!(body)

  @doc """
  The base of a media type header value, lowercased: its parameters (`; charset=...`,
  `; q=...`) and surrounding whitespace dropped.
  """
  @spec media_base(String.t()) :: String.t()
  def media_base(type),
    do: type |> String.split(";") |> hd() |> String.trim() |> String.downcase()

  @doc """
  The schema `conn` targets in `snapshot`: `Content-Profile` for POST, PATCH, PUT and DELETE, the
  `Accept-Profile` header for every other method (GET, HEAD, OPTIONS, ...), and the default schema
  without one. A schema that is not exposed is PostgREST's 406 `PGRST106`. Reads headers only.

  `negotiated?` follows PostgREST's `iNegotiatedByProfile`: the schema counts as negotiated (and
  the response carries `Content-Profile`) when a profile header named it or several schemas are
  exposed.
  """
  @spec profile(Plug.Conn.t(), Snapshot.t()) ::
          {:ok, {String.t(), boolean()}} | {:error, Error.t()}
  def profile(%Plug.Conn{} = conn, %Snapshot{schemas: schemas, default_schema: default}) do
    case profile_header(conn) do
      nil ->
        {:ok, {default, match?([_, _ | _], schemas)}}

      schema ->
        if schema in schemas,
          do: {:ok, {schema, true}},
          else: {:error, Error.invalid_schema(schema, schemas)}
    end
  end

  defp profile_header(%Plug.Conn{method: method} = conn) when method in @content_profile_methods,
    do: first_header(conn, "content-profile")

  defp profile_header(conn), do: first_header(conn, "accept-profile")

  defp first_header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first()

  defp prefer(conn, opts) do
    prefer = conn |> Plug.Conn.get_req_header("prefer") |> PreferParser.parse()
    tx_end = Access.get(opts, :tx_end, Options.default(:tx_end))
    Options.validate_tx_end!(tx_end)
    apply_tx_end(prefer, tx_end)
  end

  defp apply_tx_end(prefer, :commit_allow_override), do: prefer
  defp apply_tx_end(prefer, :commit), do: %{prefer | tx: nil}

  defp read_body(conn, opts) do
    max = Access.get(opts, :max_body_bytes) || Options.default(:max_body_bytes)
    limits = %{max: max, rpc: Access.get(opts, :rpc_body)}
    read_body(conn, conn.private, conn.body_params, limits)
  end

  defp read_body(conn, %{pgrest_raw_body: raw}, _body_params, limits),
    do: from_raw(conn, raw, limits)

  defp read_body(conn, _private, %Plug.Conn.Unfetched{}, limits), do: read_unparsed(conn, limits)

  defp read_body(%{method: method} = conn, _private, params, _limits)
       when method in @body_methods,
       do: {:ok, unwrap(params), nil, conn}

  defp read_body(conn, _private, _params, _limits), do: {:ok, nil, nil, conn}

  # Plug.Parsers wraps non-object payloads as `%{"_json" => payload}`. Scalars
  # become an empty array, as in PostgREST.
  defp unwrap(%{"_json" => list}) when is_list(list), do: list
  defp unwrap(%{"_json" => _scalar}), do: []
  defp unwrap(params), do: params

  defp read_unparsed(conn, %{max: max} = limits) do
    case Plug.Conn.read_body(conn, length: max + 1, read_length: min(max + 1, 1_000_000)) do
      {:ok, raw, conn} -> from_raw(conn, raw, limits)
      {:more, _chunk, _conn} -> {:error, Error.body_too_large()}
      {:error, _reason} -> {:error, Error.unreadable_body()}
    end
  end

  defp from_raw(_conn, raw, %{max: max}) when byte_size(raw) > max,
    do: {:error, Error.body_too_large()}

  # An RPC body that is not JSON goes to the function as is.
  defp from_raw(conn, raw, %{rpc: :raw}), do: {:ok, nil, raw, conn}

  # An empty RPC body calls the function without arguments, as PostgREST does.
  defp from_raw(%{method: "POST"} = conn, "", %{rpc: :json}), do: {:ok, %{}, "{}", conn}

  defp from_raw(conn, "", _limits) when conn.method in @body_methods,
    do: {:error, Error.invalid_json()}

  defp from_raw(conn, "", _limits), do: {:ok, nil, nil, conn}

  defp from_raw(%{method: method} = conn, raw, _limits) when method not in @body_methods,
    do: {:ok, nil, raw, conn}

  defp from_raw(conn, raw, _limits) do
    case Jason.decode(raw) do
      {:ok, decoded} when is_map(decoded) or is_list(decoded) -> {:ok, decoded, raw, conn}
      # PostgREST turns a scalar payload (including null) into an empty array.
      {:ok, _scalar} -> {:ok, [], "[]", conn}
      {:error, _} -> {:error, Error.invalid_json()}
    end
  end
end
