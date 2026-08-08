defmodule PlaidEx.API.Enrich do
  @moduledoc """
  Plaid Enrich API — transaction enrichment for non-Plaid data sources.

  Provides merchant name resolution, category classification, and
  logo URLs for arbitrary transaction data, regardless of source.
  """

  use PlaidEx.API.Base

  @doc """
  Enriches a list of transactions with merchant info and categorization.

  ## Required transaction fields
  - `id` — your internal ID
  - `description` — raw transaction description
  - `amount` — the transaction amount
  - `direction` — `"OUTFLOW"` or `"INFLOW"`
  """
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  @spec enrich(Config.t(), [map()]) ::
          {:ok, %{enriched_transactions: [map()]}} | {:error, Error.t()}
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  @spec enrich(Config.t(), [map()], keyword()) ::
          {:ok, %{enriched_transactions: [map()]}} | {:error, Error.t()}
  def enrich(%Config{} = config, transactions, opts \\ []) do
    body = %{
      "account_type" => Keyword.get(opts, :account_type, "depository"),
      "transactions" => transactions
    }

    case Client.post("/transactions/enrich", body, config, opts) do
      {:ok, raw} -> {:ok, %{enriched_transactions: raw["enriched_transactions"] || []}}
      {:error, _} = error -> error
    end
  end
end
