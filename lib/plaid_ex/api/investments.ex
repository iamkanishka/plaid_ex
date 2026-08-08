defmodule PlaidEx.API.Investments do
  @moduledoc """
  Plaid Investments API — holdings, transactions, and securities.
  """

  use PlaidEx.API.Base

  alias PlaidEx.Schemas.InvestmentHolding
  alias PlaidEx.Schemas.Security
  @doc "Returns all investment holdings (positions) for an Item."
  @spec get_holdings(Config.t(), String.t()) ::
          {:ok, %{holdings: [InvestmentHolding.t()], securities: [Security.t()]}}
          | {:error, Error.t()}
  @spec get_holdings(Config.t(), String.t(), keyword()) ::
          {:ok, %{holdings: [InvestmentHolding.t()], securities: [Security.t()]}}
          | {:error, Error.t()}
  def get_holdings(%Config{} = config, access_token, opts \\ []) do
    case Client.post(
           "/investments/holdings/get",
           %{"access_token" => access_token},
           config,
           opts
         ) do
      {:ok, raw} ->
        {:ok,
         %{
           holdings: Enum.map(raw["holdings"] || [], &InvestmentHolding.from_map/1),
           securities: Enum.map(raw["securities"] || [], &Security.from_map/1),
           accounts: raw["accounts"] || [],
           item: raw["item"]
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc "Returns investment transactions for an Item over a date range."
  @spec get_transactions(Config.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  @spec get_transactions(Config.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_transactions(%Config{} = config, access_token, start_date, end_date, opts \\ []) do
    Client.post(
      "/investments/transactions/get",
      %{
        "access_token" => access_token,
        "start_date" => start_date,
        "end_date" => end_date
      },
      config,
      opts
    )
  end

  defsingle(
    :refresh,
    "/investments/refresh",
    "access_token",
    "Refreshes investment data for an Item."
  )
end
