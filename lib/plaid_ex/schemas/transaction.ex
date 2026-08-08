defmodule PlaidEx.Schemas.Transaction do
  @moduledoc """
  A financial transaction from Plaid's Transactions product.

  Includes enriched fields (merchant name, logo, website, category)
  when using the Transactions product with enrichment enabled.
  """

  @type t :: %__MODULE__{
          transaction_id: String.t(),
          account_id: String.t(),
          amount: float(),
          iso_currency_code: String.t() | nil,
          unofficial_currency_code: String.t() | nil,
          category: [String.t()],
          category_id: String.t() | nil,
          date: String.t(),
          datetime: String.t() | nil,
          authorized_date: String.t() | nil,
          authorized_datetime: String.t() | nil,
          location: map(),
          name: String.t(),
          merchant_name: String.t() | nil,
          original_description: String.t() | nil,
          account_owner: String.t() | nil,
          pending: boolean(),
          pending_transaction_id: String.t() | nil,
          transaction_code: String.t() | nil,
          transaction_type: String.t() | nil,
          logo_url: String.t() | nil,
          website: String.t() | nil,
          personal_finance_category: map() | nil,
          personal_finance_category_icon_url: String.t() | nil,
          check_number: String.t() | nil,
          payment_meta: map(),
          payment_channel: String.t() | nil,
          counterparties: [map()],
          merchant_entity_id: String.t() | nil
        }

  defstruct [
    :transaction_id,
    :account_id,
    :amount,
    :iso_currency_code,
    :unofficial_currency_code,
    :category_id,
    :date,
    :datetime,
    :authorized_date,
    :authorized_datetime,
    :name,
    :merchant_name,
    :original_description,
    :account_owner,
    :pending,
    :pending_transaction_id,
    :transaction_code,
    :transaction_type,
    :logo_url,
    :website,
    :personal_finance_category,
    :personal_finance_category_icon_url,
    :check_number,
    :payment_channel,
    :merchant_entity_id,
    category: [],
    location: %{},
    payment_meta: %{},
    counterparties: []
  ]

  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      transaction_id: map["transaction_id"],
      account_id: map["account_id"],
      amount: map["amount"],
      iso_currency_code: map["iso_currency_code"],
      unofficial_currency_code: map["unofficial_currency_code"],
      category: map["category"] || [],
      category_id: map["category_id"],
      date: map["date"],
      datetime: map["datetime"],
      authorized_date: map["authorized_date"],
      authorized_datetime: map["authorized_datetime"],
      location: map["location"] || %{},
      name: map["name"],
      merchant_name: map["merchant_name"],
      original_description: map["original_description"],
      account_owner: map["account_owner"],
      pending: map["pending"] == true,
      pending_transaction_id: map["pending_transaction_id"],
      transaction_code: map["transaction_code"],
      transaction_type: map["transaction_type"],
      logo_url: map["logo_url"],
      website: map["website"],
      personal_finance_category: map["personal_finance_category"],
      personal_finance_category_icon_url: map["personal_finance_category_icon_url"],
      check_number: map["check_number"],
      payment_meta: map["payment_meta"] || %{},
      payment_channel: map["payment_channel"],
      counterparties: map["counterparties"] || [],
      merchant_entity_id: map["merchant_entity_id"]
    }
  end
end
