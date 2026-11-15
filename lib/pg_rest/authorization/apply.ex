defmodule PgRest.Authorization.Apply do
  @moduledoc """
  Applies a policy to one scoped source. `Authorization.check/5` runs first; the query
  callback can only narrow the base query. Columns are physical database column names.

  ## Differences from PostgREST

  Query policies are an application extension to database privileges/RLS. Stars expand
  to permitted columns; an explicit hidden-column reference is 42501. Counts and aggregates
  require explicit grants and permission limits cap their input rows, including totals.
  PostgREST's db-max-rows limits output rows and does not cap exact totals.
  With a permission cap, all count modes return the exact capped total instead of
  a planner estimate, so an estimate cannot disclose rows outside the visible set.
  RPCs with `result_scope: :none` discard row predicates only; hook denials, columns,
  count/aggregate grants and permission limits still apply.
  Hook narrowing needs a primary or unique key for source intersection; otherwise 42501.
  PostgREST can apply RLS to keyless tables.
  """

  alias PgRest.Authorization
  alias PgRest.SQL.ScopedSource

  @type policy :: %{
          query: Ecto.Query.t() | nil,
          columns: :all | MapSet.t(String.t()),
          limit: pos_integer() | nil,
          aggregates?: boolean(),
          count?: boolean()
        }

  @doc """
  Authorizes and narrows one path/operation. Options `:authorize?` and `:rows?`
  default to true; disabling the bare check never disables query narrowing.
  With `rows?: false`, the hook still decides admission, columns, limits and grants,
  but its row predicate is discarded without requiring a key.
  """
  @spec source(
          Plug.Conn.t(),
          module() | nil,
          module(),
          Authorization.operation(),
          Ecto.Query.t(),
          map(),
          keyword()
        ) :: {:ok, policy()} | {:error, :denied}
  def source(conn, auth, resource, operation, base, context, opts \\ []) do
    with :ok <-
           gate(Keyword.get(opts, :authorize?, true), auth, conn, resource, operation, context) do
      narrow(
        Authorization.query_hook?(auth),
        conn,
        auth,
        resource,
        operation,
        base,
        context,
        Keyword.get(opts, :rows?, true)
      )
    end
  end

  defp gate(false, _auth, _conn, _resource, _op, _ctx), do: :ok

  defp gate(true, auth, conn, resource, op, ctx) do
    case Authorization.check(auth, conn, resource, op, ctx) do
      :ok -> :ok
      {:error, _} -> {:error, :denied}
    end
  end

  defp narrow(false, _conn, _auth, _resource, _op, base, _ctx, _rows?),
    do: {:ok, unrestricted(base)}

  defp narrow(true, conn, auth, resource, op, base, ctx, rows?) do
    with {:ok, query, opts, _explicit?} <- query_result(auth, conn, resource, op, base, ctx),
         %Ecto.Query{} = query <- row_source(rows?, base, query, resource) do
      {:ok,
       %{
         unrestricted(query)
         | columns: column_set(Keyword.get(opts, :columns, :all)),
           limit: opts[:limit],
           aggregates?: Keyword.get(opts, :aggregates, false),
           count?: Keyword.get(opts, :count, false)
       }}
    end
  end

  defp row_source(false, base, _query, _resource), do: base
  defp row_source(true, base, query, resource), do: ScopedSource.intersect(base, query, resource)

  @doc "An unrestricted policy over a source (nil for a non-resource result)."
  @spec unrestricted(Ecto.Query.t() | nil) :: policy()
  def unrestricted(query),
    do: %{query: query, columns: :all, limit: nil, aggregates?: true, count?: true}

  @doc "The smaller non-nil permission limit."
  @spec min_limit(non_neg_integer() | nil, non_neg_integer() | nil) :: non_neg_integer() | nil
  def min_limit(nil, b), do: b
  def min_limit(a, nil), do: a
  def min_limit(a, b), do: min(a, b)

  @doc "Intersects grants, retaining the left flags; columns: :left retains a read grant."
  @spec combine(policy(), policy(), module(), keyword()) :: {:ok, policy()} | {:error, :denied}
  def combine(a, b, resource, opts \\ []) do
    with %Ecto.Query{} = query <- ScopedSource.intersect(a.query, b.query, resource) do
      columns = combine_columns(Keyword.get(opts, :columns, :intersect), a.columns, b.columns)
      {:ok, %{a | query: query, columns: columns, limit: min_limit(a.limit, b.limit)}}
    end
  end

  defp combine_columns(:left, a, _b), do: a
  defp combine_columns(:intersect, a, b), do: intersect_columns(a, b)

  @doc "Intersects physical-column grants."
  @spec intersect_columns(:all | MapSet.t(), :all | MapSet.t()) :: :all | MapSet.t()
  def intersect_columns(:all, b), do: b
  def intersect_columns(a, :all), do: a
  def intersect_columns(a, b), do: MapSet.intersection(a, b)

  @doc "Whether every physical source name belongs to a column grant."
  @spec permits?(:all | MapSet.t(), [String.t()]) :: boolean()
  def permits?(:all, _sources), do: true
  def permits?(columns, sources), do: Enum.all?(sources, &MapSet.member?(columns, &1))

  @doc "Whether an Ecto field belongs to a physical-column grant."
  @spec column_allowed?(:all | MapSet.t(), module(), atom() | String.t()) :: boolean()
  def column_allowed?(columns, resource, field),
    do: check_columns(columns, resource, [to_string(field)]) == :ok

  @doc "Checks Ecto field names against a policy's physical column allowlist."
  @spec check_columns(:all | MapSet.t(), module(), [String.t()]) :: :ok | {:error, :denied}
  def check_columns(:all, _resource, _fields), do: :ok

  def check_columns(columns, resource, fields) do
    sources = resource.__pgrest_config__().field_columns

    if permits?(columns, Enum.map(fields, &Map.get(sources, &1))),
      do: :ok,
      else: {:error, :denied}
  end

  @doc "Explicit EXPLAIN admission; the plan still explains the original authorized statement."
  @spec explain_granted?(module(), Plug.Conn.t(), module(), Ecto.Query.t(), map()) :: boolean()
  def explain_granted?(auth, conn, resource, base, context) do
    match?({:ok, _, _, true}, query_result(auth, conn, resource, :explain, base, context))
  end

  defp query_result(auth, conn, resource, op, base, context) do
    auth.authorize_query(conn, resource, op, base, context)
    |> validate_result(auth, resource, op)
  end

  defp validate_result({:ok, %Ecto.Query{}}, _auth, _resource, :explain), do: {:error, :denied}

  defp validate_result({:ok, %Ecto.Query{} = query}, auth, resource, _op),
    do: {:ok, ScopedSource.hook_query!(query, resource, auth), [], false}

  defp validate_result({:ok, %Ecto.Query{} = query, opts}, auth, resource, op)
       when is_list(opts) do
    validate_result_options!(op, opts, auth, resource)
    {:ok, ScopedSource.hook_query!(query, resource, auth), opts, true}
  end

  defp validate_result(_result, _auth, _resource, _op), do: {:error, :denied}
  defp validate_result_options!(:explain, _opts, _auth, _resource), do: :ok

  defp validate_result_options!(_op, opts, auth, resource),
    do: validate_options!(opts, auth, resource)

  defp column_set(:all), do: :all
  defp column_set(names), do: MapSet.new(names)

  defp validate_options!(opts, auth, resource) do
    valid? = Keyword.keyword?(opts) and Enum.all?(opts, &valid_option?/1)

    if not valid? do
      raise ArgumentError,
            "invalid authorize_query/5 options from #{inspect(auth)} for #{inspect(resource)}"
    end
  end

  defp valid_option?({:columns, :all}), do: true
  defp valid_option?({:columns, names}) when is_list(names), do: Enum.all?(names, &is_binary/1)
  defp valid_option?({:limit, nil}), do: true
  defp valid_option?({:limit, n}) when is_integer(n) and n > 0, do: true
  defp valid_option?({key, flag}) when key in [:aggregates, :count], do: is_boolean(flag)
  defp valid_option?(_option), do: false
end
