defmodule PgRest.Test.WriteResources do
  @moduledoc false
  # Resources for the write tests, over the compat fixture. Several share the `accounts`
  # table, so a test registers only the ones it needs.

  defmodule Counting do
    @moduledoc false
    # A custom `changeset/3`: reports each call to the test process. `sep` is the
    # `field-with_sep` column (DB default 1) with a struct default of 0; the cast does not
    # force changes, so a supplied 0 is dropped from `changeset.changes` (and not written).
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:sep, :integer, source: :"field-with_sep", default: 0)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, context) do
      if pid = context[:report_to], do: send(pid, {:changeset, context[:operation]})

      struct
      |> Ecto.Changeset.cast(attrs, [:id, :name, :sep])
      |> Ecto.Changeset.validate_required([:id])
      |> Ecto.Changeset.validate_length(:name, max: 20)
    end
  end

  defmodule Generating do
    @moduledoc false
    # The changeset adds a change the payload did not supply.
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      struct
      |> Ecto.Changeset.cast(attrs, [:id])
      |> Ecto.Changeset.put_change(:name, "generated")
    end
  end

  defmodule ScopedAccounts do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "accounts" do
      field(:email, :string)
      field(:hashed_password, :string, redact: true)
      field(:role, :string)
      field(:owner_id, :string)
    end

    @impl PgRest.Resource
    def scope(query, _context), do: where(query, [a], a.owner_id == "owner-1")
  end

  defmodule PlainAccounts do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "accounts" do
      field(:email, :string)
      field(:role, :string)
      field(:owner_id, :string)
    end
  end

  defmodule GeneratedSecret do
    @moduledoc false
    # The changeset generates a value for a `redact: true` (so non-writable) persisted field.
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "accounts" do
      field(:email, :string)
      field(:hashed_password, :string, redact: true)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      struct
      |> Ecto.Changeset.cast(attrs, [:id, :email])
      |> Ecto.Changeset.put_change(:hashed_password, "generated")
    end
  end

  defmodule NullKey do
    @moduledoc false
    # A declared key over nullable columns (as a PostgREST view's inferred key can be).
    use Ecto.Schema
    use PgRest.Resource

    @primary_key false
    @schema_prefix "test"
    schema "no_pk" do
      field(:a, :string, primary_key: true)
      field(:b, :string, primary_key: true)
    end
  end

  defmodule EmailOnly do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, writable: [:email]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "accounts" do
      field(:email, :string)
      field(:role, :string)
    end
  end

  defmodule CreateOnly do
    @moduledoc false
    # Allows `:create` and denies `:read` on `items`.
    def authorize(_conn, PgRest.Compat.Resources.Items, :read, _context), do: {:error, "no"}
    def authorize(_conn, _resource, _operation, _context), do: :ok
  end
end

