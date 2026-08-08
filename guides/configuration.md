# Configuration Reference

PlaidEx is configured using NimbleOptions-validated structs. Every option
is validated at startup with clear error messages for invalid values.

## Application config (single-tenant)

```elixir
# config/runtime.exs
config :plaid_ex,
  client_id: System.fetch_env!("PLAID_CLIENT_ID"),
  secret: System.fetch_env!("PLAID_SECRET"),
  environment: :production,
  region: :us,
  webhook_secret: System.fetch_env!("PLAID_WEBHOOK_SECRET"),
  pool_size: 30,
  pool_count: 4,
  request_timeout_ms: 30_000,
  connect_timeout_ms: 5_000,
  retry_max_attempts: 3,
  retry_base_delay_ms: 500,
  retry_max_delay_ms: 30_000,
  circuit_breaker_threshold: 5,
  circuit_breaker_reset_ms: 30_000,
  sync_poll_interval_ms: 30_000,
  oban_queue: :plaid_webhooks,
  oban_max_attempts: 10,
  telemetry_prefix: [:plaid_ex]
```

## Runtime struct construction (multi-tenant)

```elixir
config = PlaidEx.Config.new!(
  client_id: vault.get("tenant/plaid/client_id"),
  secret: vault.get("tenant/plaid/secret"),
  environment: :production,
  region: :us,
  tenant_id: "acme_corp",
  metadata: %{plan: "enterprise", onboarded_at: "2024-01-15"}
)
```

## Option reference

### Required

| Option | Type | Description |
|--------|------|-------------|
| `client_id` | `string` | Your Plaid `client_id` from the Dashboard |
| `secret` | `string` | Plaid `secret` — differs per environment |

### Environment

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `environment` | `:sandbox \| :development \| :production` | `:sandbox` | Plaid environment |
| `region` | `:us \| :eu \| :uk` | `:us` | API region for endpoint routing |

**Base URLs by environment and region:**

| Environment | Region | URL |
|-------------|--------|-----|
| `:production` | `:us` | `https://production.plaid.com` |
| `:production` | `:eu` or `:uk` | `https://production.eu.plaid.com` |
| `:development` | any | `https://development.plaid.com` |
| `:sandbox` | any | `https://sandbox.plaid.com` |

### HTTP / connection pool

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `pool_size` | `pos_integer` | `20` | Finch connections per endpoint |
| `pool_count` | `pos_integer` | `4` | Parallel pools per endpoint |
| `request_timeout_ms` | `pos_integer` | `30_000` | Request timeout (30s) |
| `connect_timeout_ms` | `pos_integer` | `5_000` | TCP connect timeout (5s) |

**Total connections = `pool_size * pool_count`**

Rule of thumb for production:
```
connections_needed = peak_rps × avg_latency_seconds × 1.5 (safety factor)
```

For 100 req/s with 200ms average:
```
connections_needed = 100 × 0.2 × 1.5 = 30 connections
pool_size: 8, pool_count: 4  # = 32 connections
```

### Retry

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `retry_max_attempts` | `non_neg_integer` | `3` | Max retries (0 = no retries) |
| `retry_base_delay_ms` | `pos_integer` | `500` | Backoff base delay |
| `retry_max_delay_ms` | `pos_integer` | `30_000` | Backoff cap |

Retry only occurs for errors classified as `retryable: true`:
- `RATE_LIMIT_EXCEEDED`
- `INTERNAL_SERVER_ERROR`
- `INSTITUTION_DOWN`
- `INSTITUTION_NOT_RESPONDING`
- `PRODUCT_NOT_READY`
- `PLANNED_MAINTENANCE`
- Network timeouts and connection errors

**Backoff formula (full jitter):**
```elixir
delay = random_uniform(min(base_ms * 2^attempt, max_delay_ms))
```

| Attempt | Jitter range (base=500ms, max=30s) |
|---------|-----------------------------------|
| 1 | 0–500ms |
| 2 | 0–1s |
| 3 | 0–2s |
| 4 | 0–4s |
| 5 | 0–8s |
| N≥9 | 0–30s (capped) |

### Circuit breaker

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `circuit_breaker_threshold` | `pos_integer` | `5` | Failures to open circuit |
| `circuit_breaker_reset_ms` | `pos_integer` | `30_000` | Recovery probe interval |

Errors that trigger the circuit breaker:
- All `status >= 500` responses
- `error_type` in `[:institution_error, :api_error]`

Errors that do NOT trigger the circuit breaker:
- `ITEM_LOGIN_REQUIRED` (user error)
- `INVALID_INPUT` (developer error)
- `RATE_LIMIT_EXCEEDED` (handled by retry)

