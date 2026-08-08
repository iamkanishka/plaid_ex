defmodule PlaidEx.Schemas.AccessToken do
  @moduledoc "Response from /item/public_token/exchange."

  @type t :: %__MODULE__{
          access_token: String.t(),
          item_id: String.t(),
          request_id: String.t()
        }

  defstruct [:access_token, :item_id, :request_id]

  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      access_token: map["access_token"],
      item_id: map["item_id"],
      request_id: map["request_id"]
    }
  end
end
