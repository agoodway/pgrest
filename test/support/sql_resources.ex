defmodule PgRest.Test.SQLResources do
  @moduledoc false
  # Resources over the read-only compat fixture, for the SQL builder tests.

  defmodule Plain do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      field(:client_id, :integer)
    end
  end

  defmodule Where do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      field(:client_id, :integer)
    end

    # An admin context (`admin?: true`) sees every row: an identity scope.
    @impl PgRest.Resource
    def scope(query, %{admin?: true}), do: query

    def scope(query, ctx) do
      if pid = ctx[:test_pid], do: send(pid, {:scope_called, __MODULE__})
      where(query, [r], r.client_id == ^ctx.client_id)
    end
  end

  defmodule Named do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      field(:client_id, :integer)
    end

    # Named bindings: `as:` on the source and on a join, referenced by name in where.
    @impl PgRest.Resource
    def scope(query, ctx) do
      query
      |> from(as: :p)
      |> join(:inner, [p: p], t in "tasks", as: :t, on: t.project_id == p.id, prefix: "test")
      |> where([p: p, t: t], p.client_id == ^ctx.client_id and t.name != "none")
    end
  end

  defmodule NamedPlain do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      field(:client_id, :integer)
    end

    @impl PgRest.Resource
    def scope(query, ctx), do: where(from(query, as: :t), [t: t], t.client_id == ^ctx.client_id)
  end

  defmodule Joined do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      field(:client_id, :integer)
    end

    # Every project has two tasks, so the join doubles each base row.
    @impl PgRest.Resource
    def scope(query, ctx) do
      query
      |> join(:inner, [r], t in "tasks", on: t.project_id == r.id, prefix: "test")
      |> where([r], r.client_id == ^ctx.client_id)
    end
  end

  defmodule Distinct do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
      field(:client_id, :integer)
    end

    @impl PgRest.Resource
    def scope(query, ctx),
      do: query |> where([r], r.client_id == ^ctx.client_id) |> distinct(true)
  end

  defmodule Renamed do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:title, :string, source: :name)
      field(:client_id, :integer)
    end

    @impl PgRest.Resource
    def scope(query, ctx), do: where(query, [r], r.client_id == ^ctx.client_id)
  end

  defmodule RenamedJoined do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:title, :string, source: :name)
      field(:client_id, :integer)
    end

    @impl PgRest.Resource
    def scope(query, _ctx) do
      join(query, :inner, [r], t in "tasks", on: t.project_id == r.id, prefix: "test")
    end
  end

  defmodule Ordered do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def scope(query, _ctx), do: order_by(query, [r], r.name)
  end

  defmodule Limited do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def scope(query, _ctx), do: limit(query, 1)
  end

  defmodule Custom do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource, custom_params: ["name_like"]
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def handle_param("name_like", value, query, _ctx),
      do: where(query, [r], like(r.name, ^value))
  end

  defmodule Keyless do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key false
    @schema_prefix "test"
    schema "no_pk" do
      field(:a, :string)
      field(:b, :string)
    end

    @impl PgRest.Resource
    def scope(query, _ctx), do: distinct(query, true)
  end
end

defmodule PgRest.Test.SQLResources.Extra do
  @moduledoc false
  # More scope shapes for the semijoin and predicate-contract tests.

  defmodule Prefixed do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    # No @schema_prefix: the tenant schema comes from the scope.
    @primary_key {:id, :integer, autogenerate: false}
    schema "projects" do
      field(:name, :string)
      field(:client_id, :integer)
    end

    @impl PgRest.Resource
    def scope(query, _ctx), do: query |> put_query_prefix("test") |> distinct(true)
  end

  defmodule Narrow do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    # `client_id` exists in the table but not in the schema.
    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def scope(query, _ctx), do: distinct(query, true)
  end

  defmodule Forbidden do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def scope(query, %{kind: :union}), do: union_all(query, ^query)
    def scope(query, %{kind: :lock}), do: lock(query, "FOR UPDATE")
    def scope(query, %{kind: :cte}), do: with_cte(query, "x", as: ^query)
    def scope(query, %{kind: :window}), do: windows(query, [r], w: [partition_by: r.id])
    def scope(_query, %{kind: :from}), do: from(t in "tasks", prefix: "test")
  end
end

defmodule PgRest.Test.SQLResources.Extra2 do
  @moduledoc false

  defmodule Unprefixed do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    schema "projects" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def scope(query, _ctx), do: distinct(query, true)
  end

  defmodule Hidden do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:title, :string, source: :name)
      field(:client_id, :integer, load_in_query: false)
    end

    @impl PgRest.Resource
    def scope(query, %{distinct: true}), do: distinct(query, true)
    def scope(query, _ctx), do: query
  end

  defmodule Hinted do
    @moduledoc false
    use Ecto.Schema
    use PgRest.Resource
    import Ecto.Query

    @primary_key {:id, :integer, autogenerate: false}
    @schema_prefix "test"
    schema "projects" do
      field(:name, :string)
    end

    @impl PgRest.Resource
    def scope(query, %{kind: :hint}), do: hint(query)
    def scope(query, %{kind: :update}), do: update(query, set: [name: "x"])

    defp hint(query), do: %{query | from: %{query.from | hints: ["x"]}}
  end
end
