defmodule PlaidEx.API.Wallet do
  @moduledoc """
  Plaid Wallet API — e-money wallet management (UK/EU).

  This product is only available in `:eu` and `:uk` regions.
  """

  use PlaidEx.API.Base

  @doc "Creates a new wallet."
  @spec create(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec create(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def create(%Config{} = config, iso_currency_code, opts \\ []) do
    Client.post("/wallet/create", %{"iso_currency_code" => iso_currency_code}, config, opts)
  end

  defsingle(:get, "/wallet/get", "wallet_id", "Retrieves a wallet by ID.")

  @doc "Lists all wallets for the client."
  @spec list(Config.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec list(Config.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list(%Config{} = config, opts \\ []) do
    body =
      %{
        "iso_currency_code" => Keyword.get(opts, :iso_currency_code),
        "count" => Keyword.get(opts, :count, 10),
        "cursor" => Keyword.get(opts, :cursor)
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    Client.post("/wallet/list", body, config, opts)
  end

  @doc "Executes a wallet transaction (send/receive)."
  @spec execute_transaction(Config.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  @spec execute_transaction(Config.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def execute_transaction(%Config{} = config, params, opts \\ []) do
    idempotency_key = Keyword.get(opts, :idempotency_key)

    Client.post(
      "/wallet/transaction/execute",
      params,
      config,
      Keyword.merge(opts, idempotency_key: idempotency_key)
    )
  end

  @doc "Lists transactions for a wallet."
  @spec list_transactions(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec list_transactions(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def list_transactions(%Config{} = config, wallet_id, opts \\ []) do
    body =
      %{
        "wallet_id" => wallet_id,
        "count" => Keyword.get(opts, :count, 10),
        "cursor" => Keyword.get(opts, :cursor)
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    Client.post("/wallet/transaction/list", body, config, opts)
  end

  @doc "Retrieves a single wallet transaction."
  @spec get_transaction(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_transaction(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_transaction(%Config{} = config, wallet_transaction_id, opts \\ []) do
    Client.post(
      "/wallet/transaction/get",
      %{"wallet_transaction_id" => wallet_transaction_id},
      config,
      opts
    )
  end
end
