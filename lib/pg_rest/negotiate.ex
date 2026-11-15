defmodule PgRest.Negotiate do
  @moduledoc """
  Picks the response media type of a request from its `Accept` types and what the endpoint
  can produce, as PostgREST's content negotiation does.

  `offered/1` lists the kinds every endpoint answers (a table, or a function of any return
  type, as recorded from PostgREST): JSON, `vnd.pgrst.object`, `vnd.pgrst.array` and CSV.
  `application/geo+json` is never offered (PostGIS is not supported), so it
  gets the ordinary `PGRST107`.

  ## The plan type

  `application/vnd.pgrst.plan` answers with the execution plan of the statement the request
  would run for the type it is `for=` (`application/json` by default): offered only for a
  `for=` this library serves (JSON, `*/*`, object, array, CSV), never for a custom media
  handler (`text/xml`, `application/vnd.twkb`).

  `negotiate/1` is provisional (it fails early when nothing at all is acceptable and never
  looks at the gate); `resolve/5` picks the **final** media type once the plan is known, with
  the plan gate and the `after_load/2` restrictions applied to the same choice, so a plan
  type that did not pass the gate cannot be returned. A plan is offered only when:

    * the plug option `plan_enabled` allows it (the function is called only when a plan type
      is in `Accept`);
    * the `:explain` operation is allowed on every resource the request touches
      (`PgRest.Authorization`);
    * `options=analyze` of something that writes has `Prefer: tx=rollback` honoured
      (`tx_end: :commit_allow_override`).

  A request the gate refuses gets the `PGRST107` of a plan that is not there, by any of the
  three reasons and whatever else is wrong with the request, so a denial is no oracle.

  ## Differences from PostgREST

    * PostgREST also serves `application/geo+json`; here it is always a `PGRST107` (no PostGIS).
    * For a request that reads a resource with `after_load/2` (a PgRest concept), CSV and
      `nulls=stripped` are not offered: the callbacks need decoded JSON rows with their nulls, and
      skipping them could leak what they redact. A client that also accepts JSON gets JSON;
      PostgREST would send CSV.
    * `options=analyze` on a write (or a call that may write) needs `Prefer: tx=rollback`, since
      `EXPLAIN ANALYZE` runs it. PostgREST runs it and commits unless the client asks for a
      rollback, so `Accept: application/vnd.pgrst.plan; options=analyze` on `POST /t` inserts a
      row there and is a `PGRST107` here. Rollback does not undo sequences or effects outside
      the transaction, and a custom `changeset/3` runs for a plan request as for any write.
    * A plan is also refused when the authorization hook denies `:explain`; PostgREST has no
      such operation.
    * A plan `for=` a custom media handler (`text/xml` on a scalar function, an aggregate such
      as `application/vnd.twkb`) is a `PGRST107` here; PostgREST explains the handler.
  """

  alias PgRest.{Authorization, Error, MediaType, Plan, Request}

  @kinds [:json, :object, :array, :csv]

  @doc "The media kinds an endpoint answers. Option `:plan?` (default `false`) adds `:plan`."
  @spec offered(keyword()) :: [MediaType.kind()]
  def offered(opts \\ []) do
    if Keyword.get(opts, :plan?, false), do: @kinds ++ [:plan], else: @kinds
  end

  @doc """
  The first of `accepts` (by descending `q`) whose kind is in `offered`; `*/*` is JSON and no
  `Accept` types at all is JSON. A plan type is chosen only when `:plan` is offered, its
  `for=` type is one of `offered` and `plan_ok?` (a function of the plan media type, default
  always true) agrees. Else the 406 `PGRST107` listing the types by canonical name (as
  PostgREST does), in the sorted order. Option `:stripped?` (default `true`) is `false` to
  refuse `nulls=stripped` types.
  """
  @spec choose([MediaType.t()], [MediaType.kind()], keyword()) ::
          {:ok, MediaType.t()} | {:error, Error.t()}
  def choose(accepts, offered, opts \\ [])
  def choose([], _offered, _opts), do: {:ok, MediaType.json()}

  def choose(accepts, offered, opts) do
    stripped? = Keyword.get(opts, :stripped?, true)
    plan_ok? = Keyword.get(opts, :plan_ok?, fn _plan -> true end)

    case Enum.find(accepts, &acceptable?(&1, offered, stripped?, plan_ok?)) do
      nil -> {:error, Error.unsupported_media(Enum.map(accepts, & &1.raw))}
      %MediaType{kind: :any} -> {:ok, MediaType.json()}
      media -> {:ok, media}
    end
  end

  defp acceptable?(%MediaType{kind: :any}, _offered, _stripped?, _plan_ok?), do: true

  defp acceptable?(%MediaType{kind: :plan, plan: %{for: target}} = media, offered, stripped?, ok?) do
    :plan in offered and (stripped? or not target.nulls_stripped?) and
      (target.kind == :any or target.kind in List.delete(offered, :plan)) and ok?.(media)
  end

  defp acceptable?(%MediaType{kind: kind, nulls_stripped?: stripped}, offered, stripped?, _ok?),
    do: kind in offered and (stripped? or not stripped)

  @doc """
  The provisional media type, before planning: `choose/3` over every kind, plan included, so a
  request nothing can answer fails before anything is planned. It never looks at the plan
  gate, which `resolve/5` applies to the final choice, so the order of the errors does not
  depend on it.
  """
  @spec negotiate(Request.t()) :: {:ok, MediaType.t()} | {:error, Error.t()}
  def negotiate(%Request{accepts: accepts}), do: choose(accepts, offered(plan?: true))

  @doc """
  The final media type, once the plan is known: the one structural step that decides it.

  `plan` is the plan the response reads (`nil` for a write without a representation). A plan
  with an `after_load/2` resource (callbacks work on decoded JSON rows) is not answered as CSV
  or with the nulls stripped, and the plan type is offered only through the gate (see the
  moduledoc). Both restrictions shape one `choose/3`, so a client that also accepts JSON falls
  back to it and anything else gets the `PGRST107` listing every type it asked for.

  `context` carries the `plan_enabled` setting (`false`, `true`, or `(conn, context ->
  boolean)`; only `true` counts) and the `authorization` module. Options: `:targets` (the
  resources and function `:explain` is asked on, default `Plan.Read.targets(plan)`) and
  `:mutating?` (default `false`: a write, or a call that may write).
  """
  @spec resolve(Request.t(), Plan.Read.t() | nil, Plug.Conn.t(), map(), keyword()) ::
          {:ok, MediaType.t()} | {:error, Error.t()}
  def resolve(%Request{accepts: accepts} = request, plan, conn, context, opts \\ []) do
    loaded? = plan != nil and Plan.Read.after_load?(plan)
    kinds = if loaded?, do: List.delete(@kinds, :csv), else: @kinds

    state = plan_state(request.authorization_state, plan)
    gate = plan_gate(request, conn, context, opts, plan, state)

    choose(accepts, [:plan | kinds], stripped?: not loaded?, plan_ok?: gate)
  end

  defp plan_state(state, nil), do: state
  defp plan_state(state, plan), do: %{state | nodes: Plan.Read.authorization_nodes(plan)}

  # Whether a plan type may be answered; evaluated at most once, and only when `Accept` names
  # one (the `plan_enabled` function is the caller's code).
  defp plan_gate(%Request{accepts: accepts} = request, conn, context, opts, plan, state) do
    if Enum.any?(accepts, &(&1.kind == :plan)) and enabled?(context, conn) and
         explain?(context, conn, targets(opts, plan), state) do
      mutating? = Keyword.get(opts, :mutating?, false)
      fn media -> not unsafe_analyze?(media.plan, request, mutating?) end
    else
      fn _media -> false end
    end
  end

  defp enabled?(%{plan_enabled: true}, _conn), do: true

  defp enabled?(%{plan_enabled: setting} = context, conn) when is_function(setting, 2),
    do: setting.(conn, context) == true

  defp enabled?(_context, _conn), do: false

  defp explain?(context, conn, targets, state),
    do: Authorization.explain?(Map.get(context, :authorization), conn, targets, context, state)

  defp targets(opts, plan),
    do: Keyword.get_lazy(opts, :targets, fn -> Plan.Read.targets(plan) end)

  defp unsafe_analyze?(%{options: options}, %Request{prefer: prefer}, mutating?),
    do: mutating? and :analyze in options and prefer.tx != :rollback
end
