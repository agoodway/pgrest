defmodule PgRest.Test.PlugResources do
  @moduledoc false
  # `after_load: true` resources over the compat fixture, for the plug read tests.

  defmodule Clients do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, after_load: true

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
      has_many(:projects, PgRest.Test.PlugResources.Projects, foreign_key: :client_id)
    end

    @impl PgRest.Resource
    def after_load(row, context),
      do: Map.merge(row, %{"loaded" => true, "tenant" => context[:tenant]})
  end

  defmodule Projects do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, after_load: true

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      belongs_to(:client, PgRest.Test.PlugResources.Clients, type: :integer)
    end

    @impl PgRest.Resource
    def after_load(row, _context), do: Map.put(row, "project_loaded", true)
  end

  defmodule TrimClients do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, after_load: true

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
      has_many(:projects, PgRest.Test.PlugResources.TrimProjects, foreign_key: :client_id)
    end

    @impl PgRest.Resource
    def after_load(row, _context), do: row |> Map.delete("name") |> Map.put("c", true)
  end

  defmodule TrimProjects do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, after_load: true

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      belongs_to(:client, PgRest.Test.PlugResources.TrimClients, type: :integer)
      has_many(:tasks, PgRest.Test.PlugResources.TrimTasks, foreign_key: :project_id)
    end

    @impl PgRest.Resource
    def after_load(row, _context), do: row |> Map.delete("name") |> Map.put("p", true)
  end

  defmodule TrimTasks do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "tasks" do
      field(:name, :string)
      belongs_to(:project, PgRest.Test.PlugResources.TrimProjects, type: :integer)
    end
  end

  # A table whose name is 63 bytes, the identifier limit: aliases derived from it would be
  # truncated into each other.
  defmodule LongKin do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @table "long_table_name_" <> String.duplicate("x", 47)
    def table, do: @table

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema @table do
      belongs_to(:parent, __MODULE__, type: :integer)
      has_many(:kids, __MODULE__, foreign_key: :parent_id)
    end
  end

  # A root table named like a generated alias: the root's alias must not collide.
  defmodule AliasKin do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "pgrst_t1" do
      belongs_to(:parent, __MODULE__, type: :integer)
      has_many(:kids, __MODULE__, foreign_key: :parent_id)
    end
  end

  # A parent whose after_load renames an embed key, over a child that trims.
  defmodule RenameClients do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, after_load: true

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
      has_many(:projects, PgRest.Test.PlugResources.RenameProjects, foreign_key: :client_id)
    end

    @impl PgRest.Resource
    def after_load(row, _context) do
      Map.new(row, fn
        {"ITEMS", value} -> {"items", value}
        pair -> pair
      end)
    end
  end

  defmodule RenameProjects do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, after_load: true

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      belongs_to(:client, PgRest.Test.PlugResources.RenameClients, type: :integer)
    end

    @impl PgRest.Resource
    def after_load(row, _context), do: row |> Map.delete("name") |> Map.put("p", true)
  end

  defmodule TakeClients do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, after_load: true

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def after_load(row, _context), do: row |> Map.delete("name") |> Map.put("c", true)
  end

  defmodule TakeProjects do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, after_load: true

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      belongs_to(:client, PgRest.Test.PlugResources.TakeClients, type: :integer)
    end

    # A parent that keeps only some keys, merged spread columns included.
    @impl PgRest.Resource
    def after_load(row, _context), do: Map.take(row, ["id", "c"])
  end

  # A three-level merge chain: `NestedProjects` (middle) runs after_load over a spread of
  # `TrimClients`, which removes `name`.
  defmodule NestedProjects do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, after_load: true

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      belongs_to(:client, PgRest.Test.PlugResources.TrimClients, type: :integer)
    end

    @impl PgRest.Resource
    def after_load(row, _context), do: Map.put(row, "saw_name", Map.has_key?(row, "name"))
  end

  defmodule NestedTasks do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "tasks" do
      field(:name, :string)
      belongs_to(:project, PgRest.Test.PlugResources.NestedProjects, type: :integer)
    end
  end

  # Like the nested chain above, but the inner callback raises on a nil `name`: only that
  # merged embed loses its columns on an empty placeholder.
  defmodule RaisingClients do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, after_load: true

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def after_load(row, _context), do: Map.update!(row, "name", &String.upcase/1)
  end

  defmodule RaisingProjects do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, after_load: true

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      belongs_to(:client, PgRest.Test.PlugResources.RaisingClients, type: :integer)
    end

    @impl PgRest.Resource
    def after_load(row, _context), do: Map.put(row, "saw", true)
  end

  defmodule RaisingTasks do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "tasks" do
      field(:name, :string)
      belongs_to(:project, PgRest.Test.PlugResources.RaisingProjects, type: :integer)
    end
  end

  defmodule NoRead do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, allow: [:create]

    @schema_prefix "test"
    schema "items" do
    end
  end

  # A repo whose connections are down.
  defmodule DownRepo do
    @moduledoc false
    def in_transaction?, do: false
    def transaction(_fun, _opts), do: raise(DBConnection.ConnectionError, "connection refused")
    def query(_sql, _params, _opts), do: raise(DBConnection.ConnectionError, "connection refused")

    def query!(_sql, _params, _opts),
      do: raise(DBConnection.ConnectionError, "connection refused")
  end

  @doc "Every resource of this module."
  @spec all() :: [module()]
  def all, do: [Clients, Projects]

  @doc "The after_load resources whose callback trims the `name` column."
  @spec trimming() :: [module()]
  def trimming, do: [TrimClients, TrimProjects, TrimTasks]
end
