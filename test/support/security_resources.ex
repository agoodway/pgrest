defmodule PgRest.Test.SecurityResources do
  @moduledoc false
  # Resources over the compat fixture for the security regression tests: `allow:` without
  # `:read` on embeds, junctions and write responses, `readable:` on `Location`, and a scope
  # that sets the schema prefix.

  defmodule Clients do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
      has_many(:projects, PgRest.Test.SecurityResources.Projects, foreign_key: :client_id)
    end
  end

  # Writable, never readable.
  defmodule Projects do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, allow: [:create, :update, :delete]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      belongs_to(:client, PgRest.Test.SecurityResources.Clients, type: :integer)
    end
  end

  defmodule Tasks do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "tasks" do
      field(:name, :string)
      belongs_to(:project, PgRest.Test.SecurityResources.Projects, type: :integer)

      many_to_many(:users, PgRest.Test.SecurityResources.Users,
        join_through: "users_tasks",
        join_keys: [task_id: :id, user_id: :id]
      )
    end
  end

  defmodule Users do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "users" do
      field(:name, :string)
    end
  end

  # A junction that may be written, never read.
  defmodule UsersTasks do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, allow: [:create]

    @primary_key false
    @schema_prefix "test"
    schema "users_tasks" do
      belongs_to(:user, PgRest.Test.SecurityResources.Users, type: :integer, primary_key: true)
      belongs_to(:task, PgRest.Test.SecurityResources.Tasks, type: :integer, primary_key: true)
    end
  end

  # The primary key is outside `readable:`.
  defmodule PkHidden do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, readable: [:name]

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
    end
  end

  # No `@schema_prefix`: the scope picks the schema, like `put_query_prefix` tenancy.
  defmodule TenantTasks do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    schema "tasks" do
      field(:name, :string)
      field(:project_id, :integer)
    end

    @impl PgRest.Resource
    def scope(query, _context), do: query |> put_query_prefix("test") |> where([t], t.id > 0)
  end

  # A custom param whose empty value narrows nothing.
  defmodule SearchClients do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, custom_params: ["search"]

    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def handle_param("search", "", query, _context), do: query

    def handle_param("search", value, query, _context),
      do: where(query, [c], ilike(c.name, ^"%#{value}%"))
  end

  @doc "The resources of the `allow:` tests."
  @spec allow() :: [module()]
  def allow, do: [Clients, Projects, Tasks, Users, UsersTasks]
end