### Webhooks

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `webhook_secret` | `string \| nil` | `nil` | Webhook signing secret |
| `oban_queue` | `atom` | `:plaid_webhooks` | Oban queue name |
| `oban_max_attempts` | `pos_integer` | `10` | Max Oban job retries |

### Sync

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `sync_poll_interval_ms` | `pos_integer` | `30_000` | Poll interval when caught up |

Plaid recommends polling no more frequently than every 30 seconds.
Use webhooks (`SYNC_UPDATES_AVAILABLE`) to trigger immediate syncs.

### Caching

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `cache_institutions_ttl_ms` | `pos_integer` | `86_400_000` | Institution cache TTL (24h) |

### Observability

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `telemetry_prefix` | `[atom]` | `[:plaid_ex]` | Prefix for all telemetry events |

Change this if you have naming conflicts:
```elixir
telemetry_prefix: [:my_app, :plaid]
# Events become: [:my_app, :plaid, :http, :stop], etc.
```

### Multi-tenant

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `tenant_id` | `string \| nil` | `nil` | Tenant identifier |
| `metadata` | `map` | `%{}` | Arbitrary metadata for tracing |

## Pluggable backends

### Cursor store

```elixir
# config/config.exs
config :plaid_ex, cursor_store: MyApp.PlaidCursorStore

# Implement the behaviour:
defmodule MyApp.PlaidCursorStore do
  @behaviour PlaidEx.Sync.CursorStore.Behaviour

  @impl true
  def get(access_token), do: # fetch from DB
  @impl true
  def put(access_token, cursor), do: # persist to DB
  @impl true
  def delete(access_token), do: # delete from DB
end
```

### Webhook handler (for Oban)

```elixir
config :plaid_ex, webhook_handler: MyApp.PlaidWebhooks
```

Used by `PlaidEx.Webhooks.ObanWorker` to look up the handler module
when processing jobs asynchronously.

### App name (for Link)

```elixir
config :plaid_ex, app_name: "Acme Finance"
```

Used in OAuth flow Link token creation as the `client_name`.

### OAuth state TTL

```elixir
config :plaid_ex, oauth_state_ttl_seconds: 600  # 10 minutes (default)
```

### Webhook dedup window

```elixir
config :plaid_ex, webhook_dedup_window_seconds: 3600  # 1 hour (default)
```

## Environment-specific patterns

### Development

```elixir
# config/dev.exs
config :plaid_ex,
  environment: :sandbox,
  pool_size: 4,
  pool_count: 1,
  retry_max_attempts: 0,   # fail fast in dev
  webhook_secret: nil      # skip verification in dev
```

### Test

```elixir
# config/test.exs
config :plaid_ex,
  client_id: "test_client_id",
  secret: "test_secret",
  environment: :sandbox,
  pool_size: 2,
  pool_count: 1,
  retry_max_attempts: 0,    # no retries in tests
  request_timeout_ms: 5_000 # fast timeout
```

### Production

```elixir
# config/runtime.exs
config :plaid_ex,
  client_id: System.fetch_env!("PLAID_CLIENT_ID"),
  secret: System.fetch_env!("PLAID_SECRET"),
  environment: :production,
  region: :us,
  webhook_secret: System.fetch_env!("PLAID_WEBHOOK_SECRET"),
  pool_size: 25,
  pool_count: 4,
  retry_max_attempts: 3,
  circuit_breaker_threshold: 5,
  circuit_breaker_reset_ms: 30_000,
  sync_poll_interval_ms: 30_000,
  oban_queue: :plaid_webhooks,
  oban_max_attempts: 10
```

## Validation errors

PlaidEx raises `ArgumentError` on invalid config with a detailed message:

```
PlaidEx.Config validation failed:

  invalid value for :environment option:
  expected one of [:sandbox, :development, :production], got: :prod

See `PlaidEx.Config` documentation for all valid options.
```

## Config introspection

```elixir
# Get the current loaded config
config = PlaidEx.config()
config.environment  # :production
config.pool_size    # 25

# Get scrubbed config (safe for logging)
PlaidEx.Config.scrub(config)
# %{client_id: "your-id", secret: "[REDACTED]", webhook_secret: "[REDACTED]", ...}

# Check if production
PlaidEx.Config.production?(config)  # true

# Get the base URL
PlaidEx.Config.base_url(config)  # "https://production.plaid.com"

# Rotate secret (returns new config, does not mutate)
new_config = PlaidEx.Config.rotate_secret(config, new_secret)
```
