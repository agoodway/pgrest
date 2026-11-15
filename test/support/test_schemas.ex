defmodule PgRest.Test.Order do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource
  import Ecto.Query

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "orders" do
    field(:reference, :string)
    field(:status, :string)
    field(:total, :decimal)
    field(:tenant_id, :integer)
    has_many(:line_items, PgRest.Test.LineItem)
  end

  @impl PgRest.Resource
  def scope(query, %{tenant_id: tid}) do
    where(query, [r], r.tenant_id == ^tid)
  end

  def scope(query, _context), do: query
end

defmodule PgRest.Test.LineItem do
  @moduledoc false
  use Ecto.Schema

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "line_items" do
    field(:name, :string)
    field(:quantity, :integer)
    field(:price, :decimal)
    belongs_to(:order, PgRest.Test.Order)
  end
end

defmodule PgRest.Test.Product do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "products" do
    field(:name, :string)
    field(:price, :decimal)
  end
end

defmodule PgRest.Test.NonResource do
  @moduledoc false
  use Ecto.Schema

  schema "non_resources" do
    field(:name, :string)
  end
end

defmodule PgRest.Test.ReadOnlyProduct do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource, allow: [:read]

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "products" do
    field(:name, :string)
    field(:price, :decimal)
  end
end

defmodule PgRest.Test.NoDeleteOrder do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource, allow: [:read, :create, :update]

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "orders" do
    field(:reference, :string)
    field(:status, :string)
    field(:total, :decimal)
    field(:tenant_id, :integer)
  end
end

# --- Schemas with associations for embedding tests ---

defmodule PgRest.Test.Author do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "authors" do
    field(:first_name, :string)
    field(:last_name, :string)
    has_many(:posts, PgRest.Test.Post)
  end
end

defmodule PgRest.Test.Post do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "posts" do
    field(:title, :string)
    field(:body, :string)
    field(:status, :string)
    belongs_to(:author, PgRest.Test.Author)
    has_many(:comments, PgRest.Test.Comment)
    many_to_many(:tags, PgRest.Test.Tag, join_through: "posts_tags")
  end
end

defmodule PgRest.Test.Comment do
  @moduledoc false
  use Ecto.Schema

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "comments" do
    field(:body, :string)
    field(:status, :string)
    belongs_to(:post, PgRest.Test.Post)
  end
end

defmodule PgRest.Test.Tag do
  @moduledoc false
  use Ecto.Schema

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "tags" do
    field(:name, :string)
    many_to_many(:posts, PgRest.Test.Post, join_through: "posts_tags")
  end
end

# --- Self-referential schema ---

defmodule PgRest.Test.Category do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "categories" do
    field(:name, :string)
    belongs_to(:parent, PgRest.Test.Category)
    has_many(:children, PgRest.Test.Category, foreign_key: :parent_id)
  end
end

# --- Multiple FKs to same table ---

defmodule PgRest.Test.Address do
  @moduledoc false
  use Ecto.Schema

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "addresses" do
    field(:street, :string)
    field(:city, :string)
  end
end

defmodule PgRest.Test.ShippingOrder do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @derive {Jason.Encoder, except: [:__meta__]}
  schema "shipping_orders" do
    field(:reference, :string)
    belongs_to(:billing_address, PgRest.Test.Address)
    belongs_to(:shipping_address, PgRest.Test.Address)
  end
end

defmodule PgRest.ResourceTest.AccountsReadHashed do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource, readable: [:id, :email, :hashed_password]

  @schema_prefix "test"
  schema "accounts" do
    field(:email, :string)
    field(:hashed_password, :string, redact: true)
    field(:role, :string)
  end
end

defmodule PgRest.ResourceTest.AccountsWriteEmail do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource, writable: [:email]

  @schema_prefix "test"
  schema "accounts" do
    field(:email, :string)
    field(:role, :string)
  end
end

defmodule PgRest.ResourceTest.AccountsOwnChangeset do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "test"
  schema "accounts" do
    field(:email, :string)
  end

  @impl PgRest.Resource
  def changeset(struct, attrs, _context), do: Ecto.Changeset.cast(struct, attrs, [:email])
end

defmodule PgRest.ResourceTest.ScopedNoPk do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource, custom_params: ["q"], after_load: true, unique_key: [:name]
  import Ecto.Query

  @primary_key false
  schema "scoped_no_pk" do
    field(:name, :string)
  end

  @impl PgRest.Resource
  def scope(query, _context), do: where(query, [r], not is_nil(r.name))
end

defmodule PgRest.ResourceTest.ScopedNoPkNoKey do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource
  import Ecto.Query

  @primary_key false
  schema "scoped_no_pk_no_key" do
    field(:name, :string)
  end

  @impl PgRest.Resource
  def scope(query, _context), do: where(query, [r], not is_nil(r.name))
end

