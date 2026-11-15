defmodule PgRest.Responder do
  @moduledoc """
  Turns results and errors into HTTP responses, following PostgREST.

  Reads always carry `Content-Range` (`<first>-<last>/<total or *>`, `*/<total>` when
  the page is empty) and `Content-Location` (the path with the query string sorted by
  key). The status is 206 only when the total is known and the page is a strict subset,
  and 416 `PGRST103` when the offset exceeds a known total. `Accept:
  application/vnd.pgrst.object+json` unwraps a single row and is a 406 `PGRST116` for any
  other row count. HEAD sends the same headers without a body.

  Every successful response carries `Content-Profile: <schema>` when the request negotiated its
  schema (`PgRest.Request` `profile_negotiated?`); error responses never do.

  A request answered with the `application/vnd.pgrst.plan` media type (`PgRest.Negotiate`)
  carries the plan text from `PgRest.Executor.explain/3` instead of a result: a 200 with the
  plan type as `Content-Type` and, when the schema was negotiated, `Content-Profile` (no
  `Content-Range`, `Content-Location` or `Preference-Applied`).

  ## Differences from PostgREST

  Custom RAISE headers replace generated headers with the same name. PostgREST
  v14.18 emits duplicate Content-Type headers when the error supplies one.

  Bodies are encoded with `Jason`. `PgRest.Plug` stores the planner context in
  `conn.private[:pgrest_context]` for `after_load` callbacks.
  """

  alias PgRest.{Error, Executor, MediaType, Plan, Request, ResponseGucs}
  alias PgRest.Planner.Result
  alias PgRest.Request.Prefer, as: PreferParser
  alias PgRest.SQL.Read.Embed

  require Logger

  @doc "Sends `error` with its status and the PostgREST error body."
  @spec error(Plug.Conn.t(), Error.t()) :: Plug.Conn.t()
  def error(conn, %Error{} = error) do
    conn
    |> Plug.Conn.delete_resp_header("content-profile")
    |> put_content_type(MediaType.content_type(MediaType.json()))
    |> put_error_headers(error)
    |> send(
      ResponseGucs.none(),
      error.status,
      nil,
      Jason.encode!(Error.to_body(error))
    )
  end

  @doc """
  Answers an `OPTIONS` request: 200, an empty body and the `Allow` header listing `methods`.
  """
  @spec allow(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def allow(conn, methods) do
    conn
    |> Plug.Conn.put_resp_header("allow", Enum.join(methods, ","))
    |> send(ResponseGucs.none(), 200, nil, "")
  end

  # PgRest's headerless 401s challenge for a bearer token. Custom errors supply their
  # own headers; a parsed PGRST RAISE can explicitly supply an empty map.
  defp put_error_headers(conn, %Error{status: status, headers: headers} = error) do
    defaults =
      if status == 401 and headers == [] and not error.custom_headers?,
        do: [{"www-authenticate", "Bearer"}],
        else: []

    Enum.reduce(defaults ++ headers, conn, fn {name, value}, conn ->
      Plug.Conn.put_resp_header(conn, String.downcase(name), value)
    end)
  end

  @doc """
  Sends the response of a read: `result` is the executor's `%{body, page_total, total}` (the
  plan text for a plan `media`), `media` the `PgRest.MediaType` `PgRest.Negotiate` chose.

  A table read answers with `Content-Location`. An RPC answers without it: a function
  returning one value or row is `0-0/<total>` whatever the filters left, and a void one is a
  204 without a body, content type or `Content-Profile`. The object media type's single-row
  check of an RPC ran inside the transaction (`PgRest.Plug`); a table read checks it here.
  """
  @spec read(
          Plug.Conn.t(),
          PgRest.Executor.result(),
          Request.t(),
          Plan.Read.t(),
          MediaType.t()
        ) :: Plug.Conn.t()
  def read(conn, result, request, %Plan.Read{source: {:call, call}} = plan, media),
    do: read_response(conn, result, request, plan, media, read_shape(call.function.returns))

  def read(conn, result, request, plan, media) do
    case Executor.ensure_single(media, result) do
      :ok -> read_response(conn, result, request, plan, media, read_shape(:table))
      {:error, error} -> error(conn, error)
    end
  end

  # How a read answers: `:range` is the rows (`:page`) or one value (`:single`), `:location?`
  # sends `Content-Location`, `:void?` answers a 204, `:applied` are the preferences echoed.
  defp read_shape(:table),
    do: %{range: :page, location?: true, void?: false, applied: [:count, :tx]}

  defp read_shape(%{set?: set?, kind: kind}) do
    %{
      range: if(set?, do: :page, else: :single),
      location?: false,
      void?: kind == :void,
      applied: [:count, :tx, :max_affected]
    }
  end

  defp read_response(conn, result, request, plan, media, shape) do
    offset = request.range.offset
    {range, status} = range_and_status(shape.range, offset, result)

    conn =
      conn
      |> Plug.Conn.put_resp_header("content-range", range)
      |> put_content_location(shape.location?, plan, request)
      |> put_applied(request, shape.applied)

    if shape.void?,
      do: send(conn, result.gucs, 204, nil, ""),
      else:
        conn
        |> put_profile(request)
        |> respond(status, MediaType.content_type(media), offset, result, request, plan)
  end

  defp range_and_status(:page, offset, result),
    do: {content_range(offset, result), status(offset, result)}

  defp range_and_status(:single, _offset, result), do: {"0-0/#{result.total || "*"}", 200}

  defp put_content_location(conn, false, _plan, _request), do: conn

  defp put_content_location(conn, true, plan, request),
    do: Plug.Conn.put_resp_header(conn, "content-location", content_location(plan, request))

  @doc """
  Sends the response of an insert: 201 with `Content-Range: */*`, or `*/<rows>` for
  `count=exact` and `count=estimated`.

  `return=representation` sends the rows (`result.body`) as JSON, or as one object for the
  `vnd.pgrst.object` media type; `headers-only` sends `Location` (when `location` is set);
  `minimal` sends nothing. `Preference-Applied` echoes `missing`, `return`, `count`, `tx` and
  `timezone`.

  Options: `:status` (default 201; an upsert that inserted nothing is 200) and
  `:resolution?` (echo `resolution` in `Preference-Applied`, default `false`).
  """
  @spec insert(
          Plug.Conn.t(),
          %{body: String.t() | nil, page_total: non_neg_integer()},
          Request.t(),
          Plan.Read.t(),
          MediaType.t(),
          String.t() | nil,
          keyword()
        ) :: Plug.Conn.t()
  def insert(conn, result, %Request{prefer: prefer} = request, plan, media, location, opts \\ []) do
    status = Keyword.get(opts, :status, 201)
    resolution = if Keyword.get(opts, :resolution?, false), do: [:resolution], else: []

    conn =
      conn
      |> Plug.Conn.put_resp_header("content-range", "*/" <> insert_total(prefer, result))
      |> put_location(location)
      |> put_applied(request, resolution ++ [:missing, :return, :count, :tx])

    rows_or_empty(conn, result, request, {plan, media}, {status, status})
  end

  @doc """
  Sends the response of a `PUT` (`PgRest.Write.Put`): `status` (201 inserted, 200 updated) with the
  row for `return=representation`, else 204. As in PostgREST there is no `Content-Range` and no
  `Location`, and `Preference-Applied` echoes `return`, `count`, `tx`, `timezone` and `handling`.
  """
  @spec put(
          Plug.Conn.t(),
          %{body: String.t() | nil, page_total: non_neg_integer()},
          Request.t(),
          Plan.Read.t(),
          MediaType.t(),
          pos_integer()
        ) :: Plug.Conn.t()
  def put(conn, result, %Request{} = request, plan, media, status) do
    conn = put_applied(conn, request, [:return, :count, :tx])
    rows_or_empty(conn, result, request, {plan, media}, {status, 204})
  end

  @doc """
  Sends the response of a `PATCH` or `DELETE`: 204 without a body, or 200 with the rows for
  `return=representation` (as one object for the `vnd.pgrst.object` media type).

  `Content-Range` is PostgREST's: `0-<n-1>/<total>` for an update (`*` when it touched no
  row) and `*/<total>` for a delete, where `<total>` is the rows touched under `count=exact`
  or `count=estimated`, else `*`. `Preference-Applied` echoes `missing` (updates only),
  `return`, `count`, `tx`, `timezone` and, under `handling=strict`, `max-affected`.
  """
  @spec mutation(
          Plug.Conn.t(),
          %{body: String.t() | nil, page_total: non_neg_integer()},
          Request.t(),
          Plan.Read.t(),
          MediaType.t(),
          :update | :delete
        ) :: Plug.Conn.t()
  def mutation(conn, result, %Request{prefer: prefer} = request, plan, media, kind) do
    conn =
      conn
      |> Plug.Conn.put_resp_header("content-range", mutation_range(kind, prefer, result))
      |> put_applied(request, mutation_applied(kind))

    rows_or_empty(conn, result, request, {plan, media}, {200, 204})
  end

  # The tail of a write: the rows (after `after_load/2`) for `return=representation` with
  # the first status, else an empty body with the second. Like PostgREST, `Content-Profile`
  # goes with a body only.
  defp rows_or_empty(
         conn,
         result,
         %Request{prefer: prefer} = request,
         {plan, media},
         {status, empty}
       ) do
    if prefer.return == :representation do
      content_type = MediaType.content_type(media)
      conn = put_profile(conn, request)
      loaded(conn, result.body, plan, &send(conn, result.gucs, status, content_type, &1))
    else
      send(conn, result.gucs, empty, nil, "")
    end
  end

  @doc """
  Sends the response of a request answered with the plan media type: the plan text from
  `PgRest.Executor.explain/3`, typed as `media`, with `Content-Profile` as for any successful
  response (a write too, which names no profile without a body).
  """
  @spec plan(Plug.Conn.t(), String.t(), Request.t(), MediaType.t()) :: Plug.Conn.t()
  def plan(conn, text, request, media) do
    conn
    |> put_profile(request)
    |> send(ResponseGucs.none(), 200, MediaType.content_type(media), text)
  end

  defp mutation_applied(:update), do: [:missing, :return, :count, :tx, :max_affected]
  defp mutation_applied(:delete), do: [:return, :count, :tx, :max_affected]

  defp mutation_range(kind, %{count: count}, %{page_total: page_total}) do
    total = if count in [:exact, :estimated], do: Integer.to_string(page_total), else: "*"

    range =
      if kind == :update and page_total > 0, do: "0-#{page_total - 1}", else: "*"

    range <> "/" <> total
  end

  # `count=exact` and `estimated` report the rows written; `planned` and none report `*`.
  defp insert_total(%{count: count}, %{page_total: total}) when count in [:exact, :estimated],
    do: Integer.to_string(total)

  defp insert_total(_prefer, _result), do: "*"

  defp put_location(conn, nil), do: conn
  defp put_location(conn, location), do: Plug.Conn.put_resp_header(conn, "location", location)

  defp respond(conn, 416, _type, offset, %{total: total}, _request, _plan),
    do: error(conn, Error.offset_out_of_bounds(offset, total))

  defp respond(conn, status, type, _offset, result, request, plan) do
    loaded(conn, result.body, plan, fn body ->
      send(conn, result.gucs, status, type, head_body(body, request))
    end)
  end

  defp head_body(_body, %Request{method: "HEAD"}), do: ""
  defp head_body(body, _request), do: body

  # PostgREST's rangeStatus: 416 past a known total, 206 for a strict subset of it.
  defp status(_offset, %{total: nil}), do: 200
  defp status(offset, %{total: total}) when offset > total, do: 416
  defp status(_offset, %{total: total, page_total: page_total}) when page_total < total, do: 206
  defp status(_offset, _result), do: 200

  defp content_range(offset, %{page_total: page_total, total: total}) do
    range =
      if total == 0 or page_total == 0, do: "*", else: "#{offset}-#{offset + page_total - 1}"

    "#{range}/#{total || "*"}"
  end

  # The request path with the query parameters sorted by key, as PostgREST's canonical
  # query string (Haskell's `urlEncodeVars`): values of a repeated key join with `,`
  # and every non-ASCII byte is encoded as if it were a Latin-1 character.
  defp content_location(plan, request) do
    table = plan.resource.__pgrest_config__().table

    query =
      request.params
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.chunk_by(&elem(&1, 0))
      |> Enum.map_join("&", fn [{key, _value} | _] = group ->
        encode_part(key) <> "=" <> Enum.map_join(group, ",", &encode_part(elem(&1, 1) || ""))
      end)

    if query == "", do: "/" <> table, else: "/" <> table <> "?" <> query
  end

  @doc false
  @spec encode_part(String.t()) :: String.t()
  def encode_part(text), do: for(<<byte <- text>>, into: "", do: encode_byte(byte))

  defp encode_byte(byte) when byte in ?a..?z or byte in ?A..?Z or byte in ?0..?9, do: <<byte>>
  defp encode_byte(byte) when byte in ~c"-_.~", do: <<byte>>
  defp encode_byte(byte) when byte < 0x80, do: "%" <> Base.encode16(<<byte>>)

  defp encode_byte(byte) do
    utf8 = <<byte::utf8>>
    for <<b <- utf8>>, into: "", do: "%" <> Base.encode16(<<b>>)
  end

  # PostgREST names the schema of a successful response when it was negotiated (a profile
  # header, or several exposed schemas). `error/2` drops it again.
  defp put_profile(conn, %Request{profile_negotiated?: true, schema: schema}),
    do: Plug.Conn.put_resp_header(conn, "content-profile", schema)

  defp put_profile(conn, _request), do: conn

  # Only preferences the response applied, a valid timezone, and handling when the client sent
  # it. `max-affected` is applied (under strict handling) by updates, deletes and calls only.
  defp put_applied(conn, %Request{prefer: prefer}, applied) do
    keys = [:timezone | applied] ++ if(prefer.handling_sent, do: [:handling], else: [])

    case PreferParser.applied_header(prefer, keys) do
      nil -> conn
      value -> Plug.Conn.put_resp_header(conn, "preference-applied", value)
    end
  end

  # --- after_load ---------------------------------------------------------------

  # Sends through `send_fun` the body after `after_load/2`. An embed that should have been
  # processed but is missing from a row fails closed: a generic 500, never the raw row.
  defp loaded(conn, body, plan, send_fun) do
    case after_load(body, plan, conn) do
      {:ok, body} ->
        send_fun.(body)

      {:error, module} ->
        Logger.error(
          "PgRest: after_load embed missing or of an unexpected shape in a row of #{inspect(module)}"
        )

        error(conn, Error.internal())
    end
  end

  defp after_load(body, plan, conn) do
    if Plan.Read.after_load?(plan) do
      context = conn.private |> Map.get(:pgrest_context, %{})
      # Plain `Jason` decoding: callbacks see floats, so a non-integer number is re-encoded
      # as a float (`1.50` -> `1.5`, digits past double precision rounded). Integers are exact.
      decoded = Jason.decode!(body)

      with :ok <- validate(decoded, plan) do
        {:ok, Jason.encode!(apply_rows(decoded, plan, context))}
      end
    else
      {:ok, body}
    end
  end

  # --- shape validation ------------------------------------------------------------
  #
  # Before any callback runs, every embed whose rows need `after_load/2` (or merging) must
  # be in the decoded body with the shape the plan implies: an object or null for a to-one
  # embed, an array of objects for a to-many one. Anything else would leave sub-rows
  # unprocessed or crash the merge, so the response fails closed.

  # `null`: a function returning one row returned none.
  defp validate(nil, _plan), do: :ok
  defp validate(rows, plan) when is_list(rows), do: validate_all(rows, plan)
  defp validate(row, plan) when is_map(row), do: validate_row(row, plan)
  defp validate(_other, plan), do: {:error, plan.resource}

  defp validate_all(rows, plan), do: Result.all_ok(rows, &validate(&1, plan))

  defp validate_row(row, plan) do
    plan.embeds
    |> Enum.filter(&processed?/1)
    |> Result.all_ok(&validate_embed(row, &1, plan))
  end

  defp validate_embed(row, embed, plan) do
    with {:ok, value} <- Map.fetch(row, embed_key(embed)),
         true <- shape?(value, Plan.Embed.to_one?(embed)) do
      validate_value(value, embed.plan)
    else
      _bad -> {:error, plan.resource}
    end
  end

  defp validate_value(nil, _plan), do: :ok
  defp validate_value(value, plan), do: validate(value, plan)

  defp shape?(value, true), do: is_nil(value) or is_map(value)
  defp shape?(value, false), do: is_list(value) and Enum.all?(value, &is_map/1)

  defp processed?(%{spread: true}), do: false

  defp processed?(embed) do
    Embed.spread_columns(embed.plan) != [] and (embed.merge or Plan.Read.after_load?(embed.plan))
  end

  defp embed_key(%{merge: true, merge_key: key}), do: key
  defp embed_key(%{output_name: name}), do: name

  # --- applying the callbacks --------------------------------------------------------

  defp apply_rows(rows, plan, context) when is_list(rows),
    do: Enum.map(rows, &apply_rows(&1, plan, context))

  # Children first, then the row's own callback, exactly once per row: each child embed is
  # processed by the plan's planned key, spreads are merged, and only then does the row's
  # `after_load/2` run. No child key is looked up after a callback could have renamed it.
  defp apply_rows(row, plan, context) when is_map(row) do
    row =
      plan.embeds
      |> Enum.reject(&(&1.spread or &1.merge))
      |> Enum.reduce(row, fn %{output_name: name, plan: embed_plan}, acc ->
        if is_map_key(acc, name),
          do: Map.update!(acc, name, &apply_rows(&1, embed_plan, context)),
          else: acc
      end)

    row =
      plan.embeds
      |> Enum.filter(& &1.merge)
      |> Enum.reduce(row, &merge_spread(&2, &1, context))

    if plan.resource.__pgrest_config__().after_load,
      do: plan.resource.after_load(row, context),
      else: row
  end

  defp apply_rows(value, _plan, _context), do: value

  # A spread whose target runs `after_load/2` arrives as an object (to-one) or an array of
  # objects (to-many) under the embed's merge key. After the callbacks ran on it, its
  # columns merge into the parent row; a to-many spread becomes one array per column.
  defp merge_spread(row, embed, context) do
    {value, row} = Map.pop(row, embed.merge_key)

    case apply_rows(value, embed.plan, context) do
      nil -> Map.merge(row, empty_columns(embed, context, nil))
      [] -> Map.merge(row, empty_columns(embed, context, []))
      rows when is_list(rows) -> Map.merge(row, transpose(rows))
      object when is_map(object) -> Map.merge(row, object)
    end
  end

  defp transpose(rows) do
    keys = rows |> Enum.flat_map(&Map.keys/1) |> Enum.uniq()
    Map.new(keys, fn key -> {key, Enum.map(rows, &Map.get(&1, key))} end)
  end

  # No row to run `after_load/2` on: run it on a placeholder row of nils and keep only the
  # keys it leaves, so columns it removes are not revealed. A callback that cannot handle
  # the placeholder yields no columns at all.
  defp empty_columns(embed, context, empty) do
    embed.plan
    |> loaded_placeholder(context)
    |> Map.new(fn {key, _value} -> {key, empty} end)
  rescue
    _exception -> %{}
  end

  # An inner callback that cannot handle its placeholder yields no columns for that merged
  # embed only; the outer and sibling columns survive.
  defp safe_placeholder(plan, context) do
    loaded_placeholder(plan, context)
  rescue
    _exception -> %{}
  end

  # Children first, like `apply_rows/3`: a nested merge embed contributes the keys its own
  # `after_load/2` leaves on its placeholder, so the outer callback never sees columns an
  # inner one removed.
  defp loaded_placeholder(plan, context) do
    {merged, rest} = Enum.split_with(plan.embeds, & &1.merge)
    base = Map.new(Embed.spread_columns(%{plan | embeds: rest}), &{&1, nil})

    row =
      Enum.reduce(merged, base, fn embed, acc ->
        Map.merge(acc, safe_placeholder(embed.plan, context))
      end)

    if plan.resource.__pgrest_config__().after_load,
      do: plan.resource.after_load(row, context),
      else: row
  end

  # --- sending ------------------------------------------------------------------

  # Every response goes out here. A successful one carries the decoded GUCs the statement
  # read: they are overlaid last, after the content type is set, so they win over every
  # generated header and the generated status. An error passes `ResponseGucs.none/0`, so
  # whatever GUCs the failed statement set never reach it. A `nil` content type sets none (a void 204, a
  # minimal write). The body and a GUC `Content-Type` override both come from the database, as
  # in PostgREST (a function can answer `text/html`), so no request value reaches either.
  defp send(conn, gucs, status, content_type, body) do
    conn
    |> put_content_type(content_type)
    |> ResponseGucs.apply(gucs)
    |> Plug.Conn.resp(ResponseGucs.status(gucs, status), body)
    |> Plug.Conn.send_resp()
  end

  defp put_content_type(conn, nil), do: conn
  defp put_content_type(conn, type), do: Plug.Conn.put_resp_header(conn, "content-type", type)
end
