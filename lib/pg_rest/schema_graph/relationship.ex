defmodule PgRest.SchemaGraph.Relationship do
  @moduledoc """
  One directed relationship between two registered resources, shaped like
  PostgREST's schema-cache relationships.

  Columns are database column names, in constraint order. `source_columns[i]`
  pairs with `target_columns[i]`.

    * `:m2o` - `source` holds the foreign key
    * `:o2m` - `target` holds the foreign key
    * `:o2o` - one-to-one in either direction (the foreign key columns are unique)
    * `:m2m` - through `junction`; `source_columns` / `target_columns` are the key
      columns of the two resources, `junction.source_columns` /
      `junction.target_columns` the junction columns that reference them, and
      `constraint` is the junction table name and `junction.module` the registered resource
      of the junction table

  `assoc` is the Ecto association (or explicit declaration) name on `source`, when
  there is one.
  """

  @type kind :: :m2o | :o2m | :o2o | :m2m

  @type junction :: %{
          module: module(),
          table: String.t(),
          schema: String.t(),
          source_columns: [String.t()],
          target_columns: [String.t()],
          constraints: {String.t(), String.t()}
        }

  @type t :: %__MODULE__{
          kind: kind(),
          source: module(),
          target: module(),
          constraint: String.t(),
          source_columns: [String.t()],
          target_columns: [String.t()],
          junction: junction() | nil,
          assoc: atom() | nil
        }

  @enforce_keys [:kind, :source, :target, :constraint, :source_columns, :target_columns]
  defstruct [:kind, :source, :target, :constraint, :source_columns, :target_columns] ++
              [junction: nil, assoc: nil]

  @doc "Whether the target is one row per source row (`:m2o`, `:o2o`) rather than a set."
  @spec to_one?(t()) :: boolean()
  def to_one?(%__MODULE__{kind: kind}), do: kind in [:m2o, :o2o]
end
