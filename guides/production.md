# Production Hardening

This guide covers everything you need to run PlaidEx reliably in production.

## Pre-launch checklist

### Credentials and security

- [ ] Use `config/runtime.exs` for all secrets — never commit credentials
- [ ] Encrypt `access_token` at rest (use Cloak, Vault, or AWS Secrets Manager)
- [ ] Set `webhook_secret` — never skip signature verification in production
- [ ] Rotate secrets quarterly; test rotation with `rotate_tenant_secret/2` first
- [ ] Restrict outbound firewall to `production.plaid.com` and `production.eu.plaid.com`
- [ ] Use Config.production?/1 to gate production-only safety checks

### Database

- [ ] Implement `PlaidEx.Sync.CursorStore.Behaviour` with Ecto — ETS cursors are lost on restart
- [ ] Add unique index on `plaid_transaction_id` — required for idempotent upserts
- [ ] Add unique index on `item_id` in your items table
- [ ] Use `on_conflict: :replace_all_except_id` for transaction upserts
- [ ] Index `(item_id, date)` for transaction queries
- [ ] Add `sync_cursor` column to your items table (TEXT, nullable)

### Connection pooling

```elixir
# config/runtime.exs — tune for your load
config :plaid_ex,
  pool_size: 30,       # concurrent connections per endpoint
  pool_count: 4,       # parallel pools (default: 4, total connections = pool_size * pool_count)
  request_timeout_ms: 30_000,
  connect_timeout_ms: 5_000
```

For reference — Plaid's rate limits (check your contract):
- Production: ~200 requests/second (varies by plan)
- Development: 100 requests/minute
- Sandbox: 100 requests/minute

### Retry configuration

```elixir
config :plaid_ex,
  retry_max_attempts: 3,
  retry_base_delay_ms: 500,   # base for exponential backoff
  retry_max_delay_ms: 30_000  # 30 second cap
```

The full jitter formula: `random_uniform(min(base * 2^attempt, max_delay))`

Attempt 1 → 0–500ms
Attempt 2 → 0–1s
Attempt 3 → 0–2s

### Webhooks

- [ ] Set webhook URL in Plaid Dashboard for all environments
- [ ] Use Oban for durable processing (not `Task.Supervisor`)
- [ ] Set `oban_max_attempts: 10` — don't lose webhooks to transient DB errors
- [ ] Monitor the Oban `plaid_webhooks` queue depth
- [ ] Test webhook delivery with `PlaidEx.API.Sandbox.fire_webhook/2`

### Circuit breaker tuning

```elixir
config :plaid_ex,
  circuit_breaker_threshold: 5,    # open after 5 consecutive failures
  circuit_breaker_reset_ms: 30_000 # try recovery after 30 seconds
```

Set an alert when `plaid_ex_circuit_breaker_open_count_total` increases.

## Performance tuning

### Connection pool sizing

For a server handling 100 req/s to Plaid:
```elixir
pool_size: 25,
pool_count: 4  # 100 total connections
```

Rule of thumb: `pool_size * pool_count >= peak_requests_per_second * avg_latency_seconds`

For 100 req/s with 200ms average latency:
`pool_connections = 100 * 0.2 = 20` → use 25 with headroom.

### Sync worker scaling

Each `TransactionSync` worker is a GenServer — lightweight (~2KB memory).
You can run thousands on a single node. Monitor with:

```elixir
PlaidEx.Sync.SyncSupervisor.worker_count()
# Returns number of active sync workers

PlaidEx.health()
# Returns %{sync_workers: N, ...}
```

### Rate limit planning

If you have 1000 tenants each with 50 items syncing every 30 seconds:
- Peak: 1000 * 50 / 30 ≈ 1667 req/s
- With Plaid's rate limits, stagger sync intervals per tenant

```elixir
# Stagger initial syncs to avoid burst
Enum.with_index(items, fn item, i ->
  Process.sleep(i * 50)  # 50ms between starts
  PlaidEx.start_transaction_sync(item.access_token, ...)
end)
```

## High availability

### Multi-node deployment

PlaidEx is designed for single-node per-environment, but works in clusters:

**What's node-local:**
- `TenantRegistry` (ETS) — re-populate from DB on each node start
- `CursorStore` (ETS) — use database-backed implementation
- `StateStore` (OAuth state, ETS) — use Redis-backed implementation for multi-node OAuth
- `Deduplicator` (ETS) — acceptable per-node; occasional cross-node duplicates are safe

**What's shared:**
- Database (Ecto/Postgres) — all nodes write through the same DB
- Oban jobs — persisted in Postgres, processed by any node