defmodule PgRest.Test.WriteResources.More do
  @moduledoc false

  defmodule RenamedKey do
    @moduledoc false
    # A scoped resource whose primary key field differs from its source column.
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:account_id, :integer, autogenerate: false, source: :id}
    @schema_prefix "test"
    schema "accounts" do
      field(:email, :string)
      field(:owner_id, :string)
    end

    @impl PgRest.Resource
    def scope(query, _context), do: where(query, [a], a.owner_id == "owner-1")
  end

  defmodule Uuided do
    @moduledoc false
    # A custom changeset over a uuid field: the dump must be JSON-safe.
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, Ecto.UUID)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context), do: Ecto.Changeset.cast(struct, attrs, [:id, :name])
  end

  defmodule Bytes do
    @moduledoc false
    # A custom changeset over a binary field that decodes base64 payload values.
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:data, :binary)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      attrs = Map.update(attrs, "data", nil, &Base.decode64!/1)
      Ecto.Changeset.cast(struct, attrs, [:id, :data])
    end
  end

  defmodule ByteLists do
    @moduledoc false
    # A custom changeset over a `{:array, :binary}` field that decodes base64 elements.
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:data, {:array, :binary})
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      attrs = Map.update(attrs, "data", nil, fn list -> Enum.map(list, &Base.decode64!/1) end)
      Ecto.Changeset.cast(struct, attrs, [:id, :data])
    end
  end

  defmodule SClients do
    @moduledoc false
    # Scoped pair over clients/projects, for upserts whose representation embeds.
    use Ecto.Schema
    use PgRest.Resource, relationships: [projects: [constraint: "client"]]
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
      has_many(:projects, PgRest.Test.WriteResources.More.SProjects, foreign_key: :client_id)
    end

    @impl PgRest.Resource
    def scope(query, _context), do: where(query, [c], c.id < 1000)
  end

  defmodule SProjects do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, relationships: [client: [constraint: "client"]]
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      belongs_to(:client, PgRest.Test.WriteResources.More.SClients, type: :integer)
    end

    @impl PgRest.Resource
    def scope(query, _context), do: where(query, [p], p.id < 1000)
  end

  defmodule ScopedCompound do
    @moduledoc false
    # A composite primary key resource, scoped on `extra`.
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key false
    @schema_prefix "test"
    schema "compound_pk" do
      field(:k1, :integer, primary_key: true)
      field(:k2, :string, primary_key: true)
      field(:extra, :integer)
    end

    @impl PgRest.Resource
    def scope(query, _context), do: where(query, [c], c.extra == 1)
  end

  defmodule UniqueKeyed do
    @moduledoc false
    # No primary key: rows are identified by the `unique_key`.
    use Ecto.Schema
    use PgRest.Resource, unique_key: [:email]
    import Ecto.Query

    @primary_key false
    @schema_prefix "test"
    schema "accounts" do
      field(:id, :integer)
      field(:email, :string)
      field(:role, :string)
      field(:owner_id, :string)
    end

    @impl PgRest.Resource
    def scope(query, _context), do: where(query, [a], a.owner_id == "owner-1")
  end

  defmodule Conditional do
    @moduledoc false
    # The changeset generates a change for some rows only.
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, context) do
      if pid = context[:report_to], do: send(pid, {:changeset, context[:operation]})
      changeset = Ecto.Changeset.cast(struct, attrs, [:id])

      if attrs["id"] == 2,
        do: Ecto.Changeset.put_change(changeset, :name, "generated"),
        else: changeset
    end
  end

  defmodule DenyProjects do
    @moduledoc false
    def authorize(_conn, PgRest.Compat.Resources.Projects, :read, _context), do: {:error, "no"}
    def authorize(_conn, _resource, _operation, _context), do: :ok
  end
end

defmodule PgRest.Test.WriteResources.Mutations do
  @moduledoc false
  # Resources and hooks for the PATCH / DELETE tests.

  defmodule RequiredName do
    @moduledoc false
    # `validate_required` over fields a partial update does not supply.
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, context) do
      if pid = context[:report_to], do: send(pid, {:changeset, context[:operation]})

      struct
      |> Ecto.Changeset.cast(attrs, [:id, :name])
      |> Ecto.Changeset.validate_required([:id, :name])
    end
  end

  defmodule Literal do
    @moduledoc false
    # Keeps `""` (Ecto's `cast` would turn it into `nil`) and forces changes, so values equal
    # to the struct default (0 for `field-with_sep`, whose database default is 1; `nil`) are
    # written.
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:sep, :integer, source: :"field-with_sep", default: 0)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context),
      do:
        Ecto.Changeset.cast(struct, attrs, [:id, :name, :sep],
          empty_values: [],
          force_changes: true
        )
  end

  defmodule Subset do
    @moduledoc false
    # Casts `id` and `name` only; `sep` (database default 1, struct default 0) is never cast.
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:sep, :integer, source: :"field-with_sep", default: 0)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context),
      do: Ecto.Changeset.cast(struct, attrs, [:id, :name])
  end

  defmodule Stamping do
    @moduledoc false
    # The changeset adds a change the payload did not supply (like `updated_at`).
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :id, autogenerate: true}
    @schema_prefix "test"
    schema "defaults_demo" do
      field(:label, :string)
      field(:note, :string)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      struct
      |> Ecto.Changeset.cast(attrs, [:label])
      |> Ecto.Changeset.put_change(:note, "stamped")
    end
  end

  defmodule ReadDenied do
    @moduledoc false
    # Allows every write on `accounts` and denies `:read` on it.
    def authorize(_conn, PgRest.Test.WriteResources.PlainAccounts, :read, _context),
      do: {:error, "no"}

    def authorize(_conn, _resource, _operation, _context), do: :ok
  end

  defmodule Recording do
    @moduledoc false
    # Reports every authorization question to the test process in the context.
    def authorize(_conn, resource, operation, context) do
      if pid = context[:report_to], do: send(pid, {:authorize, resource, operation})
      :ok
    end
  end
