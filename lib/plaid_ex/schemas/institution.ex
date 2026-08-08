defmodule PlaidEx.Schemas.Institution do
  @moduledoc "A financial institution from Plaid's institution database."

  @type t :: %__MODULE__{
          institution_id: String.t(),
          name: String.t(),
          products: [String.t()],
          country_codes: [String.t()],
          routing_numbers: [String.t()],
          oauth: boolean(),
          status: map() | nil,
          primary_color: String.t() | nil,
          logo: String.t() | nil,
          url: String.t() | nil,
          dtc_numbers: [String.t()]
        }

  defstruct [
    :institution_id,
    :name,
    :status,
    :primary_color,
    :logo,
    :url,
    products: [],
    country_codes: [],
    routing_numbers: [],
    dtc_numbers: [],
    oauth: false
  ]

  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      institution_id: map["institution_id"],
      name: map["name"],
      products: map["products"] || [],
      country_codes: map["country_codes"] || [],
      routing_numbers: map["routing_numbers"] || [],
      oauth: map["oauth"] == true,
      status: map["status"],
      primary_color: map["primary_color"],
      logo: map["logo"],
      url: map["url"],
      dtc_numbers: map["dtc_numbers"] || []
    }
  end
end
