defmodule PlaidEx.API.Sandbox do
  @moduledoc """
  Plaid Sandbox API — sandbox-only test utilities.

  Use these endpoints to test your integration without real bank accounts.

  **All functions in this module fail in production environments.**
  """

  use PlaidEx.API.Base

  @doc """
  Creates a sandbox Item with test accounts.

  Returns a `public_token` ready for exchange, without needing
  to open Link. Used in automated testing.

  ## Example

      {:ok, %{public_token: token}} = PlaidEx.API.Sandbox.create_public_token(config,
        institution_id: "ins_109508",
        initial_products: ["transactions"],
        options: %{override_username: "user_good"}
      )
  """
  @spec create_public_token(Config.t()) ::
          {:ok, %{public_token: String.t()}} | {:error, Error.t()}
  @spec create_public_token(Config.t(), keyword()) ::
          {:ok, %{public_token: String.t()}} | {:error, Error.t()}
  def create_public_token(%Config{} = config, opts \\ []) do
    body = %{
      "institution_id" => Keyword.get(opts, :institution_id, "ins_109508"),
      "initial_products" => Keyword.get(opts, :initial_products, ["transactions"]),
      "options" => Keyword.get(opts, :options, %{})
    }

    case Client.post("/sandbox/public_token/create", body, config, opts) do
      {:ok, raw} -> {:ok, %{public_token: raw["public_token"], request_id: raw["request_id"]}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Fires a webhook for a sandbox Item.

  ## Example

      PlaidEx.API.Sandbox.fire_webhook(config,
        access_token: "access-sandbox-...",
        webhook_type: "TRANSACTIONS",
        webhook_code: "SYNC_UPDATES_AVAILABLE"
      )
  """
  @spec fire_webhook(Config.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def fire_webhook(%Config{} = config, opts) do
    body = %{
      "access_token" => Keyword.fetch!(opts, :access_token),
      "webhook_type" => Keyword.fetch!(opts, :webhook_type),
      "webhook_code" => Keyword.fetch!(opts, :webhook_code),
      "override_fields" => Keyword.get(opts, :override_fields, %{})
    }

    Client.post("/sandbox/item/fire_webhook", body, config, opts)
  end

  @doc "Sets an Item into a specific verification state for testing error handling."
  @spec set_item_verification_status(Config.t(), String.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  @spec set_item_verification_status(Config.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def set_item_verification_status(
        %Config{} = config,
        access_token,
        account_id,
        verification_status,
        opts \\ []
      ) do
    Client.post(
      "/sandbox/item/set_verification_status",
      %{
        "access_token" => access_token,
        "account_id" => account_id,
        "verification_status" => verification_status
      },
      config,
      opts
    )
  end

  @doc "Resets an Item's login state to trigger ITEM_LOGIN_REQUIRED."
  @spec reset_login(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec reset_login(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def reset_login(%Config{} = config, access_token, opts \\ []) do
    Client.post("/sandbox/item/reset_login", %{"access_token" => access_token}, config, opts)
  end

  @doc "Simulates a transfer event in sandbox."
  @spec simulate_transfer_event(Config.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  @spec simulate_transfer_event(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def simulate_transfer_event(%Config{} = config, transfer_id, event_type, opts \\ []) do
    Client.post(
      "/sandbox/transfer/simulate",
      %{"transfer_id" => transfer_id, "event_type" => event_type},
      config,
      opts
    )
  end

  @doc "Creates a test bank transfer in sandbox."
  @spec create_bank_transfer(Config.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  @spec create_bank_transfer(Config.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def create_bank_transfer(%Config{} = config, params, opts \\ []) do
    Client.post("/sandbox/bank_transfer/simulate", params, config, opts)
  end

  @doc "Returns a list of available test usernames for sandbox."
  @spec test_usernames() :: [%{username: String.t(), description: String.t()}]
  def test_usernames do
    [
      %{username: "user_good", description: "Returns all products successfully"},
      %{username: "user_bad", description: "Always returns INVALID_CREDENTIALS"},
      %{username: "user_retirement", description: "Has retirement investment accounts"},
      %{username: "user_no_accounts", description: "No accounts available"},
      %{username: "user_custom_1", description: "Customizable via override_accounts"},
      %{username: "user_itin", description: "Has ITIN instead of SSN"},
      %{username: "user_good_mfa_optional", description: "MFA is optional"},
      %{username: "user_tartan", description: "Legacy test user"}
    ]
  end
end
