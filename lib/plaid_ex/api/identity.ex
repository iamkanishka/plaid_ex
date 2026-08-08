defmodule PlaidEx.API.Identity do
  @moduledoc """
  Plaid Identity API — retrieve owner identity information.
  """

  use PlaidEx.API.Base

  defsingle(
    :get,
    "/identity/get",
    "access_token",
    "Returns identity data for all accounts on an Item."
  )

  @doc "Matches provided identity data against the account owner data."
  @spec match(Config.t(), String.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  @spec match(Config.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def match(%Config{} = config, access_token, user, opts \\ []) do
    Client.post(
      "/identity/match",
      %{"access_token" => access_token, "user" => user},
      config,
      opts
    )
  end
end
