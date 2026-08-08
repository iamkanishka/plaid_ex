defmodule PlaidEx.Schemas.Security do
  @moduledoc "A security (asset) referenced by investment holdings and transactions."

  @type t :: %__MODULE__{
          security_id: String.t(),
          isin: String.t() | nil,
          cusip: String.t() | nil,
          sedol: String.t() | nil,
          institution_security_id: String.t() | nil,
          institution_id: String.t() | nil,
          proxy_security_id: String.t() | nil,
          name: String.t() | nil,
          ticker_symbol: String.t() | nil,
          is_cash_equivalent: boolean(),
          type: String.t() | nil,
          close_price: float() | nil,
          close_price_as_of: String.t() | nil,
          iso_currency_code: String.t() | nil,
          unofficial_currency_code: String.t() | nil,
          market_identifier_code: String.t() | nil,
          sector: String.t() | nil,
          industry: String.t() | nil
        }

  defstruct [
    :security_id,
    :isin,
    :cusip,
    :sedol,
    :institution_security_id,
    :institution_id,
    :proxy_security_id,
    :name,
    :ticker_symbol,
    :type,
    :close_price,
    :close_price_as_of,
    :iso_currency_code,
    :unofficial_currency_code,
    :market_identifier_code,
    :sector,
    :industry,
    is_cash_equivalent: false
  ]

  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      security_id: map["security_id"],
      isin: map["isin"],
      cusip: map["cusip"],
      sedol: map["sedol"],
      institution_security_id: map["institution_security_id"],
      institution_id: map["institution_id"],
      proxy_security_id: map["proxy_security_id"],
      name: map["name"],
      ticker_symbol: map["ticker_symbol"],
      is_cash_equivalent: map["is_cash_equivalent"] == true,
      type: map["type"],
      close_price: map["close_price"],
      close_price_as_of: map["close_price_as_of"],
      iso_currency_code: map["iso_currency_code"],
      unofficial_currency_code: map["unofficial_currency_code"],
      market_identifier_code: map["market_identifier_code"],
      sector: map["sector"],
      industry: map["industry"]
    }
  end
end
