defmodule PgRest.Authorization.State do
  @moduledoc "Internal authorization data carried by requests and plans, never user context."

  @enforce_keys [
    :policies,
    :payload_columns,
    :write_check,
    :read_check,
    :nodes,
    :source_query,
    :hook?
  ]
  defstruct @enforce_keys

  @type authorization_node :: {module() | PgRest.Function.t(), [String.t()], Ecto.Query.t() | nil}
  @type t :: %__MODULE__{
          policies: map(),
          payload_columns: :all | MapSet.t(String.t()),
          write_check: Ecto.Query.t() | nil,
          read_check: Ecto.Query.t() | nil,
          nodes: [authorization_node()],
          source_query: Ecto.Query.t() | nil,
          hook?: boolean()
        }

  @doc "An authorization state with no restrictions or cached policies."
  @spec empty() :: t()
  def empty do
    %__MODULE__{
      policies: %{},
      payload_columns: :all,
      write_check: nil,
      read_check: nil,
      nodes: [],
      source_query: nil,
      hook?: false
    }
  end
end
