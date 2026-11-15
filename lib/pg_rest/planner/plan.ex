defmodule PgRest.Plan do
  @moduledoc """
  The resolved plan of a read: a tree of `PgRest.Plan.Read` nodes joined by
  `PgRest.Plan.Embed`. Built by `PgRest.Planner`, compiled by `PgRest.SQL.Read`.
  """

  defmodule Read do
    alias PgRest.Authorization.State
    alias PgRest.SQL.ScopedSource
    alias PgRest.Write

    @moduledoc """
    One node of a read plan (the root, or the target of an embed).

    `select` entries are `%{key:, field:, json_path:, cast:}`: `key` is the JSON output
    name, `field` the Ecto field name the scoped source exposes. An aggregate entry is
    `%{key:, aggregate:, legacy:}`, its `PgRest.AST.Aggregate` holding the Ecto field name and
    `key` as alias; `legacy` marks the backwards-compatible bare `count`, which PostgREST does
    not treat as an aggregate (it never groups). `aggregates?` is true when the node or a
    to-one spread below it selects a (non-legacy) aggregate: the node then groups by its other
    output (`SQL.Aggregate.group_by/1`, internal), and a to-one spread hoists its aggregates into
    the parent. `where` holds filters
    and logic trees whose field names are Ecto field names, plus `{:null_embed,
    output_name, null?}` leaves for `embed=is.null` filters. `order` is a list of
    `PgRest.AST.OrderTerm` whose names were validated (`relation:` names an embed
    output). `limit` and `offset` are the request's window for this node; `max_limit`
    clamps it. `output.media` is the `PgRest.MediaType` the root is answered in (JSON until
    `put_media/2`). `column_types` and `categories` are keyed by Ecto field name.

    `source` is `:resource` (the node reads its resource's scoped source) or `{:call,
    PgRest.Plan.Call.t()}` for the root of an RPC, which reads the function call instead
    (`PgRest.SQL.Call`). An RPC returning a scalar, a void or a composite
    that is no registered resource has `resource: nil`.
    """
    defstruct [
      :resource,
      :alias,
      :where,
      :limit,
      :count,
      :source_query,
      authorization_state: State.empty(),
      allowed_columns: :all,
      hook_limit: nil,
      aggregates_allowed?: true,
      count_allowed?: true,
      select: [],
      order: [],
      offset: 0,
      max_limit: nil,
      embeds: [],
      custom_params: [],
      column_types: %{},
      categories: %{},
      source: :resource,
      aggregates?: false,
      output: %{media: PgRest.MediaType.json()}
    ]

    @type select_entry ::
            %{
              key: String.t(),
              field: String.t(),
              json_path: [PgRest.AST.Field.json_step()],
              cast: String.t() | nil
            }
            | %{key: String.t(), aggregate: PgRest.AST.Aggregate.t(), legacy: boolean()}

    @type t :: %__MODULE__{
            authorization_state: State.t(),
            resource: module() | nil,
            source: :resource | {:call, PgRest.Plan.Call.t()},
            alias: String.t(),
            select: [select_entry()],
            where: PgRest.AST.Logic.t() | nil,
            order: [PgRest.AST.OrderTerm.t()],
            limit: non_neg_integer() | nil,
            offset: non_neg_integer(),
            max_limit: pos_integer() | nil,
            embeds: [PgRest.Plan.Embed.t()],
            count: :exact | :planned | :estimated | nil,
            custom_params: [{String.t(), String.t()}],
            source_query: Ecto.Query.t() | nil,
            allowed_columns: :all | MapSet.t(String.t()),
            hook_limit: pos_integer() | nil,
            aggregates_allowed?: boolean(),
            count_allowed?: boolean(),
            column_types: %{String.t() => String.t()},
            categories: %{String.t() => String.t()},
            aggregates?: boolean(),
            output: %{media: PgRest.MediaType.t()}
          }

    @doc """
    Whether a select entry is an aggregate PostgREST treats as one (it groups, needs
    `aggregates: true` and is hoisted out of a to-one spread): not the legacy bare `count`.
    """
    @spec aggregate?(select_entry()) :: boolean()
    def aggregate?(%{aggregate: _, legacy: false}), do: true
    def aggregate?(_entry), do: false

    @doc "Whether a select entry computes an aggregate, the legacy bare `count` included."
    @spec aggregate_entry?(select_entry()) :: boolean()
    def aggregate_entry?(%{aggregate: _}), do: true
    def aggregate_entry?(_entry), do: false

    @doc """
    The plan with the media type its root is answered in (`output.media`): the negotiated
    type's `PgRest.MediaType.body/1`, so a plan type stores the type it explains.
    """
    @spec put_media(t(), PgRest.MediaType.t()) :: t()
    def put_media(%__MODULE__{} = plan, %PgRest.MediaType{} = media),
      do: %{plan | output: %{plan.output | media: PgRest.MediaType.body(media)}}

    @doc """
    The `{resource module, scoped source query}` of every node of the plan, root first, an embed's
    many-to-many junction before its target: the one walk over a plan's resources.
    """
    @spec sources(t()) :: [{module(), Ecto.Query.t() | nil}]
    def sources(plan),
      do:
        for(
          {resource, _path, query} <- authorization_nodes(plan),
          is_atom(resource),
          do: {resource, query}
        )

    @doc """
    What a response about this plan touches, for `:explain`: its resource modules
    (`sources/1`) and the `PgRest.Function` of an RPC root.
    """
    @spec targets(t()) :: [module() | PgRest.Function.t()]
    def targets(%__MODULE__{source: source} = plan) do
      function = for {:call, %{function: function}} <- [source], do: function
      Enum.uniq(function ++ Enum.map(sources(plan), &elem(&1, 0)))
    end

    @doc "Internal targets, node paths and precomputed queries, without callback context."
    @spec authorization_nodes(t()) :: [State.authorization_node()]
    def authorization_nodes(plan) do
      function = for {:call, %{function: f}} <- [plan.source], do: {f, [], nil}
      function ++ read_nodes(plan, [])
    end

    defp read_nodes(plan, path),
      do: own_node(plan, path) ++ Enum.flat_map(plan.embeds, &embed_nodes(&1, path))

    defp own_node(%{resource: nil}, _path), do: []
    defp own_node(plan, path), do: [{plan.resource, path, plan.source_query}]

    defp embed_nodes(embed, parent) do
      path = parent ++ [embed.output_name]
      junction_nodes(embed, path) ++ read_nodes(embed.plan, path)
    end

    defp junction_nodes(%{relationship: %{junction: nil}}, _path), do: []

    defp junction_nodes(%{relationship: %{junction: %{module: module}}} = embed, path),
      do: [{module, junction_path(path, module), embed.junction_source_query}]

    @doc "The shared authorization path of a many-to-many junction."
    @spec junction_path([String.t()], module()) :: [String.t()]
    def junction_path(path, module), do: path ++ [module.__pgrest_config__().table]

    @doc "The shared per-operation policy key of a junction."
    @spec junction_key([String.t()]) :: {{:junction, [String.t()]}, :read}
    def junction_key(path), do: {{:junction, path}, :read}

    @doc "Whether any effective source or column policy requires constraint detail scrubbing."
    @spec scrub_details?(t()) :: boolean()
    def scrub_details?(plan) do
      own = restricted?(plan.resource, plan.source_query, plan.allowed_columns)

      own or
        Enum.any?(plan.embeds, fn embed ->
          junction = embed.junction_policy

          scrub_details?(embed.plan) or
            (junction != nil and restricted?(junction.resource, junction.query, junction.columns))
        end)
    end

    defp restricted?(nil, _query, _columns), do: false

    defp restricted?(resource, query, columns) do
      scoped? = query != nil and not ScopedSource.identity_scope?(resource, query)
      Write.scrub_details?(resource.__pgrest_config__(), scoped? or columns != :all)
    end

    @doc "Whether the node or any embed below it has an `after_load/2` resource."
    @spec after_load?(t()) :: boolean()
    def after_load?(%__MODULE__{resource: nil}), do: false

    def after_load?(%__MODULE__{resource: resource, embeds: embeds}),
      do: resource.__pgrest_config__().after_load or Enum.any?(embeds, &after_load?(&1.plan))
  end

  defmodule Call do
    @moduledoc """
    The function call an RPC read plan reads from (`PgRest.Plan.Read` `source: {:call, call}`),
    compiled by `PgRest.SQL.Call`.

    `args` is how the arguments reach the function:

      * `{:direct, %{name => value | [value]}}` - GET/HEAD query parameters; a variadic
        parameter collects its repeated values in order, any other keeps the last
      * `{:json, body, keys}` - a POST body (the raw JSON text) for a function with named
        parameters; `keys` are the argument names the request supplies
      * `{:single, body}` - a POST body passed whole to the single unnamed `json`/`jsonb`
        parameter

    `read_only?` is true for GET/HEAD and for a POST to a stable or immutable function: the
    transaction then runs read-only. `scope` is `{resource, scoped_query}` when the result rows
    must be checked against the stored, in-scope rows (`result_scope: :stored_rows` on a scoped
    resource), else `nil`.
    """
    @enforce_keys [:function, :args, :read_only?]
    defstruct [:function, :args, :read_only?, scope: nil]

    @type args ::
            {:direct, %{String.t() => String.t() | [String.t()]}}
            | {:json, binary(), [String.t()]}
            | {:single, binary()}

    @type t :: %__MODULE__{
            function: PgRest.Function.t(),
            args: args(),
            read_only?: boolean(),
            scope: {module(), Ecto.Query.t()} | nil
          }
  end

  defmodule Embed do
    @moduledoc """
    An embedded resource: the relationship from the parent, the JSON output name and the
    plan of the target. `join_conditions` are the equalities that tie the target to its parent,
    resolved by the planner as `{left_alias, left_field, right_alias, right_field}` over the
    exposed (Ecto field) column names. `agg_alias` (`"pgrst_e<n>"`, numbered per statement so
    it never exceeds 63 bytes) names the lateral that holds the embed's rows, and
    `junction_alias` and `junction_source_query` the junction of a many-to-many embed.

    A spread whose target subtree has an `after_load/2` resource is planned with
    `merge: true` and `spread: false`: SQL renders it as a plain embed under its `merge_key`
    (`"...m<n>"`, generated, never a request name), and `PgRest.Responder` runs `after_load/2` on its rows before merging the columns into
    the parent (to-one) or into per-column arrays (to-many).
    """

    alias PgRest.SchemaGraph.Relationship

    @enforce_keys [:relationship, :output_name, :plan]
    defstruct [
      :relationship,
      :output_name,
      :plan,
      :agg_alias,
      :merge_key,
      :junction_alias,
      :junction_source_query,
      junction_policy: nil,
      join: :left,
      spread: false,
      merge: false,
      join_conditions: []
    ]

    @type t :: %__MODULE__{
            relationship: PgRest.SchemaGraph.Relationship.t(),
            output_name: String.t(),
            join: :left | :inner,
            spread: boolean(),
            merge: boolean(),
            plan: PgRest.Plan.Read.t(),
            join_conditions: [{String.t(), String.t(), String.t(), String.t()}],
            agg_alias: String.t() | nil,
            merge_key: String.t() | nil,
            junction_alias: String.t() | nil,
            junction_policy: map() | nil,
            junction_source_query: Ecto.Query.t() | nil
          }

    @doc "Whether the embed yields one object (`m2o`, `o2o`) rather than an array."
    @spec to_one?(t()) :: boolean()
    def to_one?(%__MODULE__{relationship: relationship}),
      do: Relationship.to_one?(relationship)
  end
end
