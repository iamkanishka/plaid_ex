defmodule PlaidEx.Webhooks.Handler do
  @moduledoc """
  Behaviour for Plaid webhook handlers.

  Implement this in your application to receive typed webhook events.
  All callbacks are optional — unimplemented ones fall through to
  `on_unknown/1` which has a default no-op implementation.

  ## Example

      defmodule MyApp.PlaidWebhooks do
        @behaviour PlaidEx.Webhooks.Handler

        @impl true
        def on_transactions_sync(%{item_id: item_id}) do
          # Triggered by TRANSACTIONS.SYNC_UPDATES_AVAILABLE
          # Trigger your sync worker to fetch new data
          PlaidEx.Sync.TransactionSync.trigger_sync(
            MyApp.Items.get_access_token!(item_id)
          )
          :ok
        end

        @impl true
        def on_item_error(%{item_id: item_id, error: error}) do
          case error["error_code"] do
            "ITEM_LOGIN_REQUIRED" ->
              MyApp.Users.notify_reconnect_required(item_id)
            _ ->
              MyApp.Alerts.notify_item_error(item_id, error)
          end
          :ok
        end

        @impl true
        def on_item_pending_expiration(%{item_id: item_id}) do
          # Item will expire in 7 days — notify user to reconnect
          MyApp.Users.notify_expiring_connection(item_id)
          :ok
        end

        @impl true
        def on_transfer_events_update(_event) do
          MyApp.Transfers.sync_events()
          :ok
        end

        # Catch-all for events you haven't handled yet
        @impl true
        def on_unknown(event) do
          require Logger
          Logger.debug("[PlaidWebhooks] Unhandled: \#{inspect(event)}")
          :ok
        end
      end
  """

  @type event :: map() | struct()
  @type result :: :ok | {:error, term()}

  # ── Transactions ─────────────────────────────────────────────────────────────

  @callback on_transactions_sync(event()) :: result()
  @callback on_transactions_initial_update(event()) :: result()
  @callback on_transactions_historical_update(event()) :: result()
  @callback on_transactions_default_update(event()) :: result()

  # ── Items ────────────────────────────────────────────────────────────────────

  @callback on_item_error(event()) :: result()
  @callback on_item_pending_expiration(event()) :: result()
  @callback on_item_permission_revoked(event()) :: result()
  @callback on_item_new_accounts(event()) :: result()

  # ── Auth ─────────────────────────────────────────────────────────────────────

  @callback on_auth_automatically_verified(event()) :: result()
  @callback on_auth_verification_expired(event()) :: result()

  # ── Transfers ────────────────────────────────────────────────────────────────

  @callback on_transfer_events_update(event()) :: result()

  # ── Payments ─────────────────────────────────────────────────────────────────

  @callback on_payment_status_update(event()) :: result()

  # ── Identity Verification ─────────────────────────────────────────────────────

  @callback on_identity_verification_status_updated(event()) :: result()
  @callback on_identity_verification_retried(event()) :: result()

  # ── Income ───────────────────────────────────────────────────────────────────

  @callback on_income_verification(event()) :: result()

  # ── Investments ───────────────────────────────────────────────────────────────

  @callback on_investments_default_update(event()) :: result()

  # ── Liabilities ───────────────────────────────────────────────────────────────

  @callback on_liabilities_default_update(event()) :: result()

  # ── Assets ───────────────────────────────────────────────────────────────────

  @callback on_assets_product_ready(event()) :: result()
  @callback on_assets_error(event()) :: result()

  # ── Beacon ───────────────────────────────────────────────────────────────────

  @callback on_beacon_user_review_status_updated(event()) :: result()

  # ── Signal ───────────────────────────────────────────────────────────────────

  @callback on_signal_default_update(event()) :: result()

  # ── Statements ───────────────────────────────────────────────────────────────

  @callback on_statements_ready(event()) :: result()

  # ── Catch-all ─────────────────────────────────────────────────────────────────

  @callback on_unknown(event()) :: result()

  @callback_names [
    :on_transactions_sync,
    :on_transactions_initial_update,
    :on_transactions_historical_update,
    :on_transactions_default_update,
    :on_item_error,
    :on_item_pending_expiration,
    :on_item_permission_revoked,
    :on_item_new_accounts,
    :on_auth_automatically_verified,
    :on_auth_verification_expired,
    :on_transfer_events_update,
    :on_payment_status_update,
    :on_identity_verification_status_updated,
    :on_identity_verification_retried,
    :on_income_verification,
    :on_investments_default_update,
    :on_liabilities_default_update,
    :on_assets_product_ready,
    :on_assets_error,
    :on_beacon_user_review_status_updated,
    :on_signal_default_update,
    :on_statements_ready,
    :on_unknown
  ]

  @optional_callbacks Enum.map(@callback_names, &{&1, 1})

  @doc """
  Injects default no-op implementations for all optional callbacks.
  Use this when you only want to handle a subset of events.

      defmodule MyApp.PlaidWebhooks do
        use PlaidEx.Webhooks.Handler

        @impl true
        def on_transactions_sync(event) do
          # Only this one is custom — all others are no-ops
          trigger_my_sync(event.item_id)
          :ok
        end
      end
  """
  defmacro __using__(_) do
    default_impls =
      for name <- @callback_names do
        quote do
          def unquote(name)(_), do: :ok
        end
      end

    quote do
      @behaviour PlaidEx.Webhooks.Handler

      # Default no-op implementations, generated from @callback_names
      # above so this list only has to be maintained in one place.
      unquote_splicing(default_impls)

      defoverridable unquote(Enum.map(@callback_names, &{&1, 1}))
    end
  end
end
