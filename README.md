# PlaidEx

[![Hex.pm](https://img.shields.io/hexpm/v/plaid_ex.svg)](https://hex.pm/packages/plaid_ex)
[![Docs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/plaid_ex)
[![CI](https://github.com/iamkanishka/plaid_ex/actions/workflows/ci.yml/badge.svg)](https://github.com/iamkanishka/plaid_ex/actions)
[![Coverage](https://coveralls.io/repos/github/iamkanishka/plaid_ex/badge.svg?branch=main)](https://coveralls.io/github/iamkanishka/plaid_ex)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

**Production-grade Plaid API client for Elixir/OTP.**

PlaidEx is not a REST wrapper. It is fintech infrastructure — built for enterprise
production workloads, multi-tenant SaaS platforms, embedded finance systems, and
high-scale data pipelines.

---

## Why PlaidEx?

Most Plaid clients for Elixir are thin HTTP wrappers. PlaidEx is an OTP application
that solves the hard problems:

| Problem | PlaidEx solution |
|---------|-----------------|
| Plaid webhooks arrive out of order and are re-delivered | ETS deduplication window + typed event routing |
| Transaction sync cursors must survive process crashes | Pluggable `CursorStore` behaviour — swap in Ecto, Redis, etc. |
| Institution outages cause cascading failures | Per-environment GenServer circuit breakers |
| Multi-tenant SaaS needs credential isolation | `TenantRegistry` + per-tenant rate limiting + `DynamicSupervisor` subtrees |
| `ITEM_LOGIN_REQUIRED` silently breaks syncs | Worker pauses and emits telemetry — you get notified, not surprised |
| Retries on shared connections cause thundering herds | Full jitter backoff — never synchronized |
| Webhook signature verification is subtle | Constant-time HMAC comparison + JWT verification |
| Sync workers need observability | 14 telemetry events, OpenTelemetry spans, structured logs |

---

## Installation

```elixir
# mix.exs
def deps do
  [
    {:plaid_ex, "~> 1.0"},

    # Optional — for durable webhook processing
    {:oban, "~> 2.18"},

    # Optional — for high-throughput sync pipelines
    {:broadway, "~> 1.1"},
    {:gen_stage, "~> 1.2"},

    # Optional — for distributed caching
    {:nebulex, "~> 2.6"}
  ]
end
```

---

## Quick start

### 1. Configure

```elixir
# config/runtime.exs
config :plaid_ex,
  client_id: System.fetch_env!("PLAID_CLIENT_ID"),
  secret: System.fetch_env!("PLAID_SECRET"),
  environment: :sandbox,         # :sandbox | :development | :production
  region: :us,                   # :us | :eu | :uk
  webhook_secret: System.get_env("PLAID_WEBHOOK_SECRET")
```

### 2. Create a Link token

```elixir
# Server-side only — never expose client_id/secret to the browser
{:ok, link} = PlaidEx.create_link_token(
  user: %{client_user_id: current_user.id},
  client_name: "Acme Finance",
  products: ["transactions"],
  country_codes: ["US"],
  language: "en",
  webhook: "https://yourapp.com/webhooks/plaid"
)

# Pass link.link_token to your frontend Link SDK
```

### 3. Exchange the public token

```elixir
# Called from your frontend callback handler
{:ok, result} = PlaidEx.exchange_public_token(params["public_token"])

# Store permanently — access_token and item_id are your permanent credentials
MyApp.Repo.insert!(%PlaidItem{
  item_id: result.item_id,
  access_token: result.access_token,  # encrypt at rest
  user_id: current_user.id
})
```

### 4. Start transaction sync

```elixir
{:ok, _pid} = PlaidEx.start_transaction_sync(item.access_token,
  handler: fn page ->
    # page is %PlaidEx.Schemas.TransactionSyncPage{}
    MyApp.Transactions.upsert_batch(page.added)
    MyApp.Transactions.update_batch(page.modified)
    MyApp.Transactions.remove_batch(Enum.map(page.removed, & &1.transaction_id))
    :ok
  end
)
```

### 5. Handle webhooks

```elixir
# router.ex
forward "/webhooks/plaid", PlaidEx.Webhooks.Plug,
  config: PlaidEx.Config.load!(),
  handler: MyApp.PlaidWebhooks

# lib/my_app/plaid_webhooks.ex
defmodule MyApp.PlaidWebhooks do
  use PlaidEx.Webhooks.Handler

  @impl true
  def on_transactions_sync(%{item_id: item_id}) do
    item = MyApp.Items.get_by_item_id!(item_id)
    PlaidEx.trigger_transaction_sync(item.access_token)
    :ok
  end

  @impl true
  def on_item_error(%{item_id: item_id, error: %{"error_code" => "ITEM_LOGIN_REQUIRED"}}) do
    MyApp.Users.notify_reconnect_required(item_id)
    :ok
  end
end
```

---

## API coverage

### Core products

```elixir
# Link
PlaidEx.API.Link.create_token(config, params)
PlaidEx.API.Link.get_token(config, link_token)

# Items
PlaidEx.API.Items.exchange_public_token(config, public_token)
PlaidEx.API.Items.get(config, access_token)
PlaidEx.API.Items.remove(config, access_token)
PlaidEx.API.Items.update_webhook(config, access_token, webhook_url)
PlaidEx.API.Items.invalidate_access_token(config, access_token)
PlaidEx.API.Items.create_processor_token(config, access_token, account_id, "dwolla")

# Accounts
PlaidEx.API.Accounts.get(config, access_token)
PlaidEx.API.Accounts.get_balance(config, access_token)

# Transactions (cursor-based sync)
PlaidEx.API.Transactions.sync(config, access_token: token, cursor: cursor)
PlaidEx.API.Transactions.get(config, access_token: token, start_date: "2024-01-01", end_date: "2024-01-31")
PlaidEx.API.Transactions.get_recurring(config, access_token: token)
PlaidEx.API.Transactions.enrich(config, transactions)
PlaidEx.API.Transactions.refresh(config, access_token)

# Auth
PlaidEx.API.Auth.get(config, access_token)

# Identity
PlaidEx.API.Identity.get(config, access_token)
PlaidEx.API.Identity.match(config, access_token, user_data)

# Investments
PlaidEx.API.Investments.get_holdings(config, access_token)
PlaidEx.API.Investments.get_transactions(config, access_token, start_date, end_date)
PlaidEx.API.Investments.refresh(config, access_token)

# Liabilities
PlaidEx.API.Liabilities.get(config, access_token)

# Statements
PlaidEx.API.Statements.list(config, access_token)
PlaidEx.API.Statements.download(config, access_token, statement_id)
PlaidEx.API.Statements.refresh(config, access_token)
```

### Transfer & payments

```elixir
# Signal (ACH return risk)
PlaidEx.API.Signal.evaluate(config, params)
PlaidEx.API.Signal.decision_report(config, client_transaction_id, initiated)
PlaidEx.API.Signal.return_report(config, client_transaction_id, return_code)
PlaidEx.API.Signal.prepare(config, access_token)

# Transfer
PlaidEx.API.Transfer.authorize(config, params)
PlaidEx.API.Transfer.create(config, params)
PlaidEx.API.Transfer.get(config, transfer_id)
PlaidEx.API.Transfer.cancel(config, transfer_id)
PlaidEx.API.Transfer.list(config)
PlaidEx.API.Transfer.get_events(config)
PlaidEx.API.Transfer.sync_events(config, after_id: last_event_id)
```

### Fraud, risk & compliance

```elixir
# Beacon (fraud network)
PlaidEx.API.Beacon.create_user(config, params)
PlaidEx.API.Beacon.get_user(config, beacon_user_id)
PlaidEx.API.Beacon.review_user(config, beacon_user_id, "approve")
PlaidEx.API.Beacon.create_report(config, params)
PlaidEx.API.Beacon.list_reports(config, beacon_user_id)

# Monitor (watchlist screening)
PlaidEx.API.Monitor.create_individual_screening(config, params)
PlaidEx.API.Monitor.get_individual_screening(config, screening_id)
PlaidEx.API.Monitor.list_individual_screenings(config)
PlaidEx.API.Monitor.create_entity_screening(config, params)
```

### Verification & assets

```elixir
# Assets
PlaidEx.API.Assets.create(config, access_tokens, days_requested: 90)
PlaidEx.API.Assets.get(config, asset_report_token)
PlaidEx.API.Assets.get_pdf(config, asset_report_token)
PlaidEx.API.Assets.filter(config, asset_report_token, account_ids_to_exclude)
PlaidEx.API.Assets.create_audit_copy(config, asset_report_token, auditor_id)

# Income
PlaidEx.API.Income.create_verification(config, params)
PlaidEx.API.Income.get_summary(config, verification_id)
PlaidEx.API.Income.get_payroll(config, verification_id)
```

### Institutions

```elixir
PlaidEx.API.Institutions.get(config, "ins_chase", ["US"])
PlaidEx.API.Institutions.list(config, count: 500, offset: 0)
PlaidEx.API.Institutions.search(config, "Chase", products: ["transactions"])
```

### Sandbox

```elixir
PlaidEx.API.Sandbox.create_public_token(config,
  institution_id: "ins_109508",
  initial_products: ["transactions"],
  options: %{override_username: "user_good"}
)
PlaidEx.API.Sandbox.fire_webhook(config,
  access_token: token,
  webhook_type: "TRANSACTIONS",
  webhook_code: "SYNC_UPDATES_AVAILABLE"
)
PlaidEx.API.Sandbox.reset_login(config, access_token)
PlaidEx.API.Sandbox.simulate_transfer_event(config, transfer_id, "posted")
```

---

## Transaction sync in depth

PlaidEx manages the complete `/transactions/sync` lifecycle automatically:

```elixir
{:ok, _pid} = PlaidEx.start_transaction_sync(access_token,
  handler: &MyApp.Transactions.process_page/1,

  # Optional: override poll interval (default: 30s)
  poll_interval_ms: 60_000,

  # Optional: for multi-tenant, pass the tenant_id
  tenant_id: "acme_corp"
)

# The worker handles all of this automatically:
# ✓ Cursor persistence (swap CursorStore backend for DB persistence)
# ✓ Pagination (has_more: true → fetch immediately, no sleep)
# ✓ ITEM_LOGIN_REQUIRED → pause worker + emit telemetry
# ✓ TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION → reset cursor + retry
# ✓ Institution outages → exponential backoff (5s → 10s → 20s → max 5min)
# ✓ Handler failures → retry same page (cursor not advanced)
# ✓ Worker crashes → restart from last persisted cursor
```

### Persistent cursors (production requirement)

The default ETS cursor store loses cursors on restart. For production,
implement `PlaidEx.Sync.CursorStore.Behaviour`:

```elixir
defmodule MyApp.PlaidCursorStore do
  @behaviour PlaidEx.Sync.CursorStore.Behaviour

  @impl true
  def get(access_token) do
    case MyApp.Repo.get_by(MyApp.PlaidItem, access_token: access_token) do
      nil -> nil
      item -> item.sync_cursor
    end
  end

  @impl true
  def put(access_token, cursor) do
    MyApp.Repo.update_all(
      from(i in MyApp.PlaidItem, where: i.access_token == ^access_token),
      set: [sync_cursor: cursor, cursor_updated_at: DateTime.utc_now()]
    )
    :ok
  end

  @impl true
  def delete(access_token) do
    MyApp.Repo.update_all(
      from(i in MyApp.PlaidItem, where: i.access_token == ^access_token),
      set: [sync_cursor: nil]
    )
    :ok
  end
end

# config/config.exs
config :plaid_ex, cursor_store: MyApp.PlaidCursorStore
```

---

## Multi-tenant setup

```elixir
# On tenant onboarding (e.g., after they enter Plaid credentials):
PlaidEx.register_tenant("acme_corp",
  PlaidEx.Config.new!(
    client_id: vault.get("acme/plaid/client_id"),
    secret: vault.get("acme/plaid/secret"),
    environment: :production,
    tenant_id: "acme_corp"
  )
)

# All API calls accept an explicit config:
{:ok, config} = PlaidEx.get_tenant_config("acme_corp")
{:ok, link_token} = PlaidEx.API.Link.create_token(config, params)

# Secret rotation (no restart required):
PlaidEx.rotate_tenant_secret("acme_corp", new_secret_from_vault)

# Tenant offboarding:
PlaidEx.Config.TenantRegistry.deregister("acme_corp")
```

---

## Webhook setup

### Phoenix router

```elixir
# router.ex
pipeline :plaid_webhooks do
  plug :accepts, ["json"]
  # IMPORTANT: Do NOT put Plug.Parsers before PlaidEx.Webhooks.Plug
  # It reads the raw body for signature verification
end

scope "/webhooks" do
  pipe_through :plaid_webhooks

  forward "/plaid", PlaidEx.Webhooks.Plug,
    config: Application.fetch_env!(:my_app, :plaid_config),
    handler: MyApp.PlaidWebhooks
end
```

### Handler

```elixir
defmodule MyApp.PlaidWebhooks do
  use PlaidEx.Webhooks.Handler  # provides default no-op implementations

  @impl true
  def on_transactions_sync(%PlaidEx.Webhooks.Schemas.TransactionsSyncEvent{} = event) do
    # Fired when new transaction data is available
    # Trigger your sync worker — don't process inline (webhook must return fast)
    PlaidEx.trigger_transaction_sync(
      MyApp.Items.get_access_token!(event.item_id)
    )
    :ok
  end

  @impl true
  def on_item_error(%PlaidEx.Webhooks.Schemas.ItemErrorEvent{} = event) do
    case event.error["error_code"] do
      "ITEM_LOGIN_REQUIRED" ->
        # User must reconnect via Link update mode
        MyApp.Notifications.send_reconnect_email(event.item_id)

      _ ->
        MyApp.Alerts.pagerduty(event)
    end
    :ok
  end

  @impl true
  def on_item_pending_expiration(%{item_id: item_id}) do
    # Item will expire in 7 days — nudge user to re-authenticate
    MyApp.Notifications.send_expiry_warning(item_id)
    :ok
  end

  @impl true
  def on_transfer_events_update(_event) do
    # Poll for new transfer events
    MyApp.Transfers.sync_events()
    :ok
  end
end
```

### Durable webhooks with Oban

```elixir
# mix.exs
{:oban, "~> 2.18"}

# config/config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [plaid_webhooks: 10],
  plugins: [Oban.Plugins.Pruner]

# config/config.exs
config :plaid_ex,
  oban_queue: :plaid_webhooks,
  oban_max_attempts: 10,
  webhook_handler: MyApp.PlaidWebhooks
```

With Oban, the Plug ACKs Plaid immediately and enqueues a job. If your handler
fails (e.g., DB down), Oban retries automatically with exponential backoff.

---

## Observability

### Telemetry events

```elixir
# Attach built-in structured logging:
PlaidEx.attach_telemetry(log_level: :info)

# Or attach your own handler:
:telemetry.attach_many("my_plaid_handler",
  PlaidEx.Telemetry.Handler.events(),
  fn
    [:plaid_ex, :http, :stop], _measurements, %{path: path, duration_ms: ms}, _ ->
      MyMetrics.histogram("plaid.http.latency", ms, tags: [path: path])

    [:plaid_ex, :circuit_breaker, :open], _, %{environment: env}, _ ->
      MyAlerts.page("Plaid circuit breaker opened for #{env}")

    _, _, _, _ -> :ok
  end,
  nil
)
```

### Telemetry.Metrics (Prometheus / StatsD)

```elixir
# In your Telemetry supervisor:
def metrics do
  PlaidEx.telemetry_metrics() ++ your_own_metrics()
end
```

Provides histograms, counters, and sums for:
- HTTP request latency (p50, p95, p99)
- HTTP error rates by error code
- Retry counts by path
- Sync pages/transactions processed
- Webhook dispatch latency
- Circuit breaker open/close events
- Rate limit throttle events

### OpenTelemetry

```elixir
# config/runtime.exs
config :opentelemetry,
  resource: [service: [name: "my-plaid-service"]],
  span_processor: :batch,
  traces_exporter: :otlp
```

Every HTTP request creates an OpenTelemetry span with:
- `plaid.product`, `plaid.endpoint`
- `plaid.environment`, `plaid.region`
- `plaid.tenant_id`
- Error details on failure

---

## Testing

```elixir
# mix.exs test deps
{:bypass, "~> 2.1", only: :test},
{:mox, "~> 1.2", only: :test}
```

### Bypass helpers

```elixir
defmodule MyApp.PlaidTest do
  use ExUnit.Case
  use PlaidEx.Test.BypassHelpers

  setup do
    bypass = Bypass.open()
    {:ok, bypass: bypass, config: test_config(bypass)}
  end

  test "syncs transactions", %{bypass: bypass, config: config} do
    stub_transactions_sync(bypass,
      response: transactions_sync_fixture(
        added: [transaction_fixture(id: "txn-1"), transaction_fixture(id: "txn-2")],
        has_more: false
      )
    )

    {:ok, page} = PlaidEx.API.Transactions.sync(config, access_token: "access-test")

    assert length(page.added) == 2
    assert page.has_more == false
  end

  test "handles ITEM_LOGIN_REQUIRED", %{bypass: bypass, config: config} do
    stub_error(bypass, "/transactions/sync", "ITEM_LOGIN_REQUIRED",
      status: 400
    )

    {:error, error} = PlaidEx.API.Transactions.sync(config, access_token: "access-test")

    assert error.code == "ITEM_LOGIN_REQUIRED"
    assert PlaidEx.Error.requires_reauthentication?(error)
  end
end
```

### Mox for unit tests

```elixir
# test/support/mocks.ex
Mox.defmock(PlaidEx.MockHTTP, for: PlaidEx.HTTP.ClientBehaviour)

# In tests:
expect(PlaidEx.MockHTTP, :post, fn _path, _body, _config, _opts ->
  {:ok, PlaidEx.Test.BypassHelpers.transactions_sync_fixture()}
end)
```

---

## Health check

```elixir
# In your health check endpoint:
def health(conn, _params) do
  json(conn, PlaidEx.health())
end

# Returns:
# {
#   "status": "ok",
#   "version": "1.0.0",
#   "sync_workers": 42,
#   "circuit_breakers": {
#     "sandbox": "closed",
#     "production": "closed"
#   },
#   "registered_tenants": 156
# }
```

---

## Configuration reference

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `client_id` | `string` | required | Plaid client_id |
| `secret` | `string` | required | Plaid secret (per environment) |
| `environment` | `:sandbox \| :development \| :production` | `:sandbox` | Plaid environment |
| `region` | `:us \| :eu \| :uk` | `:us` | API region |
| `pool_size` | `integer` | `20` | Finch connection pool size |
| `pool_count` | `integer` | `4` | Finch pool count |
| `request_timeout_ms` | `integer` | `30_000` | HTTP request timeout |
| `connect_timeout_ms` | `integer` | `5_000` | TCP connect timeout |
| `retry_max_attempts` | `integer` | `3` | Max retry attempts |
| `retry_base_delay_ms` | `integer` | `500` | Retry backoff base |
| `retry_max_delay_ms` | `integer` | `30_000` | Retry backoff cap |
| `circuit_breaker_threshold` | `integer` | `5` | Failures to open circuit |
| `circuit_breaker_reset_ms` | `integer` | `30_000` | Circuit reset timeout |
| `webhook_secret` | `string \| nil` | `nil` | Webhook signing secret |
| `oban_queue` | `atom` | `:plaid_webhooks` | Oban queue for webhooks |
| `oban_max_attempts` | `integer` | `10` | Oban job retry limit |
| `telemetry_prefix` | `[atom]` | `[:plaid_ex]` | Telemetry event prefix |
| `sync_poll_interval_ms` | `integer` | `30_000` | Transaction sync poll interval |
| `tenant_id` | `string \| nil` | `nil` | Tenant identifier |

---

## Requirements

- Elixir ~> 1.18
- OTP ~> 28
- Erlang/OTP crypto application

## License

MIT  

## Contributing

See CONTRIBUTING.md 
