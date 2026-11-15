defmodule PgRest.Test.Policies.AllowAll do
  @moduledoc false
  @behaviour PgRest.Authorization
  @impl true
  def authorize(_conn, _target, _op, _context), do: :ok
end

defmodule PgRest.Test.Policies.BareQuery do
  @moduledoc false
  @behaviour PgRest.Authorization
  @impl true
  def authorize_query(_conn, _resource, _op, query, _context), do: {:ok, query}
end

defmodule PgRest.Test.Policies.Neither do
  @moduledoc false
  @behaviour PgRest.Authorization
end
