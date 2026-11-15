defmodule PgRest.Compat.Supabase.Resources do
  @moduledoc """
  Ecto resource modules for every table in the Supabase-shaped fixture (`public` and
  `personal` in `pgrest_supabase`), plus the views `active_users` and `recent_messages`, which
  RPC functions return. Other views and materialized views are not resources.

  `public.users` is `PgRest.Compat.Supabase.User`; `personal.users` is
  `PgRest.Compat.Supabase.Personal.User`.
  """

  @modules Enum.map(
             ~w(User UserProfile BestFriend Channel ChannelDetail Message UserAudit Collection Lab Product Category ProductCategory Cornercase Event Hotel Booking InferenceCase RlsNote PrivateDoc Personal.User Personal.UserNote ActiveUser RecentMessage)a,
             &Module.concat(PgRest.Compat.Supabase, &1)
           )

  @doc "Every Supabase fixture resource module."
  @spec all() :: [module()]
  def all, do: @modules
end

defmodule PgRest.Compat.Supabase.User do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  alias PgRest.Compat.Resources.Raw

  @primary_key {:username, :string, autogenerate: false}
  @schema_prefix "public"
  schema "users" do
    field(:data, :map)
    field(:age_range, Raw)
    field(:status, :string)
    field(:catchphrase, Raw)
  end
end

defmodule PgRest.Compat.Supabase.UserProfile do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "public"
  schema "user_profiles" do
    belongs_to(:user, PgRest.Compat.Supabase.User,
      foreign_key: :username,
      references: :username,
      type: :string
    )
  end
end

defmodule PgRest.Compat.Supabase.BestFriend do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "public"
  schema "best_friends" do
    belongs_to(:first, PgRest.Compat.Supabase.User,
      foreign_key: :first_user,
      references: :username,
      type: :string
    )

    belongs_to(:second, PgRest.Compat.Supabase.User,
      foreign_key: :second_user,
      references: :username,
      type: :string
    )

    belongs_to(:third, PgRest.Compat.Supabase.User,
      foreign_key: :third_wheel,
      references: :username,
      type: :string
    )
  end
end

defmodule PgRest.Compat.Supabase.Channel do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "public"
  schema "channels" do
    field(:data, :map)
    field(:slug, :string)
  end
end

defmodule PgRest.Compat.Supabase.ChannelDetail do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource, relationships: [channel: [cardinality: :one_to_one]]

  @primary_key {:id, :id, autogenerate: false}
  @schema_prefix "public"
  schema "channel_details" do
    belongs_to(:channel, PgRest.Compat.Supabase.Channel, foreign_key: :id, define_field: false)
    field(:details, :string)
  end
end

defmodule PgRest.Compat.Supabase.Message do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "public"
  schema "messages" do
    field(:data, :map)
    field(:message, :string)

    belongs_to(:user, PgRest.Compat.Supabase.User,
      foreign_key: :username,
      references: :username,
      type: :string
    )

    belongs_to(:channel, PgRest.Compat.Supabase.Channel)
  end
end

defmodule PgRest.Compat.Supabase.UserAudit do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "public"
  schema "users_audit" do
    field(:created_at, :utc_datetime_usec)
    field(:previous_value, :integer)
  end
end

defmodule PgRest.Compat.Supabase.Collection do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "public"
  schema "collections" do
    field(:description, :string)
    belongs_to(:parent, PgRest.Compat.Supabase.Collection)
  end
end

defmodule PgRest.Compat.Supabase.Lab do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "public"
  schema "lab" do
    field(:name, :string)
    field(:type, :string)
    belongs_to(:parent_lab, PgRest.Compat.Supabase.Lab, foreign_key: :parent)
    belongs_to(:main_lab, PgRest.Compat.Supabase.Lab, foreign_key: :main)
  end
end

defmodule PgRest.Compat.Supabase.Product do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "public"
  schema "products" do
    field(:name, :string)
    field(:description, :string)
    field(:price, :decimal)
  end
end

defmodule PgRest.Compat.Supabase.Category do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "public"
  schema "categories" do
    field(:name, :string)
    field(:description, :string)
  end
end

