defmodule PgRest.Test.ReadResources do
  @moduledoc false
  # Resources over the compat fixture for the planner and read compiler tests.

  defmodule Clients do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "clients" do
      field(:name, :string)
      has_many(:projects, PgRest.Test.ReadResources.Projects, foreign_key: :client_id)
    end
  end

  # Only projects whose name starts with `Windows` are visible; reports each scope call.
  defmodule Projects do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      belongs_to(:client, PgRest.Test.ReadResources.Clients, type: :integer)
    end

    @impl PgRest.Resource
    def scope(query, ctx) do
      if pid = ctx[:test_pid], do: send(pid, {:scope_called, __MODULE__})
      where(query, [r], like(r.name, "Windows%"))
    end
  end

  # A declared custom param narrows the query through `handle_param/4`.
  defmodule Searchable do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, custom_params: ["q"]
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def handle_param("q", value, query, _ctx), do: where(query, [r], like(r.name, ^"%#{value}%"))
  end

  # `name` is stored in `client_id` (integer) and `client_id` in `name` (varchar): the
  # field names and the database columns are crossed.
  defmodule Swapped do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :integer, source: :client_id)
      field(:client_id, :string, source: :name)
    end
  end
end
