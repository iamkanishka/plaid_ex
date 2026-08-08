defmodule PlaidEx.API.Accounts do
  @moduledoc """
  Plaid Accounts API — retrieve account and balance information.
  """

  use PlaidEx.API.Base

  alias PlaidEx.Schemas.Account

  @doc "Returns all accounts for an Item."
  @spec get(Config.t(), String.t()) ::
          {:ok, %{accounts: [Account.t()], item: map()}} | {:error, Error.t()}
  @spec get(Config.t(), String.t(), keyword()) ::
          {:ok, %{accounts: [Account.t()], item: map()}} | {:error, Error.t()}
  def get(%Config{} = config, access_token, opts \\ []) do
    account_ids = Keyword.get(opts, :account_ids)

    body = maybe_add_options(%{"access_token" => access_token}, account_ids)

    case Client.post("/accounts/get", body, config, opts) do
      {:ok, raw} ->
        {:ok,
         %{
           accounts: Enum.map(raw["accounts"] || [], &Account.from_map/1),
           item: raw["item"],
           request_id: raw["request_id"]
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc "Returns real-time balances for all accounts or specified account IDs."
  @spec get_balance(Config.t(), String.t()) ::
          {:ok, %{accounts: [Account.t()]}} | {:error, Error.t()}
  @spec get_balance(Config.t(), String.t(), keyword()) ::
          {:ok, %{accounts: [Account.t()]}} | {:error, Error.t()}
  def get_balance(%Config{} = config, access_token, opts \\ []) do
    account_ids = Keyword.get(opts, :account_ids)

    body = maybe_add_options(%{"access_token" => access_token}, account_ids)

    case Client.post("/accounts/balance/get", body, config, opts) do
      {:ok, raw} ->
        {:ok,
         %{
           accounts: Enum.map(raw["accounts"] || [], &Account.from_map/1),
           item: raw["item"]
         }}

      {:error, _} = error ->
        error
    end
  end

  defp maybe_add_options(body, nil), do: body

  defp maybe_add_options(body, account_ids),
    do: Map.put(body, "options", %{"account_ids" => account_ids})
end
