defmodule PlaidEx.API.Processor do
  @moduledoc """
  Plaid Processor API — pass-through data to payment processors.

  Allows processor partners (Stripe, Dwolla, Apex, etc.) to use
  Plaid-verified account data without sharing the access token.
  """

  use PlaidEx.API.Base
  @doc "Returns ACH data formatted for a processor partner."
  @spec get_auth(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_auth(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_auth(%Config{} = config, processor_token, opts \\ []) do
    Client.post("/processor/auth/get", %{"processor_token" => processor_token}, config, opts)
  end

  @doc "Returns account identity data for a processor token."
  @spec get_identity(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_identity(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_identity(%Config{} = config, processor_token, opts \\ []) do
    Client.post("/processor/identity/get", %{"processor_token" => processor_token}, config, opts)
  end

  @doc "Returns balance data for a processor token."
  @spec get_balance(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_balance(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_balance(%Config{} = config, processor_token, opts \\ []) do
    Client.post("/processor/balance/get", %{"processor_token" => processor_token}, config, opts)
  end

  @doc "Returns a Stripe bank account token from a processor token."
  @spec create_stripe_bank_account_token(Config.t(), String.t()) ::
          {:ok, %{stripe_bank_account_token: String.t()}} | {:error, Error.t()}
  @spec create_stripe_bank_account_token(Config.t(), String.t(), keyword()) ::
          {:ok, %{stripe_bank_account_token: String.t()}} | {:error, Error.t()}
  def create_stripe_bank_account_token(%Config{} = config, processor_token, opts \\ []) do
    case Client.post(
           "/processor/stripe/bank_account_token/create",
           %{"processor_token" => processor_token},
           config,
           opts
         ) do
      {:ok, raw} -> {:ok, %{stripe_bank_account_token: raw["stripe_bank_account_token"]}}
      {:error, _} = error -> error
    end
  end
end
