defmodule PlaidEx.Schemas.Item do
  @moduledoc "A Plaid Item — represents a user's connection to a financial institution."

  @type t :: %__MODULE__{
          item_id: String.t(),
          institution_id: String.t() | nil,
          webhook: String.t() | nil,
          error: map() | nil,
          available_products: [String.t()],
          billed_products: [String.t()],
          consent_expiration_time: String.t() | nil,
          update_type: String.t() | nil
        }

  defstruct [
    :item_id,
    :institution_id,
    :webhook,
    :error,
    :consent_expiration_time,
    :update_type,
    available_products: [],
    billed_products: []
  ]

  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      item_id: map["item_id"],
      institution_id: map["institution_id"],
      webhook: map["webhook"],
      error: map["error"],
      available_products: map["available_products"] || [],
      billed_products: map["billed_products"] || [],
      consent_expiration_time: map["consent_expiration_time"],
      update_type: map["update_type"]
    }
  end
end
