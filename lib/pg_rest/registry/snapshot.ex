defmodule PgRest.Registry.Snapshot do
  @moduledoc """
  The immutable schema cache a `PgRest.Registry` publishes: its resources keyed by
  `{schema, table}`, the exposed schemas (the first is the default) and the relationship
  graph.

  `graph` spans every schema. Embedding follows PostgREST and only reaches tables in the
  request's schema, so requests resolve embeds through `graph/2`, the graph restricted to one
  schema (precomputed per exposed schema).

  `functions` maps `{schema, name}` to its overloads (`PgRest.Function`), declared or
  introspected. `introspection` is `nil` without `introspect:`, otherwise what `PgRest.Plug`
  cross-checks on every request: `%{mode: :app | :rls, as_role: [String.t()] | nil,
  authorization: module() | nil, filtered?: boolean()}` (`filtered?` when `only:` or `except:`
  was given).

  `generation` is unique per built snapshot, so a reload is a new generation.

  `scrub_rpc_details?` is whether any resource is scoped or restricts columns
  (`PgRest.Write.scrub_details?/2`): a function may touch any table, so its database errors
  then lose their details.
  """

  alias PgRest.{Error, Function, SchemaGraph, Write}
  alias PgRest.SchemaGraph.Fuzzy

  # PostgREST's maxDbTablesForFuzzySearch: no table hint in a schema this large.
  @max_fuzzy_tables 500

  @enforce_keys [
    :name,
    :generation,
    :schemas,
    :default_schema,
    :resources,
    :by_module,
    :graph,
    :graphs
  ]
  defstruct [
    :name,
    :generation,
    :schemas,
    :default_schema,
    :resources,
    :by_module,
    :graph,
    :graphs,
    functions: %{},
    introspection: nil,
    scrub_rpc_details?: false
  ]

  @type t :: %__MODULE__{
          name: atom(),
          generation: pos_integer(),
          schemas: [String.t()],
          default_schema: String.t(),
          resources: %{{String.t(), String.t()} => map()},
          by_module: %{module() => map()},
          graph: SchemaGraph.t(),
          graphs: %{String.t() => SchemaGraph.t()},
          functions: %{{String.t(), String.t()} => [Function.t()]},
          introspection: introspection() | nil,
          scrub_rpc_details?: boolean()
        }

  @type introspection :: %{
          mode: :app | :rls,
          as_role: [String.t()] | nil,
          authorization: module() | nil,
          filtered?: boolean()
        }

  @doc """
  Builds the snapshot of `configs` (resource configs, already validated) exposing `schemas`.
  `opts` may carry `functions:` (a list of `PgRest.Function`, grouped here by schema and name)
  and `introspection:`.
  """
  @spec build(atom(), [String.t()], [map()], keyword()) :: t()
  def build(name, [default | _] = schemas, configs, opts \\ []) do
    graph = configs |> Enum.map(& &1.module) |> SchemaGraph.build()

    %__MODULE__{
      name: name,
      generation: System.unique_integer([:positive, :monotonic]),
      schemas: schemas,
      default_schema: default,
      resources: Map.new(configs, &{{&1.schema, &1.table}, &1}),
      by_module: Map.new(configs, &{&1.module, &1}),
      graph: graph,
      graphs: Map.new(schemas, &{&1, SchemaGraph.restrict(graph, &1)}),
      functions: opts |> Keyword.get(:functions, []) |> Enum.group_by(&{&1.schema, &1.name}),
      introspection: Keyword.get(opts, :introspection),
      scrub_rpc_details?: Enum.any?(configs, &Write.scrub_details?(&1, &1.custom_scope?))
    }
  end

  @doc """
  The resource registered for `schema.table`, or PostgREST's 404 `PGRST205`, with a
  "Perhaps you meant" hint naming the closest table of that schema.
  """
  @spec fetch_resource(t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  def fetch_resource(%__MODULE__{resources: resources} = snap, schema, table) do
    case Map.fetch(resources, {schema, table}) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, table_not_found(snap, schema, table)}
    end
  end

  @doc "The relationship graph a request against `schema` embeds through."
  @spec graph(t(), String.t()) :: SchemaGraph.t()
  def graph(%__MODULE__{graphs: graphs}, schema), do: Map.fetch!(graphs, schema)

  @doc "The overloads of function `schema.name` (empty when none is registered)."
  @spec functions(t(), String.t(), String.t()) :: [Function.t()]
  def functions(%__MODULE__{functions: functions}, schema, name),
    do: Map.get(functions, {schema, name}, [])

  @doc "Every function registered in `schema` (the candidates of an RPC name hint)."
  @spec schema_functions(t(), String.t()) :: [Function.t()]
  def schema_functions(%__MODULE__{functions: functions}, schema) do
    for {{^schema, _name}, overloads} <- functions, function <- overloads, do: function
  end

  defp table_not_found(snap, schema, table) do
    names = for {{^schema, name}, _config} <- snap.resources, do: name

    # PostgREST only suggests a table scoring at least 0.75, and not at all in a schema with
    # @max_fuzzy_tables or more (`maxDbTablesForFuzzySearch`).
    hint =
      if length(names) < @max_fuzzy_tables,
        do: Fuzzy.hint(names, table, 0.75, &"Perhaps you meant the table '#{schema}.#{&1}'")

    Error.table_not_found(schema, table, hint)
  end
end
