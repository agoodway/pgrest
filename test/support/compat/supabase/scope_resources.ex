defmodule PgRest.Compat.SupabaseScope.RlsNote do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource
  import Ecto.Query
  @schema_prefix "public"
  schema "rls_notes" do
    field(:owner, :string)
    field(:body, :string)
    field(:slug, :string)
  end

  @impl true
  def scope(query, %{role: "service_role"}), do: query
  def scope(query, %{jwt_claims: %{"sub" => sub}}), do: where(query, [n], n.owner == ^sub)
  def scope(query, _context), do: where(query, false)
  @impl true
  def changeset(row, attrs, context) do
    changeset = Ecto.Changeset.cast(row, attrs, [:id, :owner, :body, :slug])

    if Map.has_key?(attrs, "owner"),
      do: changeset,
      else: Ecto.Changeset.put_change(changeset, :owner, context.jwt_claims["sub"])
  end
end

defmodule PgRest.Compat.SupabaseScope.PrivateDoc do
  @moduledoc false
  use Ecto.Schema
  use PgRest.Resource
  @schema_prefix "public"
  schema "private_docs" do
    field(:body, :string)
  end
end

defmodule PgRest.Compat.SupabaseScopeAuthorization do
  @moduledoc false
  @behaviour PgRest.Authorization
  alias PgRest.Compat.SupabaseScope
  @impl true
  def authorize(_conn, SupabaseScope.PrivateDoc, _op, _ctx), do: {:error, :denied}

  def authorize(_conn, SupabaseScope.RlsNote, op, %{role: "anon"}) when op != :read,
    do: {:error, :denied}

  def authorize(_conn, SupabaseScope.RlsNote, _op, _ctx), do: :ok

  def authorize(_conn, %PgRest.Function{name: "privileged_hello"}, :execute, %{role: role})
      when role != "anon", do: :ok

  def authorize(_conn, _target, _op, _ctx), do: {:error, :denied}
end
