defmodule PlaidEx.API.Auth do
  @moduledoc """
  Plaid Auth API — retrieve ACH account and routing numbers.

  Returns the checking/savings account numbers needed for ACH transfers.
  """

  use PlaidEx.API.Base

  @doc "Returns ACH account and routing numbers for all accounts on an Item."
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  @spec get(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  @spec get(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(%Config{} = config, access_token, opts \\ []) do
    account_ids = Keyword.get(opts, :account_ids)

    base_body = %{"access_token" => access_token}

    body =
      if account_ids,
        do: Map.put(base_body, "options", %{"account_ids" => account_ids}),
        else: base_body

    Client.post("/auth/get", body, config, opts)
  end
end
