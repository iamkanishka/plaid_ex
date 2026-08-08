defmodule PlaidEx.Schemas.InvestmentHolding do
  @moduledoc "An investment holding (position) from Plaid Investments."

  @type t :: %__MODULE__{
          account_id: String.t(),
          security_id: String.t(),
          institution_price: float() | nil,
          institution_price_as_of: String.t() | nil,
          institution_price_datetime: String.t() | nil,
          institution_value: float() | nil,
          cost_basis: float() | nil,
          quantity: float(),
          iso_currency_code: String.t() | nil,
          unofficial_currency_code: String.t() | nil
        }

  defstruct [
    :account_id,
    :security_id,
    :institution_price,
    :institution_price_as_of,
    :institution_price_datetime,
    :institution_value,
    :cost_basis,
    :quantity,
    :iso_currency_code,
    :unofficial_currency_code
  ]

  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      account_id: map["account_id"],
      security_id: map["security_id"],
      institution_price: map["institution_price"],
      institution_price_as_of: map["institution_price_as_of"],
      institution_price_datetime: map["institution_price_datetime"],
      institution_value: map["institution_value"],
      cost_basis: map["cost_basis"],
      quantity: map["quantity"],
      iso_currency_code: map["iso_currency_code"],
      unofficial_currency_code: map["unofficial_currency_code"]
    }
  end
end