defmodule PgRest.Compat.Supabase.ProductCategory do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @primary_key false
  @schema_prefix "public"
  schema "product_categories" do
    belongs_to(:product, PgRest.Compat.Supabase.Product, primary_key: true)
    belongs_to(:category, PgRest.Compat.Supabase.Category, primary_key: true)
  end
end

defmodule PgRest.Compat.Supabase.Cornercase do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @primary_key {:id, :integer, autogenerate: false}
  @schema_prefix "public"
  schema "cornercase" do
    field(:"column whitespace", :string)
    field(:array_column, {:array, :string})
  end
end

defmodule PgRest.Compat.Supabase.Event do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @primary_key false
  @schema_prefix "public"
  schema "events" do
    field(:id, :id, primary_key: true)
    field(:created_at, :utc_datetime_usec, primary_key: true)
    field(:event_type, :string)
    field(:data, :map)
  end
end

defmodule PgRest.Compat.Supabase.Hotel do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "public"
  schema "hotel" do
    field(:name, :string)
  end
end

defmodule PgRest.Compat.Supabase.Booking do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "public"
  schema "booking" do
    belongs_to(:hotel, PgRest.Compat.Supabase.Hotel)
  end
end

defmodule PgRest.Compat.Supabase.InferenceCase do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  alias PgRest.Compat.Resources.Raw

  @schema_prefix "public"
  schema "inference_cases" do
    field(:sequence_id, :id)
    field(:price, :decimal)
    field(:quantity, :integer)
    field(:total, :decimal)
    field(:note, :string)
    field(:required_payload, :map)
    field(:optional_payload, :map)
    field(:tags, {:array, :string})
    field(:scores, {:array, :integer})
    field(:shipping_address, Raw)
    field(:status, :string)
  end
end

defmodule PgRest.Compat.Supabase.RlsNote do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "public"
  schema "rls_notes" do
    field(:owner, :string)
    field(:body, :string)
    field(:slug, :string)
  end
end

defmodule PgRest.Compat.Supabase.PrivateDoc do
  # `anon` has no grant on `private_docs`; `allow:` is that missing grant.
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource, allow: [:create]

  @primary_key {:id, :integer, autogenerate: false}
  @schema_prefix "public"
  schema "private_docs" do
    field(:body, :string)
  end
end

defmodule PgRest.Compat.Supabase.Personal.User do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  alias PgRest.Compat.Resources.Raw

  @primary_key {:username, :string, autogenerate: false}
  @schema_prefix "personal"
  schema "users" do
    field(:data, :map)
    field(:age_range, Raw)
    field(:status, :string)
  end
end

defmodule PgRest.Compat.Supabase.Personal.UserNote do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "personal"
  schema "user_notes" do
    # Cross-schema foreign key: personal.user_notes.author -> public.users.username.
    belongs_to(:author_user, PgRest.Compat.Supabase.User,
      foreign_key: :author,
      references: :username,
      type: :string
    )

    belongs_to(:personal_author_user, PgRest.Compat.Supabase.Personal.User,
      foreign_key: :personal_author,
      references: :username,
      type: :string
    )

    field(:note, :string)
  end
end

defmodule PgRest.Compat.Supabase.ActiveUser do
  @moduledoc false
  # The `public.active_users` view (`users` with status ONLINE).
  use Ecto.Schema
  use PgRest.Resource

  alias PgRest.Compat.Resources.Raw

  @primary_key {:username, :string, autogenerate: false}
  @schema_prefix "public"
  schema "active_users" do
    field(:data, :map)
    field(:age_range, Raw)
    field(:status, :string)
    field(:catchphrase, Raw)
  end
end

defmodule PgRest.Compat.Supabase.RecentMessage do
  @moduledoc false
  # The `public.recent_messages` view (the last 100 `messages`).
  use Ecto.Schema
  use PgRest.Resource

  @schema_prefix "public"
  schema "recent_messages" do
    field(:data, :map)
    field(:message, :string)

    belongs_to(:user, PgRest.Compat.Supabase.User,
      foreign_key: :username,
      references: :username,
      type: :string
    )

    belongs_to(:channel, PgRest.Compat.Supabase.Channel)
  end
end
