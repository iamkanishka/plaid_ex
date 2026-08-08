# Webhooks

Plaid delivers webhooks for every significant event — new transactions,
item errors, transfer completions, identity verification results, and more.
PlaidEx provides a complete webhook infrastructure: signature verification,
deduplication, typed event structs, and durable processing via Oban.

## Architecture

```
Plaid → POST /webhooks/plaid
          │
          ▼
  PlaidEx.Webhooks.Plug
    1. Read raw body (for signature verification)
    2. Verify Plaid-Verification header
    3. Parse JSON to typed event struct
    4. ETS deduplication check
    5. Respond 200 OK immediately ◄── Plaid requires < 5s response
    6. Dispatch async via Task.Supervisor or Oban
          │
          ▼
  PlaidEx.Webhooks.Dispatcher
    Routes by webhook_type + webhook_code
          │
          ▼
  YourApp.PlaidWebhookHandler
    Your business logic
```

## Setup

### Phoenix router

```elixir
# router.ex
pipeline :plaid_webhooks do
  plug :accepts, ["json"]
  # ⚠️ Do NOT add Plug.Parsers here — it consumes the raw body
  # PlaidEx.Webhooks.Plug reads the raw body for signature verification
end

scope "/webhooks" do
  pipe_through :plaid_webhooks
  forward "/plaid", PlaidEx.Webhooks.Plug,
    config: Application.fetch_env!(:my_app, :plaid_config),
    handler: MyApp.PlaidWebhooks,
    max_body_bytes: 2_000_000   # optional, default 2MB
end
```

### Handler module

```elixir
defmodule MyApp.PlaidWebhooks do
  # use provides default no-op implementations for all callbacks
  use PlaidEx.Webhooks.Handler

  # ── Transactions ──────────────────────────────────────────────────────────

  @impl true
  def on_transactions_sync(%PlaidEx.Webhooks.Schemas.TransactionsSyncEvent{} = event) do
    # New transaction data is available for this item.
    # Trigger your sync worker — don't do heavy work inline.
    # The webhook must return quickly.
    case MyApp.PlaidItems.get_by_item_id(event.item_id) do
      nil -> :ok
      item ->
        PlaidEx.trigger_transaction_sync(decrypt!(item.access_token))
        :ok
    end
  end

  # ── Items ─────────────────────────────────────────────────────────────────

  @impl true
  def on_item_error(%PlaidEx.Webhooks.Schemas.ItemErrorEvent{} = event) do
    MyApp.PlaidItems.mark_error(event.item_id, event.error["error_code"])

    case event.error["error_code"] do
      "ITEM_LOGIN_REQUIRED" ->
        # User must re-authenticate via Link update mode
        MyApp.Notifications.send_reconnect_email(event.item_id)

      "NO_ACCOUNTS" ->
        # No accounts returned — unusual, may need investigation
        MyApp.Alerts.notify(:no_accounts, event.item_id)

      error_code ->
        MyApp.Alerts.pagerduty("Plaid item error: #{error_code}", event)
    end

    :ok
  end

  @impl true
  def on_item_pending_expiration(%PlaidEx.Webhooks.Schemas.ItemEvent{} = event) do
    # Item will expire in ~7 days — user should reconnect
    MyApp.Notifications.send_expiry_warning(
      event.item_id,
      expiration: event.consent_expiration_time
    )
    :ok
  end

  @impl true
  def on_item_permission_revoked(%{item_id: item_id}) do
    # User revoked access from their bank's website
    MyApp.PlaidItems.mark_revoked(item_id)
    MyApp.Notifications.notify_access_revoked(item_id)
    :ok
  end

  # ── Auth ──────────────────────────────────────────────────────────────────

  @impl true
  def on_auth_automatically_verified(%{item_id: item_id, account_id: account_id}) do
    # Micro-deposit verification completed automatically
    MyApp.Accounts.mark_verified(account_id)
    :ok
  end

  @impl true
  def on_auth_verification_expired(%{item_id: item_id, account_id: account_id}) do
    # Micro-deposit window expired — user needs to restart verification
    MyApp.Notifications.send_verification_expired(account_id)
    :ok
  end

  # ── Transfers ─────────────────────────────────────────────────────────────

  @impl true
  def on_transfer_events_update(_event) do
    # New transfer events available — sync them
    MyApp.Transfers.sync_events_async()
    :ok
  end

  # ── Investments ───────────────────────────────────────────────────────────

  @impl true
  def on_investments_default_update(%{item_id: item_id}) do
    # New investment data available
    MyApp.Investments.schedule_refresh(item_id)
    :ok
  end

  # ── Assets ────────────────────────────────────────────────────────────────

  @impl true
  def on_assets_product_ready(%{asset_report_id: report_id}) do
    # Asset report generation complete — fetch and store
    MyApp.AssetReports.fetch_and_store(report_id)
    :ok
  end

  @impl true
  def on_assets_error(%{asset_report_id: report_id, error: error}) do
    MyApp.AssetReports.mark_failed(report_id, error)
    :ok
  end

  # ── Catch-all ─────────────────────────────────────────────────────────────

  @impl true
  def on_unknown(event) do
    require Logger
    Logger.info("[PlaidWebhooks] Unhandled event",
      webhook_type: event["webhook_type"],
      webhook_code: event["webhook_code"]
    )
    :ok
  end
end
```