defmodule PgRest.GraphTest.ExplA do
  @moduledoc false
  use Ecto.Schema

  use PgRest.Resource,
    relationships: [
      bs: [
        kind: :m2m,
        target: PgRest.GraphTest.ExplB,
        junction: [
          table: "expl_j",
          schema: "public",
          source_columns: [{"id", "a_id"}],
          target_columns: [{"b_id", "id"}],
          constraints: {"expl_j_a_id_fkey", "expl_j_b_id_fkey"}
        ]
      ]
    ]

  schema "expl_a" do
    field(:name, :string)
  end
end

defmodule PgRest.GraphTest.ExplB do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  schema "expl_b" do
    field(:name, :string)
  end
end

# Surrogate primary key: not a junction by PostgREST's rule, so only the explicit
# declaration on ExplA makes it one.
defmodule PgRest.GraphTest.ExplJ do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  schema "expl_j" do
    belongs_to(:a, PgRest.GraphTest.ExplA)
    belongs_to(:b, PgRest.GraphTest.ExplB)
  end
end

defmodule PgRest.GraphTest.ExplAUnregisteredTarget do
  @moduledoc false
  use Ecto.Schema

  use PgRest.Resource,
    relationships: [
      other: [
        kind: :m2o,
        target: PgRest.GraphTest.ExplB,
        columns: [{"b_id", "id"}],
        constraint: "expl_au_b_id_fkey"
      ]
    ]

  schema "expl_au" do
    field(:b_id, :integer)
  end
end

defmodule PgRest.GraphTest.ConflParent do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource, relationships: [kids: [constraint: "from_parent"]]

  schema "confl_parent" do
    has_many(:kids, PgRest.GraphTest.ConflKid, foreign_key: :parent_id)
  end
end

defmodule PgRest.GraphTest.ConflKid do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource, relationships: [parent: [constraint: "from_kid"]]

  schema "confl_kid" do
    belongs_to(:parent, PgRest.GraphTest.ConflParent)
  end
end

# Junction with a composite primary key, derivable by PostgREST's rule.
defmodule PgRest.GraphTest.DerivA do
  @moduledoc false
  use Ecto.Schema

  use PgRest.Resource,
    relationships: [
      bs: [
        kind: :m2m,
        target: PgRest.GraphTest.DerivB,
        junction: [
          table: "deriv_j",
          schema: "public",
          source_columns: [{"id", "a_id"}],
          target_columns: [{"b_id", "id"}],
          constraints: {"deriv_j_a_id_fkey", "deriv_j_b_id_fkey"}
        ]
      ]
    ]

  schema "deriv_a" do
    field(:name, :string)
  end
end

defmodule PgRest.GraphTest.DerivB do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  schema "deriv_b" do
    field(:name, :string)
  end
end

defmodule PgRest.GraphTest.DerivJ do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @primary_key false
  schema "deriv_j" do
    belongs_to(:a, PgRest.GraphTest.DerivA, primary_key: true)
    belongs_to(:b, PgRest.GraphTest.DerivB, primary_key: true)
  end
end

# The same explicit m2m declared from both sides.
defmodule PgRest.GraphTest.BothC do
  @moduledoc false
  use Ecto.Schema

  use PgRest.Resource,
    relationships: [
      ds: [
        kind: :m2m,
        target: PgRest.GraphTest.BothD,
        junction: [
          table: "both_j",
          schema: "public",
          source_columns: [{"id", "c_id"}],
          target_columns: [{"d_id", "id"}],
          constraints: {"both_j_c_id_fkey", "both_j_d_id_fkey"}
        ]
      ]
    ]

  schema "both_c" do
    field(:name, :string)
  end
end

defmodule PgRest.GraphTest.BothD do
  @moduledoc false
  use Ecto.Schema

  use PgRest.Resource,
    relationships: [
      cs: [
        kind: :m2m,
        target: PgRest.GraphTest.BothC,
        junction: [
          table: "both_j",
          schema: "public",
          source_columns: [{"id", "d_id"}],
          target_columns: [{"c_id", "id"}],
          constraints: {"both_j_d_id_fkey", "both_j_c_id_fkey"}
        ]
      ]
    ]

  schema "both_d" do
    field(:name, :string)
  end
end

defmodule PgRest.GraphTest.BothJ do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @primary_key false
  schema "both_j" do
    belongs_to(:c, PgRest.GraphTest.BothC, primary_key: true)
    belongs_to(:d, PgRest.GraphTest.BothD, primary_key: true)
  end
end

# Self-referencing junction: two derived m2m relationships share one many_to_many alias key.
defmodule PgRest.GraphTest.SelfA do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  schema "self_a" do
    many_to_many(:friends, PgRest.GraphTest.SelfA,
      join_through: "self_j",
      join_keys: [a_id: :id, b_id: :id]
    )
  end
end

defmodule PgRest.GraphTest.SelfJ do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @primary_key false
  schema "self_j" do
    belongs_to(:a, PgRest.GraphTest.SelfA, primary_key: true)
    belongs_to(:b, PgRest.GraphTest.SelfA, primary_key: true)
  end
end
