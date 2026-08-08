defmodule PlaidEx.API.User do
  @moduledoc """
  Plaid User API — manage Plaid-hosted user identities.
  """

  use PlaidEx.API.Base

  @doc "Creates a Plaid-hosted user identity."
  @spec create(Config.t(), String.t()) ::
          {:ok, %{user_token: String.t(), user_id: String.t()}} | {:error, Error.t()}
  @spec create(Config.t(), String.t(), keyword()) ::
          {:ok, %{user_token: String.t(), user_id: String.t()}} | {:error, Error.t()}
  def create(%Config{} = config, client_user_id, opts \\ []) do
    case Client.post("/user/create", %{"client_user_id" => client_user_id}, config, opts) do
      {:ok, raw} ->
        {:ok,
         %{
           user_token: raw["user_token"],
           user_id: raw["user_id"],
           request_id: raw["request_id"]
         }}

      {:error, _} = error ->
        error
    end
  end

  defsingle(:get, "/user/get", "user_token", "Retrieves a user by user_token.")

  @doc "Updates a user's client_user_id."
  @spec update(Config.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec update(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def update(%Config{} = config, user_token, new_client_user_id, opts \\ []) do
    Client.post(
      "/user/update",
      %{"user_token" => user_token, "client_user_id" => new_client_user_id},
      config,
      opts
    )
  end
end
