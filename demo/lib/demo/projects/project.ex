defmodule Demo.Projects.Project do
  use Ecto.Schema
  use PgRest.Resource, allow: [:read], custom_params: ["search"]
  import Ecto.Query

  schema "projects" do
    field :name, :string
    field :description, :string
    field :status, :string
    field :archived, :boolean, default: false
    field :deadline, :date
    field :budget, :decimal

    has_many :tasks, Demo.Tasks.Task

    timestamps(type: :utc_datetime)
  end

  @impl PgRest.Resource
  def handle_param("search", value, query, _context) do
    pattern = "%#{value}%"
    where(query, [p], ilike(p.name, ^pattern) or ilike(p.description, ^pattern))
  end

  def handle_param(_key, _value, query, _context), do: query
end
