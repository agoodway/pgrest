defmodule PgRest.AST do
  @moduledoc """
  Structs produced by the PostgREST grammar parsers (filters, logic trees, select and order).
  """

  defmodule Field do
    @moduledoc """
    A column reference with an optional JSON path, e.g. `data->a->>b` or `arr->0`.
    """
    @enforce_keys [:name]
    defstruct name: nil, json_path: []

    @type json_step :: {:arrow | :double_arrow, String.t() | integer()}
    @type t :: %__MODULE__{name: String.t(), json_path: [json_step()]}
  end

  defmodule Condition do
    @moduledoc """
    A single `field op value` filter.

    `value` is a binary for scalar operators, a list of binaries for `in` and for
    `any`/`all` quantified array literals, one of `:null | :not_null | true | false |
    :unknown` for `is`, and the raw literal (`{1,2}`, `[1,5)`, JSON) for `cs`, `cd`
    and `ov`.
    """
    @enforce_keys [:field, :op]
    defstruct field: nil, op: nil, negate: false, modifier: nil, value: nil, fts_config: nil

    @type op ::
            :eq
            | :neq
            | :gt
            | :gte
            | :lt
            | :lte
            | :like
            | :ilike
            | :match
            | :imatch
            | :in
            | :is
            | :isdistinct
            | :fts
            | :plfts
            | :phfts
            | :wfts
            | :cs
            | :cd
            | :ov
            | :sl
            | :sr
            | :nxr
            | :nxl
            | :adj

    @type value ::
            String.t() | [String.t()] | :null | :not_null | true | false | :unknown

    @type t :: %__MODULE__{
            field: PgRest.AST.Field.t(),
            op: op(),
            negate: boolean(),
            modifier: nil | :any | :all,
            value: value(),
            fts_config: String.t() | nil
          }
  end

  defmodule Logic do
    @moduledoc """
    An `and`/`or` node of a logic tree, optionally negated (`not.and`, `not.or`).
    """
    @enforce_keys [:op]
    defstruct op: nil, negate: false, children: []

    @type t :: %__MODULE__{
            op: :and | :or,
            negate: boolean(),
            children: [PgRest.AST.Condition.t() | t()]
          }
  end

  defmodule SelectField do
    @moduledoc """
    A `select=` column: `alias:field::cast`, or `:star` for `*`.
    """
    @enforce_keys [:field]
    defstruct field: nil, alias: nil, cast: nil

    @type t :: %__MODULE__{
            field: PgRest.AST.Field.t() | :star,
            alias: String.t() | nil,
            cast: String.t() | nil
          }
  end

  defmodule Aggregate do
    @moduledoc """
    A `select=` aggregate: `count()`, `col.sum()`, `alias:col::text.avg()::int`.

    `field` is `nil` for a bare `count()`. `input_cast` is the cast applied to the
    column before aggregating, `cast` the cast applied to the result.
    """
    @enforce_keys [:fun]
    defstruct fun: nil, field: nil, alias: nil, cast: nil, input_cast: nil

    @type fun :: :count | :sum | :avg | :min | :max
    @type t :: %__MODULE__{
            fun: fun(),
            field: PgRest.AST.Field.t() | nil,
            alias: String.t() | nil,
            cast: String.t() | nil,
            input_cast: String.t() | nil
          }
  end

  defmodule Embed do
    @moduledoc """
    A `select=` embedded resource: `alias:rel!hint!inner(...)`, or a spread
    (`...rel(...)`). An empty embed `rel()` has `select: []`.
    """
    @enforce_keys [:name]
    defstruct name: nil, alias: nil, hint: nil, join: :left, spread: false, select: []

    @type item :: PgRest.AST.SelectField.t() | PgRest.AST.Aggregate.t() | t()
    @type t :: %__MODULE__{
            name: String.t(),
            alias: String.t() | nil,
            hint: String.t() | nil,
            join: :left | :inner,
            spread: boolean(),
            select: [item()]
          }
  end

  defmodule OrderTerm do
    @moduledoc """
    One `order=` term: `field.desc.nullsfirst`, or `rel(field).asc` which orders by a
    column of the to-one embed `rel`.
    """
    @enforce_keys [:field]
    defstruct field: nil, relation: nil, dir: :asc, nulls: nil

    @type t :: %__MODULE__{
            field: PgRest.AST.Field.t(),
            relation: String.t() | nil,
            dir: :asc | :desc,
            nulls: :first | :last | nil
          }
  end
end