end

defmodule PgRest.Test.WriteResources.Mutations.DenyClientsRead do
  @moduledoc false
  def authorize(_conn, PgRest.Test.WriteResources.Mutations.RequiredName, :read, _context),
    do: {:error, "no"}

  def authorize(_conn, _resource, _operation, _context), do: :ok
end

defmodule PgRest.Test.WriteResources.Changesets do
  @moduledoc false
  # Custom changesets whose final changes are the write intent (one run per row). All over
  # `complex_items`, whose `field-with_sep` (`sep`) has database default 1.

  defmodule Settings do
    @moduledoc false
    use Ecto.Schema
    @primary_key false
    embedded_schema do
      field(:a, :string)
    end

    def changeset(struct, attrs), do: Ecto.Changeset.cast(struct, attrs, [:a])
  end

  defmodule Embed do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      embeds_one(:settings, PgRest.Test.WriteResources.Changesets.Settings, on_replace: :update)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      struct |> Ecto.Changeset.cast(attrs, [:id, :name]) |> Ecto.Changeset.cast_embed(:settings)
    end
  end

  defmodule Required do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:tags, {:array, :string})
    end

    # `tags` is never cast: supplying it must not satisfy validate_required.
    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      struct
      |> Ecto.Changeset.cast(attrs, [:id, :name])
      |> Ecto.Changeset.validate_required([:name, :tags])
    end
  end

  defmodule Bypass do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:sep, :integer, source: :"field-with_sep", default: 0)
    end

    # `sep` is never cast; a default-level row must have a short name.
    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      changeset = Ecto.Changeset.cast(struct, attrs, [:id, :name])

      if Ecto.Changeset.get_field(changeset, :sep) == 0,
        do: Ecto.Changeset.validate_length(changeset, :name, max: 3),
        else: changeset
    end
  end

  defmodule Leak do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:sep, :integer, source: :"field-with_sep", default: 0)
    end

    # Generates `sep` from the struct it is given.
    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      struct
      |> Ecto.Changeset.cast(attrs, [:id])
      |> Ecto.Changeset.put_change(:sep, struct.sep + 1)
    end
  end

  defmodule Copy do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:sep, :integer, source: :"field-with_sep", default: 0)
    end

    # Interpolates a struct field into a generated change.
    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      struct
      |> Ecto.Changeset.cast(attrs, [:id])
      |> Ecto.Changeset.put_change(:name, "sep=#{inspect(struct.sep)}")
    end
  end

  defmodule Match do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
    end

    # Matches the pristine struct in its head.
    @impl PgRest.Resource
    def changeset(%__MODULE__{name: nil} = struct, attrs, _context),
      do: Ecto.Changeset.cast(struct, attrs, [:id, :name])
  end

  defmodule Fresh do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:sep, :integer, source: :"field-with_sep", default: 0)
    end

    # Ignores the struct it is given (and does not force changes).
    @impl PgRest.Resource
    def changeset(_struct, attrs, _context),
      do: Ecto.Changeset.cast(%__MODULE__{}, attrs, [:id, :name, :sep])
  end

  # Branches on a struct field: `struct(resource)` has `tags: nil`, so `sep` is never cast.
  defmodule Branch do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:tags, {:array, :string})
      field(:sep, :integer, source: :"field-with_sep", default: 0)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      fields = if struct.tags, do: [:id, :name, :sep], else: [:id, :name]
      Ecto.Changeset.cast(struct, attrs, fields)
    end
  end

  # The new-vs-existing branch: `struct(resource)` has `id: nil`, so every key is cast.
  defmodule NewOrOld do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:sep, :integer, source: :"field-with_sep", default: 0)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      fields = if struct.id, do: [:name], else: [:id, :name, :sep]
      Ecto.Changeset.cast(struct, attrs, fields)
    end
  end

  # Generates `tags` from the struct's `name`; `sep` is never cast.
  defmodule Raise do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:tags, {:array, :string})
      field(:sep, :integer, source: :"field-with_sep", default: 0)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      struct
      |> Ecto.Changeset.cast(attrs, [:id, :name])
      |> Ecto.Changeset.put_change(:tags, [String.downcase(struct.name || "none")])
    end
  end

  # An embed the changeset never casts.
  defmodule EmbedUncast do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      embeds_one(:settings, PgRest.Test.WriteResources.Changesets.Settings, on_replace: :update)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context), do: Ecto.Changeset.cast(struct, attrs, [:id, :name])
  end

  defmodule EmbedMany do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      embeds_many(:settings, PgRest.Test.WriteResources.Changesets.Settings, on_replace: :delete)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      struct |> Ecto.Changeset.cast(attrs, [:id, :name]) |> Ecto.Changeset.cast_embed(:settings)
    end
  end

  # Forces changes: values equal to the struct default (`nil`, `0`, `""` through
  # `empty_values`, `[]`) are changes, written and validated. A cross-field validation sees
  # both forced changes.
  defmodule Forced do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:tags, {:array, :string}, default: [])
      field(:sep, :integer, source: :"field-with_sep", default: 0)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      struct
      |> Ecto.Changeset.cast(attrs, [:id, :name, :tags, :sep], force_changes: true)
      |> Ecto.Changeset.validate_number(:sep, less_than: 100)
      |> validate_not_both_cleared()
    end

    defp validate_not_both_cleared(changeset) do
      if Ecto.Changeset.fetch_change(changeset, :name) == {:ok, nil} and
           Ecto.Changeset.fetch_change(changeset, :tags) == {:ok, []},
         do: Ecto.Changeset.add_error(changeset, :name, "cannot be cleared with tags"),
         else: changeset
    end
  end

  # `sep` must be positive. With `force_changes: true` a supplied 0 is validated (400);
  # without it, 0 equals the struct default, is not a change and is not written.
  defmodule Positive do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      field(:sep, :integer, source: :"field-with_sep", default: 0)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, context) do
      struct
      |> Ecto.Changeset.cast(attrs, [:id, :name, :sep], force_changes: context[:force?] == true)
      |> Ecto.Changeset.validate_number(:sep, greater_than: 0)
    end
  end

  # An embed with `on_replace: :raise`: one changeset run never replaces an embed.
  defmodule EmbedRaise do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string)
      embeds_one(:settings, PgRest.Test.WriteResources.Changesets.Settings, on_replace: :raise)
    end

    @impl PgRest.Resource
    def changeset(struct, attrs, _context) do
      struct |> Ecto.Changeset.cast(attrs, [:id, :name]) |> Ecto.Changeset.cast_embed(:settings)
    end
  end

  # A default changeset over every Ecto primitive the ruling names (never registered: it is
  # only called directly, so its table does not matter).
  defmodule Defaults do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    @primary_key {:id, :id, autogenerate: false}
    @schema_prefix "test"
    schema "complex_items" do
      field(:name, :string, default: "")
      field(:active, :boolean, default: false)
      field(:count, :integer, default: 0)
      field(:note, :string)
      field(:tags, {:array, :string}, default: [])
    end
  end
end
