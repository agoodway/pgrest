defmodule PgRest.Function do
  @moduledoc """
  A database function a `PgRest.Registry` exposes for RPC.

  Functions reach a registry two ways: introspected from `pg_proc`
  (`PgRest.Function.Introspect`, the registry's `introspect:` option) or declared by a module
  (the registry's `functions:` option):

      defmodule MyApp.Rpc.GetStatus do
        use PgRest.Function,
          schema: "public",
          name: "get_status",
          params: [{"name_param", "text"}],
          returns: {:scalar, "user_status"},
          volatility: :immutable
      end

  ## Options

    * `:schema`, `:name` (required) - the function's schema and name
    * `:params` - its input parameters, in order: `{name, type}`, `{name, type, default: true}`
      (optional) or `{name, type, variadic: true}` (default `[]`)
    * `:returns` (required) - `:void`, `{:scalar, type}`, `{:setof_scalar, type}`,
      `{:composite, resource_module | [{column, type}]}` or
      `{:setof, resource_module | [{column, type}]}`. Declared `{column, type}` columns carry
      no type category (only introspected ones do), so a filter on them always binds a typed
      `$n::text::<type>`, never the bare `$n` a string or enum column of a resource or an
      introspected function gets; declare an enum result through a resource to match that
    * `:volatility` - `:immutable`, `:stable` or `:volatile` (default `:volatile`, like
      Postgres)
    * `:result_scope` - `:stored_rows` (default) or `:none`. Under `:stored_rows` a function
      returning a scoped resource keeps only the rows that match a stored, in-scope row in
      every column, compared with `IS NOT DISTINCT FROM`. That comparison needs an equality
      operator for each column type, so a resource with a `json`, `point` or `xml` column
      fails with Postgres' `42883`; give such a function `result_scope: :none`.

  In application mode calls run as the repo role. Introspection therefore requires
  `only:`/`except:` or an authorization module exporting `authorize/4`. `as_role:`
  filters EXECUTE privileges; extension-owned and trigger/internal functions are skipped.
  See the RPC guide for registry setup.

  VOLATILE functions returning custom-scoped resources must declare `result_scope: :none`.
  The default drops fabricated or altered rows; `:none` is an explicit trust boundary.
  Introspected functions configure this through the registry's `function_opts:` map.

  Each overload is its own module. A declared function replaces an introspected one with the
  same schema, name and parameter names.
  """

  alias PgRest.Function.{Param, Return}
  alias PgRest.Options

  @enforce_keys [:schema, :name, :params, :returns, :volatility]
  defstruct [
    :schema,
    :name,
    :params,
    :returns,
    :volatility,
    result_scope: :stored_rows,
    module: nil
  ]

  @type volatility :: :immutable | :stable | :volatile
  @type result_scope :: :stored_rows | :none

  @type t :: %__MODULE__{
          schema: String.t(),
          name: String.t(),
          params: [Param.t()],
          returns: Return.t(),
          volatility: volatility(),
          result_scope: result_scope(),
          module: module() | nil
        }

  @volatilities [:immutable, :stable, :volatile]
  @result_scopes [:stored_rows, :none]
  @options [:schema, :name, :params, :returns, :volatility, :result_scope]

  defmodule Param do
    @moduledoc """
    An input (`IN`, `INOUT` or `VARIADIC`) parameter of a `PgRest.Function`. `name` is `""`
    for an unnamed parameter; `type` is `pg_catalog.format_type(oid, NULL)` text.
    """

    @enforce_keys [:name, :type]
    defstruct [:name, :type, required?: true, variadic?: false]

    @type t :: %__MODULE__{
            name: String.t(),
            type: String.t(),
            required?: boolean(),
            variadic?: boolean()
          }
  end

  defmodule Return do
    @moduledoc """
    What a `PgRest.Function` returns.

      * `kind` - `:void`, `:scalar` or `:composite`. A function with any `OUT`, `INOUT` or
        `TABLE` parameter is `:composite`, even with a single one.
      * `set?` - whether it returns a set (`SETOF`, `TABLE`)
      * `type` - the return type's `format_type` text: `record` for several `OUT`/`TABLE`
        columns, the column's own type for a single `OUT`/`INOUT` parameter (`integer` for
        `single_out_param(num int, OUT num_plus_one int)`, still `:composite` with that one
        column), `schema.table` for a declared resource return
      * `columns` - `{name, type}` of the composite type's attributes or of the
        `OUT`/`INOUT`/`TABLE` parameters. A bare `record` has none, so no select or filter
        applies to it. A declared resource return has none either: its `resource` is the
        source of truth.
      * `categories` - `pg_type.typcategory` of each column, by name (`"S"` string, `"E"`
        enum, ...), when introspected; a string or enum column filters with a bare bind, as a
        resource column does
      * `resource` - the registered resource whose table is the composite type
    """

    @enforce_keys [:kind, :type]
    defstruct [:kind, :type, set?: false, columns: [], categories: %{}, resource: nil]

    @type t :: %__MODULE__{
            kind: :void | :scalar | :composite,
            set?: boolean(),
            type: String.t(),
            columns: [{String.t(), String.t()}],
            categories: %{String.t() => String.t()},
            resource: module() | nil
          }
  end

  defmacro __using__(opts) do
    quote bind_quoted: [opts: opts] do
      @pgrest_function_opts PgRest.Function.validate!(opts)

      @doc false
      @spec __pgrest_function__() :: PgRest.Function.t()
      def __pgrest_function__, do: PgRest.Function.build(__MODULE__, @pgrest_function_opts)
    end
  end

  @doc false
  # Compile-time shape check of the `use PgRest.Function` options.
  @spec validate!(keyword()) :: keyword()
  def validate!(opts) do
    Options.validate_keys!(opts, @options, "PgRest.Function")

    for key <- [:schema, :name] do
      unless is_binary(opts[key]),
        do: raise(ArgumentError, "PgRest.Function #{inspect(key)} must be a string")
    end

    opts
    |> Keyword.get(:params, [])
    |> List.wrap()
    |> Enum.each(&param!/1)

    return!(Keyword.get(opts, :returns))
    volatility = Keyword.get(opts, :volatility, :volatile)

    unless volatility in @volatilities,
      do: raise(ArgumentError, "invalid PgRest.Function :volatility: #{inspect(volatility)}")

    result_scope!(Keyword.get(opts, :result_scope, :stored_rows), opts[:name])
    opts
  end

  @doc """
  Raises `ArgumentError` unless `scope` is `:stored_rows` or `:none`; `name` names the
  function in the message.
  """
  @spec result_scope!(term(), String.t()) :: result_scope()
  def result_scope!(scope, _name) when scope in @result_scopes, do: scope

  def result_scope!(scope, name) do
    raise ArgumentError,
          "invalid result_scope #{inspect(scope)} for function #{name}; expected :stored_rows or :none"
  end

  @doc false
  # Builds the declared function. A resource return is resolved here, at run time, so
  # declaring a function adds no compile-time dependency on the resource.
  @spec build(module(), keyword()) :: t()
  def build(module, opts) do
    %__MODULE__{
      schema: opts[:schema],
      name: opts[:name],
      params: opts |> Keyword.get(:params, []) |> Enum.map(&param!/1),
      returns: opts[:returns] |> return!() |> resolve(),
      volatility: Keyword.get(opts, :volatility, :volatile),
      result_scope: Keyword.get(opts, :result_scope, :stored_rows),
      module: module
    }
  end

  @doc "The `\"schema.name\"` label of a function, as messages name it."
  @spec label(t()) :: String.t()
  def label(%__MODULE__{schema: schema, name: name}), do: "#{schema}.#{name}"

  # One classifier per declared shape, shared by the compile-time check (`validate!/1`) and the
  # run-time build (`build/2`), so the two cannot drift. Both are pure: a resource return is
  # only named here (`{:resource, module, set?}`) and resolved by `resolve/1` at run time.
  defp param!(spec), do: spec |> param() |> ok!("param", spec)

  defp return!(spec) do
    case return(spec) do
      {:error, :columns} ->
        raise ArgumentError, "invalid PgRest.Function :returns columns: #{inspect(elem(spec, 1))}"

      result ->
        ok!(result, ":returns", spec)
    end
  end

  defp ok!({:ok, value}, _what, _spec), do: value

  defp ok!(:error, what, spec),
    do: raise(ArgumentError, "invalid PgRest.Function #{what}: #{inspect(spec)}")

  defp param({name, type}) when is_binary(name) and is_binary(type),
    do: {:ok, %Param{name: name, type: type}}

  defp param({name, type, [default: true]}) when is_binary(name) and is_binary(type),
    do: {:ok, %Param{name: name, type: type, required?: false}}

  defp param({name, type, [variadic: true]}) when is_binary(name) and is_binary(type),
    do: {:ok, %Param{name: name, type: type, variadic?: true}}

  defp param(_other), do: :error

  defp return(:void), do: {:ok, %Return{kind: :void, type: "void"}}

  defp return({:scalar, type}) when is_binary(type),
    do: {:ok, %Return{kind: :scalar, type: type}}

  defp return({:setof_scalar, type}) when is_binary(type),
    do: {:ok, %Return{kind: :scalar, set?: true, type: type}}

  defp return({kind, [_ | _] = columns}) when kind in [:composite, :setof] do
    if Enum.all?(columns, &match?({name, type} when is_binary(name) and is_binary(type), &1)),
      do:
        {:ok, %Return{kind: :composite, set?: kind == :setof, type: "record", columns: columns}},
      else: {:error, :columns}
  end

  defp return({kind, resource}) when kind in [:composite, :setof] and is_atom(resource),
    do: {:ok, {:resource, resource, kind == :setof}}

  defp return(_other), do: :error

  defp resolve(%Return{} = return), do: return

  defp resolve({:resource, resource, set?}) do
    unless Options.exports?(resource, :__pgrest_config__, 0),
      do:
        raise(
          ArgumentError,
          "PgRest.Function :returns names #{inspect(resource)}, which is not a PgRest.Resource"
        )

    %{schema: schema, table: table} = resource.__pgrest_config__()
    %Return{kind: :composite, set?: set?, type: "#{schema}.#{table}", resource: resource}
  end
end
