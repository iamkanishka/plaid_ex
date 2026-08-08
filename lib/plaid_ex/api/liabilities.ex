defmodule PlaidEx.API.Liabilities do
  @moduledoc """
  Plaid Liabilities API — loan, mortgage, and credit card details.
  """

  use PlaidEx.API.Base

  defsingle(
    :get,
    "/liabilities/get",
    "access_token",
    "Returns liability details for student loans, mortgages, and credit cards."
  )
end