## Signature verification

PlaidEx verifies the `Plaid-Verification` header on every request.

### Get your webhook secret

1. Go to [Plaid Dashboard → Webhooks](https://dashboard.plaid.com/webhooks)
2. Create or view your webhook configuration
3. Copy the webhook secret

### Configure it

```elixir
# config/runtime.exs
config :plaid_ex,
  webhook_secret: System.fetch_env!("PLAID_WEBHOOK_SECRET")
```

### Verification flow

Plaid signs webhooks using HMAC-SHA256 (older config) or JWT (newer config).
PlaidEx detects the format automatically and verifies accordingly.

**Never disable signature verification in production.** Without it, anyone
can POST arbitrary webhooks to your endpoint.

To test locally without a real secret:

```elixir
# config/dev.exs
config :plaid_ex, webhook_secret: nil  # skips verification in dev
```

## Deduplication

Plaid uses at-least-once delivery — the same webhook may arrive twice.
PlaidEx automatically deduplicates using a 1-hour sliding ETS window.

Duplicate webhooks receive a `200 OK` response (Plaid won't retry them)
but are silently discarded before reaching your handler.

### How IDs are derived

Plaid doesn't include a unique webhook ID in all events. PlaidEx derives
a dedup key from:

```
SHA256(webhook_type + ":" + webhook_code + ":" + item_id + ":" + quantized_timestamp)
```

Timestamps are quantized to 5-second windows, so re-deliveries within
5 seconds of each other are deduplicated. Re-deliveries after 5 seconds
are treated as distinct events (rare in practice).

## Durable processing with Oban

For production systems where webhook processing must survive application restarts:

```elixir
# mix.exs
{:oban, "~> 2.18"}

# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [plaid_webhooks: 10],
  plugins: [
    {Oban.Plugins.Pruner, max_age: :timer.hours(24 * 7)},
    {Oban.Plugins.Stager, interval: 1_000}
  ]

# config/config.exs
config :plaid_ex,
  oban_queue: :plaid_webhooks,
  oban_max_attempts: 10,
  webhook_handler: MyApp.PlaidWebhooks  # used by ObanWorker
```

With Oban enabled:
1. Plug receives webhook, responds `200 OK` in < 100ms
2. Raw event is enqueued as an Oban job
3. Oban worker processes it (with retry on failure)
4. Failed jobs land in the dead-letter queue for inspection

### Oban Web for webhook visibility

With [Oban Web](https://getoban.pro/web), you can:
- See all pending and failed webhook jobs
- Retry individual failed jobs
- Inspect job args (raw event payload)
- Monitor queue throughput

## Testing webhooks

### Local testing with ngrok

```bash
ngrok http 4000
# Copy the https URL, e.g., https://abc123.ngrok.io

# Set in Plaid Dashboard → Webhooks:
# https://abc123.ngrok.io/webhooks/plaid
```

### Fire test webhooks from sandbox

```elixir
# Trigger a SYNC_UPDATES_AVAILABLE webhook
PlaidEx.API.Sandbox.fire_webhook(config,
  access_token: "access-sandbox-...",
  webhook_type: "TRANSACTIONS",
  webhook_code: "SYNC_UPDATES_AVAILABLE"
)

# Trigger an ITEM error
PlaidEx.API.Sandbox.fire_webhook(config,
  access_token: "access-sandbox-...",
  webhook_type: "ITEM",
  webhook_code: "ERROR"
)
```

### Unit testing your handler

```elixir
defmodule MyApp.PlaidWebhooksTest do
  use ExUnit.Case, async: true

  alias PlaidEx.Webhooks.Schemas

  test "on_transactions_sync triggers sync" do
    # Use the test helper to build a typed event
    event = %Schemas.TransactionsSyncEvent{
      webhook_type: "TRANSACTIONS",
      webhook_code: "SYNC_UPDATES_AVAILABLE",
      item_id: "item-test-123",
      environment: "sandbox",
      initial_update_complete: true,
      historical_update_complete: true
    }

    # Call handler directly — no HTTP needed
    assert :ok = MyApp.PlaidWebhooks.on_transactions_sync(event)
  end
end
```

### Integration testing the Plug

```elixir
defmodule MyApp.WebhookPlugTest do
  use MyAppWeb.ConnCase

  alias PlaidEx.Test.MockPlaidServer

  test "accepts valid webhook and returns 200" do
    event = MockPlaidServer.build_webhook("TRANSACTIONS", "SYNC_UPDATES_AVAILABLE",
      item_id: "item-test-123"
    )

    conn =
      conn(:post, "/webhooks/plaid", Jason.encode!(event))
      |> put_req_header("content-type", "application/json")
      |> MyAppWeb.Endpoint.call([])

    assert conn.status == 200
  end

  test "rejects webhook with invalid signature" do
    event = MockPlaidServer.build_webhook("TRANSACTIONS", "SYNC_UPDATES_AVAILABLE")
    body = Jason.encode!(event)

    conn =
      conn(:post, "/webhooks/plaid", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("plaid-verification", "invalid_signature_here")
      |> MyAppWeb.Endpoint.call([])

    assert conn.status == 401
  end

  test "deduplicates repeated webhooks" do
    config = PlaidEx.Config.new!(client_id: "c", secret: "s", webhook_secret: "test_secret")

    event = MockPlaidServer.build_webhook("ITEM", "ERROR", item_id: "item-dup")
    {body, signature} = MockPlaidServer.build_signed_webhook(event, "test_secret")

    # First delivery
    conn1 =
      conn(:post, "/webhooks/plaid", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("plaid-verification", signature)
      |> MyAppWeb.Endpoint.call([])

    assert conn1.status == 200

    # Second delivery — same payload within 5s
    conn2 =
      conn(:post, "/webhooks/plaid", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("plaid-verification", signature)
      |> MyAppWeb.Endpoint.call([])

    # Still 200 (don't cause Plaid to retry) but deduplicated
    assert conn2.status == 200
  end
end
```

## Webhook event reference

| webhook_type | webhook_code | Handler callback | Trigger |
|---|---|---|---|
| TRANSACTIONS | SYNC_UPDATES_AVAILABLE | `on_transactions_sync/1` | New transaction data available |
| TRANSACTIONS | INITIAL_UPDATE | `on_transactions_initial_update/1` | Initial data loaded (legacy) |
| TRANSACTIONS | HISTORICAL_UPDATE | `on_transactions_historical_update/1` | Historical data loaded (legacy) |
| ITEM | ERROR | `on_item_error/1` | Item entered error state |
| ITEM | PENDING_EXPIRATION | `on_item_pending_expiration/1` | Item expires in ~7 days |
| ITEM | USER_PERMISSION_REVOKED | `on_item_permission_revoked/1` | User revoked bank access |
| ITEM | NEW_ACCOUNTS_AVAILABLE | `on_item_new_accounts/1` | New accounts detected at institution |
| AUTH | AUTOMATICALLY_VERIFIED | `on_auth_automatically_verified/1` | Micro-deposit auto-verified |
| AUTH | VERIFICATION_EXPIRED | `on_auth_verification_expired/1` | Micro-deposit window expired |
| TRANSFER | TRANSFER_EVENTS_UPDATE | `on_transfer_events_update/1` | Transfer status changed |
| PAYMENT_INITIATION | PAYMENT_STATUS_UPDATE | `on_payment_status_update/1` | Payment status changed |
| IDENTITY_VERIFICATION | STATUS_UPDATED | `on_identity_verification_status_updated/1` | KYC status changed |
| INCOME | INCOME_VERIFICATION | `on_income_verification/1` | Income verification complete |
| INVESTMENTS_TRANSACTIONS | DEFAULT_UPDATE | `on_investments_default_update/1` | New investment data |
| LIABILITIES | DEFAULT_UPDATE | `on_liabilities_default_update/1` | Liability data updated |
| ASSETS | PRODUCT_READY | `on_assets_product_ready/1` | Asset report ready |
| ASSETS | ERROR | `on_assets_error/1` | Asset report generation failed |
| BEACON | USER_REVIEW_STATUS_UPDATED | `on_beacon_user_review_status_updated/1` | Beacon review status changed |
| SIGNAL | DEFAULT_UPDATE | `on_signal_default_update/1` | Signal data updated |
| STATEMENTS | READY | `on_statements_ready/1` | Statement available |

## Operational considerations

### Respond quickly

Plaid expects a `2xx` response within **10 seconds** (ideally < 1 second).
PlaidEx responds immediately and dispatches processing asynchronously.
Never do database queries, HTTP calls, or heavy computation inline.

### Handle failures gracefully

With Oban: failed handlers are retried automatically with backoff.
Without Oban: failed handlers are logged and silently dropped (use Oban for production).

### Monitor your webhook health

```bash
# Check Oban queue depth
MyApp.Repo.one(from j in Oban.Job, where: j.queue == "plaid_webhooks" and j.state == "available", select: count())

# Check for stuck/failed jobs
MyApp.Repo.all(from j in Oban.Job, where: j.queue == "plaid_webhooks" and j.state == "discarded")
```

### Set up a webhook URL in Plaid Dashboard

1. Go to [Plaid Dashboard → API → Webhooks](https://dashboard.plaid.com/webhooks)
2. Add your production URL: `https://yourapp.com/webhooks/plaid`
3. Copy the webhook secret and add it to your config

### Per-item webhook override

Plaid also supports per-item webhook URLs set at item creation time:

```elixir
PlaidEx.create_link_token(
  user: %{client_user_id: user_id},
  products: ["transactions"],
  country_codes: ["US"],
  language: "en",
  webhook: "https://yourapp.com/webhooks/plaid/#{tenant_id}"  # per-tenant
)
```
