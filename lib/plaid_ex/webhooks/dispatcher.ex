# This module routes every webhook type to its schema and handler callback —
# the dependency count reflects webhook type coverage, not incidental coupling.
# credo:disable-for-this-file Credo.Check.Refactor.ModuleDependencies
defmodule PlaidEx.Webhooks.Dispatcher do
  @moduledoc """
  Routes typed webhook events to handler callbacks.

  Dispatches based on `webhook_type` + `webhook_code` pairs, casting
  raw JSON maps to typed event structs before calling your handler.

  ## Supported events

  ### Transactions
  - `SYNC_UPDATES_AVAILABLE` → `on_transactions_sync/1`
  - `INITIAL_UPDATE` → `on_transactions_initial_update/1`
  - `HISTORICAL_UPDATE` → `on_transactions_historical_update/1`
  - `DEFAULT_UPDATE` → `on_transactions_default_update/1` (legacy)

  ### Items
  - `ERROR` → `on_item_error/1`
  - `PENDING_EXPIRATION` → `on_item_pending_expiration/1`
  - `USER_PERMISSION_REVOKED` → `on_item_permission_revoked/1`
  - `NEW_ACCOUNTS_AVAILABLE` → `on_item_new_accounts/1`

  ### Auth
  - `AUTOMATICALLY_VERIFIED` → `on_auth_automatically_verified/1`
  - `VERIFICATION_EXPIRED` → `on_auth_verification_expired/1`

  ### Transfers
  - `TRANSFER_EVENTS_UPDATE` → `on_transfer_events_update/1`

  ### Payment Initiation
  - `PAYMENT_STATUS_UPDATE` → `on_payment_status_update/1`

  ### Identity Verification
  - `STATUS_UPDATED` → `on_identity_verification_status_updated/1`
  - `RETRIED` → `on_identity_verification_retried/1`

  ### Income
  - `INCOME_VERIFICATION` → `on_income_verification/1`

  ### Investments
  - `DEFAULT_UPDATE` → `on_investments_default_update/1`

  ### Liabilities
  - `DEFAULT_UPDATE` → `on_liabilities_default_update/1`

  ### Assets
  - `PRODUCT_READY` → `on_assets_product_ready/1`
  - `ERROR` → `on_assets_error/1`

  ### Beacon
  - `USER_REVIEW_STATUS_UPDATED` → `on_beacon_user_review_status_updated/1`

  ### Signal
  - `DEFAULT_UPDATE` → `on_signal_default_update/1`

  ### Statements
  - `READY` → `on_statements_ready/1`
  """

  require Logger

  alias PlaidEx.Support.HandlerResult
  alias PlaidEx.Webhooks.Schemas

  # ── Webhook routing table ────────────────────────────────────────────────────

  @routes %{
    {"TRANSACTIONS", "SYNC_UPDATES_AVAILABLE"} =>
      {:on_transactions_sync, &Schemas.TransactionsSyncEvent.from_map/1},
    {"TRANSACTIONS", "INITIAL_UPDATE"} =>
      {:on_transactions_initial_update, &Schemas.TransactionsEvent.from_map/1},
    {"TRANSACTIONS", "HISTORICAL_UPDATE"} =>
      {:on_transactions_historical_update, &Schemas.TransactionsEvent.from_map/1},
    {"TRANSACTIONS", "DEFAULT_UPDATE"} =>
      {:on_transactions_default_update, &Schemas.TransactionsEvent.from_map/1},
    {"ITEM", "ERROR"} => {:on_item_error, &Schemas.ItemErrorEvent.from_map/1},
    {"ITEM", "PENDING_EXPIRATION"} =>
      {:on_item_pending_expiration, &Schemas.ItemEvent.from_map/1},
    {"ITEM", "USER_PERMISSION_REVOKED"} =>
      {:on_item_permission_revoked, &Schemas.ItemEvent.from_map/1},
    {"ITEM", "NEW_ACCOUNTS_AVAILABLE"} => {:on_item_new_accounts, &Schemas.ItemEvent.from_map/1},
    {"AUTH", "AUTOMATICALLY_VERIFIED"} =>
      {:on_auth_automatically_verified, &Schemas.AuthEvent.from_map/1},
    {"AUTH", "VERIFICATION_EXPIRED"} =>
      {:on_auth_verification_expired, &Schemas.AuthEvent.from_map/1},
    {"TRANSFER", "TRANSFER_EVENTS_UPDATE"} =>
      {:on_transfer_events_update, &Schemas.TransferEvent.from_map/1},
    {"PAYMENT_INITIATION", "PAYMENT_STATUS_UPDATE"} =>
      {:on_payment_status_update, &Schemas.PaymentStatusEvent.from_map/1},
    {"IDENTITY_VERIFICATION", "STATUS_UPDATED"} =>
      {:on_identity_verification_status_updated, &Schemas.IdentityVerificationEvent.from_map/1},
    {"IDENTITY_VERIFICATION", "RETRIED"} =>
      {:on_identity_verification_retried, &Schemas.IdentityVerificationEvent.from_map/1},
    {"INCOME", "INCOME_VERIFICATION"} =>
      {:on_income_verification, &Schemas.IncomeEvent.from_map/1},
    {"INVESTMENTS_TRANSACTIONS", "DEFAULT_UPDATE"} =>
      {:on_investments_default_update, &Schemas.InvestmentsEvent.from_map/1},
    {"LIABILITIES", "DEFAULT_UPDATE"} =>
      {:on_liabilities_default_update, &Schemas.LiabilitiesEvent.from_map/1},
    {"ASSETS", "PRODUCT_READY"} => {:on_assets_product_ready, &Schemas.AssetsEvent.from_map/1},
    {"ASSETS", "ERROR"} => {:on_assets_error, &Schemas.AssetsEvent.from_map/1},
    {"BEACON", "USER_REVIEW_STATUS_UPDATED"} =>
      {:on_beacon_user_review_status_updated, &Schemas.BeaconEvent.from_map/1},
    {"SIGNAL", "DEFAULT_UPDATE"} => {:on_signal_default_update, &Schemas.SignalEvent.from_map/1},
    {"STATEMENTS", "READY"} => {:on_statements_ready, &Schemas.StatementsEvent.from_map/1}
  }

  @doc """
  Dispatches a raw webhook event map to the appropriate handler callback.

  The handler module must implement `PlaidEx.Webhooks.Handler`.
  """
  @spec dispatch(map(), module() | function(), PlaidEx.Config.t()) :: :ok | {:error, term()}
  def dispatch(raw_event, handler, config) do
    type_key = {raw_event["webhook_type"], raw_event["webhook_code"]}

    start_time = System.monotonic_time()

    result =
      case Map.get(@routes, type_key) do
        {callback, caster} ->
          typed_event = safe_cast(caster, raw_event)
          invoke_handler(handler, callback, typed_event)

        nil ->
          invoke_handler(handler, :on_unknown, raw_event)
      end

    duration_ms =
      System.convert_time_unit(System.monotonic_time() - start_time, :native, :millisecond)

    :telemetry.execute(
      [:plaid_ex, :webhook, :dispatch],
      %{duration_ms: duration_ms},
      %{
        webhook_type: raw_event["webhook_type"],
        webhook_code: raw_event["webhook_code"],
        item_id: raw_event["item_id"],
        tenant_id: config.tenant_id,
        success: result == :ok
      }
    )

    result
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp safe_cast(caster, raw_event) do
    try do
      caster.(raw_event)
    rescue
      e ->
        Logger.warning("[PlaidEx.Dispatcher] Failed to cast event: #{Exception.message(e)}")
        raw_event
    end
  end

  defp invoke_handler(handler, callback, event) when is_atom(handler) do
    if function_exported?(handler, callback, 1) do
      try do
        raw_result = apply(handler, callback, [event])
        HandlerResult.normalize(raw_result)
      rescue
        e ->
          Logger.error(
            "[PlaidEx.Dispatcher] Handler #{handler}.#{callback}/1 raised: #{Exception.message(e)}"
          )

          {:error, {:handler_exception, Exception.message(e)}}
      end
    else
      # Fall back to on_unknown if the specific callback isn't implemented
      if function_exported?(handler, :on_unknown, 1) do
        apply(handler, :on_unknown, [event])
      else
        Logger.debug(
          "[PlaidEx.Dispatcher] Handler #{handler} has no #{callback}/1 or on_unknown/1"
        )

        :ok
      end
    end
  end

  defp invoke_handler(handler, _, event) when is_function(handler, 1) do
    try do
      handler.(event)
    rescue
      e ->
        Logger.error("[PlaidEx.Dispatcher] Handler function raised: #{Exception.message(e)}")
        {:error, {:handler_exception, Exception.message(e)}}
    end
  end
end
