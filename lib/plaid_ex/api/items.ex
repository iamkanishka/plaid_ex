defmodule PlaidEx.API.Items do
  @moduledoc """
  Plaid Items API — manage connected financial institution Items.

  An Item represents a user's connection to a financial institution.
  It holds one or more accounts and is associated with an access token.
  """

  use PlaidEx.API.Base

  alias PlaidEx.Schemas.AccessToken
  alias PlaidEx.Schemas.Item

  @doc """
  Exchanges a Link `public_token` for an `access_token`.

  The `public_token` is returned by the Plaid Link SDK after the user
  successfully completes the Link flow. It is **short-lived** (30 minutes)
  and **single-use**. Exchange it immediately.

  Store the returned `access_token` permanently — it does not expire
  unless the user revokes access or the item enters error state.
  """
  @spec exchange_public_token(Config.t(), String.t()) ::
          {:ok, AccessToken.t()} | {:error, Error.t()}
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  @spec exchange_public_token(Config.t(), String.t(), keyword()) ::
          {:ok, AccessToken.t()} | {:error, Error.t()}
  def exchange_public_token(%Config{} = config, public_token, opts \\ []) do
    case Client.post(
           "/item/public_token/exchange",
           %{"public_token" => public_token},
           config,
           opts
         ) do
      {:ok, raw} -> {:ok, AccessToken.from_map(raw)}
      {:error, _} = error -> error
    end
  end

  @doc "Retrieves metadata about an Item and its available products."
  @spec get(Config.t(), String.t()) ::
          {:ok, %{item: Item.t(), status: map()}} | {:error, Error.t()}
  @spec get(Config.t(), String.t(), keyword()) ::
          {:ok, %{item: Item.t(), status: map()}} | {:error, Error.t()}
  def get(%Config{} = config, access_token, opts \\ []) do
    case Client.post("/item/get", %{"access_token" => access_token}, config, opts) do
      {:ok, raw} -> {:ok, %{item: Item.from_map(raw["item"]), status: raw["status"]}}
      {:error, _} = error -> error
    end
  end

  defsingle(
    :remove,
    "/item/remove",
    "access_token",
    "Removes an Item. Revokes the access token and disconnects all linked accounts."
  )

  @doc "Updates the webhook URL for an Item."
  @spec update_webhook(Config.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  @spec update_webhook(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def update_webhook(%Config{} = config, access_token, webhook_url, opts \\ []) do
    Client.post(
      "/item/webhook/update",
      %{"access_token" => access_token, "webhook" => webhook_url},
      config,
      opts
    )
  end

  @doc "Invalidates an access token and returns a new one. Use for token rotation."
  @spec invalidate_access_token(Config.t(), String.t()) ::
          {:ok, %{new_access_token: String.t()}} | {:error, Error.t()}
  @spec invalidate_access_token(Config.t(), String.t(), keyword()) ::
          {:ok, %{new_access_token: String.t()}} | {:error, Error.t()}
  def invalidate_access_token(%Config{} = config, access_token, opts \\ []) do
    case Client.post(
           "/item/access_token/invalidate",
           %{"access_token" => access_token},
           config,
           opts
         ) do
      {:ok, raw} ->
        {:ok, %{new_access_token: raw["new_access_token"], request_id: raw["request_id"]}}

      {:error, _} = error ->
        error
    end
  end

  @doc "Creates a processor token for a partner processor (Dwolla, Stripe, etc.)."
  @spec create_processor_token(Config.t(), String.t(), String.t(), String.t()) ::
          {:ok, %{processor_token: String.t()}} | {:error, Error.t()}
  @spec create_processor_token(Config.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{processor_token: String.t()}} | {:error, Error.t()}
  def create_processor_token(%Config{} = config, access_token, account_id, processor, opts \\ []) do
    case Client.post(
           "/processor/token/create",
           %{
             "access_token" => access_token,
             "account_id" => account_id,
             "processor" => processor
           },
           config,
           opts
         ) do
      {:ok, raw} ->
        {:ok, %{processor_token: raw["processor_token"], request_id: raw["request_id"]}}

      {:error, _} = error ->
        error
    end
  end

  @doc "Creates a public token from an access token (for reinitializing Link in update mode)."
  @spec create_public_token(Config.t(), String.t()) ::
          {:ok, %{public_token: String.t()}} | {:error, Error.t()}
  @spec create_public_token(Config.t(), String.t(), keyword()) ::
          {:ok, %{public_token: String.t()}} | {:error, Error.t()}
  def create_public_token(%Config{} = config, access_token, opts \\ []) do
    case Client.post(
           "/item/public_token/create",
           %{"access_token" => access_token},
           config,
           opts
         ) do
      {:ok, raw} ->
        {:ok, %{public_token: raw["public_token"], expiration: raw["expiration"]}}

      {:error, _} = error ->
        error
    end
  end
end
