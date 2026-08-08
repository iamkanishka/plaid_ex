defmodule PlaidEx.API.Signal do
  @moduledoc """
  Plaid Signal API — ACH return risk scoring.
  """

  use PlaidEx.API.Base
  @doc "Evaluates ACH return risk for a transaction."
  @spec evaluate(Config.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  @spec evaluate(Config.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def evaluate(%Config{} = config, params, opts \\ []) do
    Client.post("/signal/evaluate", params, config, opts)
  end

  @doc "Returns a Decision Report confirming whether the ACH was initiated."
  @spec decision_report(Config.t(), String.t(), boolean()) ::
          {:ok, map()} | {:error, Error.t()}
  @spec decision_report(Config.t(), String.t(), boolean(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def decision_report(%Config{} = config, client_transaction_id, initiated, opts \\ []) do
    Client.post(
      "/signal/decision/report",
      %{"client_transaction_id" => client_transaction_id, "initiated" => initiated},
      config,
      opts
    )
  end

  @doc "Reports the outcome of an ACH return."
  @spec return_report(Config.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  @spec return_report(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def return_report(%Config{} = config, client_transaction_id, return_code, opts \\ []) do
    Client.post(
      "/signal/return/report",
      %{"client_transaction_id" => client_transaction_id, "return_code" => return_code},
      config,
      opts
    )
  end

  @doc "Prepares items for Signal evaluation."
  @spec prepare(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec prepare(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def prepare(%Config{} = config, access_token, opts \\ []) do
    Client.post("/signal/prepare", %{"access_token" => access_token}, config, opts)
  end
end
