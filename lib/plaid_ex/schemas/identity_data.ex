defmodule PlaidEx.Schemas.IdentityData do
  @moduledoc "Identity data returned by /identity/get."

  @type t :: %__MODULE__{
          account_id: String.t(),
          owners: [map()]
        }

  defstruct [:account_id, owners: []]

  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      account_id: map["account_id"],
      owners: map["owners"] || []
    }
  end
end
