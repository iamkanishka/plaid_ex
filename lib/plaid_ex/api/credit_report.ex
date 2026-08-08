defmodule PlaidEx.API.CreditReport do
  @moduledoc """
  Plaid Consumer Report API — credit and risk reports.

  Note: Usage is subject to FCRA compliance requirements.
  Consult your legal counsel before implementing.
  """

  use PlaidEx.API.Base
  @doc "Creates a consumer report for an asset report."
  @spec create(Config.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec create(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create(%Config{} = config, asset_report_token, user_token, opts \\ []) do
    Client.post(
      "/consumer_report/create",
      %{"asset_report_token" => asset_report_token, "user_token" => user_token},
      config,
      opts
    )
  end
end
