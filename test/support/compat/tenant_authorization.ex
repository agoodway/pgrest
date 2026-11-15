defmodule PgRest.Compat.TenantAuthorization do
  @moduledoc false
  import Ecto.Query
  alias PgRest.Compat.Resources

  def authorize_query(_conn, resource, :read, query, context) do
    tenant = Map.fetch!(context, :tenant_client_id)
    policy(query, resource, tenant, context)
  end

  def authorize_query(_conn, _resource, _operation, _query, _context),
    do: {:error, :unsupported}

  defp policy(query, Resources.Clients, tenant, context) do
    columns = if context[:role] == :admin, do: :all, else: ["id"]
    {:ok, where(query, [c], c.id == ^tenant), columns: columns}
  end

  defp policy(query, Resources.Projects, tenant, _context),
    do: {:ok, where(query, [p], p.client_id == ^tenant), aggregates: true, count: true}

  defp policy(query, Resources.Tasks, tenant, _context) do
    projects = from(p in Resources.Projects, where: p.client_id == ^tenant, select: p.id)
    {:ok, where(query, [t], t.project_id in subquery(projects))}
  end

  defp policy(_query, _resource, _tenant, _context), do: {:error, :unsupported}
end
