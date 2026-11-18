defmodule Demo.Tasks.Task do
  use Ecto.Schema
  use PgRest.Resource, allow: [:read], custom_params: ["search"]
  import Ecto.Query

  schema "tasks" do
    field :title, :string
    field :description, :string
    field :status, :string
    field :priority, :string
    field :assignee_name, :string
    field :tags, {:array, :string}
    field :due_date, :date
    field :estimated_hours, :decimal
    field :completed, :boolean, default: false
    field :urgent, :boolean, default: false
    field :complexity, :integer
    field :deleted_at, :utc_datetime

    belongs_to :project, Demo.Projects.Project

    timestamps(type: :utc_datetime)
  end

  # Exclude soft-deleted tasks by default
  @impl PgRest.Resource
  def scope(query, _context) do
    where(query, [t], is_nil(t.deleted_at))
  end

  @impl PgRest.Resource
  def handle_param("search", value, query, _context) do
    pattern = "%#{value}%"
    where(query, [t], ilike(t.title, ^pattern) or ilike(t.description, ^pattern))
  end

  def handle_param(_key, _value, query, _context), do: query
end
