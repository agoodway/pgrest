defmodule PgRest.RPC.Args do
  @moduledoc """
  Splits an RPC request into function arguments and row filters, as PostgREST's
  `pRequestFilter`/`isRpcRead` do, and builds the arguments of the call.

  On a read (GET/HEAD) the query string carries both: a key is a filter when it is reserved
  or `PgRest.Grammar.Filter.parse_condition/2` accepts its value, and an argument otherwise.
  On a POST every query parameter is a filter and the arguments are the keys of the JSON body
  (an array body: the keys its objects share), or the `columns=` list when given.
  A parameter without a value (`?a`) is dropped, as PostgREST's `nonemptyParams` does.
  """

  alias PgRest.{Error, Function, Plan, Request, Write}
  alias PgRest.Grammar.Filter
  alias PgRest.Planner.Params
  alias PgRest.RPC.Resolver
  alias PgRest.Write.Payload

  # The body media types a POST can carry to a single unnamed parameter; anything else is JSON.
  @body_media %{
    "text/plain" => :text,
    "text/xml" => :xml,
    "application/octet-stream" => :bytea
  }

  @doc """
  Returns `{argument_keys, filter_params}` for an invocation (`invocation/1`). Argument keys
  are deduplicated; the resolver matches them as a set.
  """
  @spec split(Request.t(), Resolver.invocation()) ::
          {[String.t()], [{String.t(), String.t()}]}
  def split(%Request{params: params}, :read) do
    {args, filters} = read_split(params)
    {args |> Enum.map(&elem(&1, 0)) |> Enum.uniq(), filters}
  end

  def split(%Request{params: params} = request, :post),
    do: {post_keys(request), valued(params)}

  def split(%Request{} = request, {:post, _media}), do: split(request, :post)

  @doc """
  The body media type of a `conn` (its `Content-Type`): `:text`, `:xml`, `:bytea`, or `:json`
  for anything else, as PostgREST defaults to JSON.
  """
  @spec body_media(Plug.Conn.t()) :: :json | :text | :xml | :bytea
  def body_media(%Plug.Conn{} = conn) do
    type =
      conn
      |> Plug.Conn.get_req_header("content-type")
      |> List.first("")
      |> Request.media_base()

    Map.get(@body_media, type, :json)
  end

  @doc "How the request calls its function, for `PgRest.RPC.Resolver.resolve/5`."
  @spec invocation(Request.t()) :: Resolver.invocation()
  def invocation(%Request{method: method}) when method in ["GET", "HEAD"], do: :read
  def invocation(%Request{conn: conn}), do: {:post, body_media(conn)}

  @doc """
  Checks a JSON RPC body before resolution: an array must hold objects that all have the same
  keys (`PGRST102`), as a bulk write's rows must. A `columns=` list must parse.
  """
  @spec check_body(Request.t()) :: :ok | {:error, Error.t()}
  def check_body(%Request{body: body} = request) when is_list(body) do
    with {:ok, columns} <- Write.columns(request.params),
         {:ok, _keys} <- Payload.uniform_keys(body, columns),
         do: :ok
  end

  def check_body(%Request{} = request) do
    with {:ok, _columns} <- Write.columns(request.params), do: :ok
  end

  @doc """
  The arguments of the call of `function` (`PgRest.Plan.Call` `args`). A read passes the
  function's parameters the query string names (a variadic one every value in order, any other
  the last). A JSON POST passes the raw body once, to `json_to_recordset`, or whole to a single
  unnamed parameter; a non-JSON POST always reaches a single unnamed parameter.
  """
  @spec call_args(Request.t(), Function.t()) :: Plan.Call.args()
  def call_args(%Request{method: method} = request, %Function{} = function)
      when method in ["GET", "HEAD"] do
    {params, _filters} = read_split(request.params)

    args =
      for %{name: name} = param <- function.params, List.keymember?(params, name, 0), into: %{} do
        values = for {^name, value} <- params, do: value
        {name, if(param.variadic?, do: values, else: List.last(values))}
      end

    {:direct, args}
  end

  def call_args(%Request{} = request, %Function{params: [%{name: ""}]}),
    do: {:single, raw_body(request)}

  def call_args(%Request{} = request, %Function{}),
    do: {:json, raw_body(request), post_keys(request)}

  # The body bytes (`PgRest.Request.body_bytes/1`); no body at all is empty.
  defp raw_body(%Request{body: nil, raw_body: nil}), do: ""
  defp raw_body(%Request{} = request), do: Request.body_bytes(request)

  defp post_keys(%Request{params: params, body: body}) do
    case Write.columns(params) do
      {:ok, columns} when is_list(columns) -> Enum.uniq(columns)
      _none_or_invalid -> body_keys(body)
    end
  end

  # The argument pairs and the filter pairs of a read's query string.
  defp read_split(params) do
    {filters, args} = params |> valued() |> Enum.split_with(&filter?/1)
    {args, filters}
  end

  defp valued(params), do: Enum.reject(params, fn {_key, value} -> is_nil(value) end)

  defp filter?({key, value}),
    do: Params.reserved_key?(key) or match?({:ok, _}, Filter.parse_condition(key, value))

  defp body_keys(%{} = body), do: Map.keys(body)
  defp body_keys([%{} = first | _rest]), do: body_keys(first)
  defp body_keys(_empty), do: []
end