### Restart recovery

On application restart, re-register tenants and restart sync workers:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [MyApp.Repo, MyAppWeb.Endpoint]
    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

    Task.start(fn ->
      # Wait for PlaidEx to initialize
      Process.sleep(1_000)

      # Re-register all tenants from database
      MyApp.PlaidTenants.rehydrate_all()

      # Restart sync workers for all active items
      MyApp.PlaidItems.restart_all_sync_workers()
    end)

    {:ok, sup}
  end
end

defmodule MyApp.PlaidItems do
  def restart_all_sync_workers do
    from(i in PlaidItem, where: i.status == "active")
    |> Repo.all()
    |> Enum.each(fn item ->
      access_token = MyApp.Vault.decrypt!(item.access_token)

      PlaidEx.start_transaction_sync(access_token,
        handler: &MyApp.Transactions.process_page/1,
        tenant_id: item.tenant_id
      )
    end)
  end
end
```

### Graceful shutdown

PlaidEx workers stop cleanly on application shutdown.
`SyncSupervisor` children have a 5-second shutdown timeout — they will
finish processing the current page before stopping.

```elixir
# Ensure sufficient shutdown timeout in your release config:
# rel/config.exs
release :my_app do
  shutdown_timeout: 30_000  # 30 seconds for graceful drain
end
```

## Monitoring and alerting

### Critical alerts (page immediately)

| Condition | Query |
|-----------|-------|
| Circuit breaker opened | `plaid_ex_circuit_breaker_open_count_total > 0` |
| Invalid webhook signatures | `rate(plaid_ex_webhook_invalid_signature_count_total[5m]) > 0` |
| P99 latency > 10s | `histogram_quantile(0.99, plaid_ex_http_stop_duration_ms_bucket) > 10000` |
| Error rate > 10% | `rate(plaid_ex_http_error_count) / rate(plaid_ex_http_stop_count) > 0.10` |

### Warning alerts (notify next business day)

| Condition | Query |
|-----------|-------|
| Reauth required > 10/hour | `increase(plaid_ex_sync_reauth_required_count_total[1h]) > 10` |
| Retry rate > 5% | `rate(plaid_ex_http_retry_count) / rate(plaid_ex_http_stop_count) > 0.05` |
| Webhook queue depth > 100 | Oban queue depth |
| Sync lag > 5 minutes | Custom: time since last `sync.page` event per item |

### Runbooks

**Circuit breaker is open:**
1. Check `plaid_ex_http_error_count` for the error codes causing failures
2. Check [Plaid Status](https://status.plaid.com) for institution/API outages
3. If Plaid is healthy and your credentials are valid, manually reset:
   `PlaidEx.reset_circuit_breaker(:production)`

**Items requiring reauth spike:**
1. Query: `SELECT COUNT(*) FROM plaid_items WHERE status = 'reauth_required'`
2. Check if a specific institution is causing issues (institution outage)
3. Send targeted emails to affected users

**Webhook processing failures:**
1. Check Oban failed queue: `Oban.Web` or `Repo.all(from j in Oban.Job, where: j.state == "discarded")`
2. Inspect the job args to see the raw Plaid event
3. Fix the bug, then manually retry: `Oban.retry_job(job_id)`

## Security checklist

- [ ] `access_token` encrypted at rest (AES-256-GCM minimum)
- [ ] `webhook_secret` set and signature verification enabled
- [ ] Plaid Dashboard has IP allowlist for your server IPs (if supported by your plan)
- [ ] Never log `access_token`, `secret`, or `client_id` — use Config.scrub/1
- [ ] Audit log all token exchanges and item removals
- [ ] Implement rate limiting at your API layer (separate from PlaidEx's client-side limiting)
- [ ] Token rotation procedure documented and tested

## Plaid API version pinning

PlaidEx pins to API version `2020-09-14`. This version is stable.
Check the `Plaid-Version` header in your request logs to verify.

When Plaid releases a new API version:
1. Review the [Plaid changelog](https://plaid.com/docs/changelog/)
2. Test in sandbox with the new version
3. Update `@plaid_api_version` in `PlaidEx.HTTP.Client`
4. Run your full integration test suite

## Cost optimization

- Plaid bills per item per month and per API call (varies by product)
- Use `transactions/sync` instead of `transactions/get` — fewer total API calls
- Cache institution data (24-hour TTL) — `PlaidEx.API.Institutions` responses rarely change
- Batch balance checks — use `accounts/balance/get` with multiple account IDs
- Set `sync_poll_interval_ms: 60_000` if 30s granularity isn't required
- Use webhooks to trigger sync instead of constant polling
