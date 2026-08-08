# Observability

PlaidEx emits telemetry events, OpenTelemetry spans, and structured logs
for every significant operation. This guide shows how to wire them into
your monitoring stack.

## Telemetry events

### Attaching the default logger

```elixir
# In your Application.start/2 or a separate Telemetry supervisor:
PlaidEx.attach_telemetry(log_level: :info)
```

This attaches structured log lines for all PlaidEx events. In production,
set `:info` or `:warning` to reduce noise.

### Event reference

| Event                                       | Measurements               | Metadata                                                   |
| ------------------------------------------- | -------------------------- | ---------------------------------------------------------- |
| `[:plaid_ex, :http, :start]`                | `system_time`              | `path, attempt, tenant_id, url`                            |
| `[:plaid_ex, :http, :stop]`                 | `system_time`              | `path, status, duration_ms, attempt, tenant_id`            |
| `[:plaid_ex, :http, :error]`                | `system_time`              | `path, error_code, error_type, status, attempt, tenant_id` |
| `[:plaid_ex, :http, :retry]`                | `system_time`              | `path, attempt, delay_ms, error_code, tenant_id`           |
| `[:plaid_ex, :sync, :start]`                | —                          | `tenant_id, has_cursor`                                    |
| `[:plaid_ex, :sync, :page]`                 | `added, modified, removed` | `tenant_id, has_more, total_pages`                         |
| `[:plaid_ex, :sync, :reauth_required]`      | —                          | `tenant_id`                                                |
| `[:plaid_ex, :webhook, :received]`          | `system_time`              | `webhook_type, webhook_code, item_id, tenant_id`           |
| `[:plaid_ex, :webhook, :dispatch]`          | `duration_ms`              | `webhook_type, webhook_code, item_id, tenant_id, success`  |
| `[:plaid_ex, :webhook, :duplicate]`         | —                          | `webhook_id`                                               |
| `[:plaid_ex, :webhook, :invalid_signature]` | —                          | `remote_ip`                                                |
| `[:plaid_ex, :circuit_breaker, :open]`      | `failure_count`            | `environment`                                              |
| `[:plaid_ex, :circuit_breaker, :close]`     | —                          | `environment`                                              |
| `[:plaid_ex, :rate_limit, :throttled]`      | —                          | `tenant_id`                                                |

### Custom handlers

```elixir
# Attach your own handler for specific events:
:telemetry.attach(
  "my_app_plaid_errors",
  [:plaid_ex, :http, :error],
  fn _event, _measurements, meta, _config ->
    MyApp.Metrics.increment("plaid.http.error",
      tags: [
        path: meta.path,
        error_code: meta.error_code,
        tenant: meta.tenant_id || "global"
      ]
    )

    # Alert on high error rates
    if meta.error_code in ["INTERNAL_SERVER_ERROR", "RATE_LIMIT_EXCEEDED"] do
      MyApp.Alerts.increment_error_budget(:plaid)
    end
  end,
  nil
)

# Alert on circuit breaker events
:telemetry.attach(
  "my_app_plaid_circuit",
  [:plaid_ex, :circuit_breaker, :open],
  fn _event, %{failure_count: count}, %{environment: env}, _ ->
    MyApp.Alerts.pagerduty(
      "Plaid circuit breaker opened",
      environment: env,
      failure_count: count
    )
  end,
  nil
)
```

## Telemetry.Metrics (Prometheus / StatsD)

Use the built-in metric definitions with any `Telemetry.Metrics`-compatible
reporter (PromEx, TelemetryMetricsStatsd, etc.):

```elixir
defmodule MyApp.Telemetry do
  use Supervisor

  def start_link(arg), do: Supervisor.start_link(__MODULE__, arg, name: __MODULE__)

  def init(_arg) do
    children = [
      # PromEx (Prometheus)
      {MyApp.PromEx, []},

      # Or TelemetryMetricsStatsd
      {TelemetryMetricsStatsd,
        metrics: metrics(),
        host: "localhost",
        port: 8125,
        prefix: "myapp"
      }
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    # Include all PlaidEx metrics
    PlaidEx.telemetry_metrics() ++
    [
      # Your own app metrics
      counter("myapp.transactions.processed"),
      distribution("myapp.sync.duration_ms")
    ]
  end
end
```

### Built-in metrics

```
plaid_ex.http.stop.duration_ms      # histogram: HTTP latency by path/status/tenant
plaid_ex.http.stop.count            # counter: request count
plaid_ex.http.error.count           # counter: errors by code/type/tenant
plaid_ex.http.retry.count           # counter: retries by path/tenant
plaid_ex.sync.page.count            # counter: sync pages processed
plaid_ex.sync.page.added            # sum: transactions added per page
plaid_ex.sync.page.modified         # sum: transactions modified per page
plaid_ex.sync.page.removed          # sum: transactions removed per page
plaid_ex.sync.reauth_required.count # counter: items needing reauth
plaid_ex.webhook.received.count     # counter: webhooks by type/code
plaid_ex.webhook.dispatch.duration_ms # histogram: handler latency
plaid_ex.webhook.duplicate.count    # counter: duplicates discarded
plaid_ex.webhook.invalid_signature.count # counter: invalid signatures
plaid_ex.circuit_breaker.open.count # counter: circuit opens by environment
plaid_ex.circuit_breaker.close.count # counter: circuit closes
plaid_ex.rate_limit.throttled.count # counter: rate limit hits by tenant
```

### PromEx integration

```elixir
defmodule MyApp.PromEx do
  use PromEx, otp_app: :my_app

  @impl true
  def plugins do
    [
      PromEx.Plugins.Application,
      PromEx.Plugins.Beam,
      # PlaidEx metrics are already in Telemetry.Metrics format,
      # so they integrate with any PromEx setup via manual_metrics
    ]
  end

  @impl true
  def dashboard_assigns do
    [grafana_folder: "MyApp Dashboards"]
  end
end
```

## OpenTelemetry (distributed tracing)

### Setup

```elixir
# mix.exs
{:opentelemetry, "~> 1.4"},
{:opentelemetry_exporter, "~> 1.7"},
{:opentelemetry_phoenix, "~> 2.0"},
{:opentelemetry_ecto, "~> 1.2"}

# config/runtime.exs
config :opentelemetry,
  resource: [
    service: [name: "my-plaid-service", version: "1.0.0"]
  ],
  span_processor: :batch,
  traces_exporter: :otlp

config :opentelemetry_exporter,
  otlp_protocol: :grpc,
  otlp_endpoint: System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT", "http://localhost:4317")
```

### What's traced

Every PlaidEx HTTP request creates an OpenTelemetry span:

```
plaid.http.post /transactions/sync
  ├── plaid.path = "/transactions/sync"
  ├── plaid.environment = "production"
  ├── plaid.region = "us"
  ├── plaid.tenant_id = "acme_corp"
  └── plaid.error.code = "RATE_LIMIT_EXCEEDED" (on error)
```

### Propagating context to async operations

When dispatching webhooks or starting sync workers from within a traced
request, propagate the trace context:

```elixir
def handle_webhook(conn, %{"public_token" => token} = _params) do
  # Capture current trace context
  ctx = OpenTelemetry.Ctx.get_current()

  Task.start(fn ->
    # Restore context in the async task
    OpenTelemetry.Ctx.attach(ctx)
    process_token(token)
  end)

  send_resp(conn, 200, "ok")
end
```

### Custom spans for your business logic

```elixir
defmodule MyApp.Transactions do
  require OpenTelemetry.Tracer, as: Tracer

  def process_sync_page(tenant_id, page) do
    Tracer.with_span "transactions.process_page" do
      Tracer.set_attributes(%{
        "tenant_id" => tenant_id,
        "transactions.added" => length(page.added),
        "transactions.modified" => length(page.modified),
        "transactions.removed" => length(page.removed)
      })

      # Your processing logic
      upsert_batch(page.added ++ page.modified)
      delete_batch(page.removed)
    end
  end
end
```

## Structured logging

PlaidEx uses `Logger.metadata` for structured context. Configure your
logger formatter to emit JSON for log aggregation:

```elixir
# config/prod.exs
config :logger,
  backends: [:console],
  level: :info

config :logger, :console,
  format: {MyApp.LogFormatter, :format},
  metadata: [:request_id, :tenant_id, :trace_id, :span_id]
```

```elixir
defmodule MyApp.LogFormatter do
  def format(level, message, timestamp, metadata) do
    data = %{
      level: level,
      message: IO.chardata_to_string(message),
      timestamp: format_timestamp(timestamp),
      tenant_id: metadata[:tenant_id],
      trace_id: metadata[:trace_id],
      span_id: metadata[:span_id],
      request_id: metadata[:request_id]
    }

    [Jason.encode!(data), "\n"]
  rescue
    _ -> "#{message}\n"
  end

  defp format_timestamp({{y, mo, d}, {h, m, s, _ms}}) do
    "#{y}-#{pad(mo)}-#{pad(d)}T#{pad(h)}:#{pad(m)}:#{pad(s)}Z"
  end

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")
end
```

## Grafana dashboard setup

Create a dashboard with these key panels:

### API Health

```promql
# P95 latency by Plaid endpoint
histogram_quantile(0.95,
  rate(plaid_ex_http_stop_duration_ms_bucket[5m])
) by (path)

# Error rate
rate(plaid_ex_http_error_count_total[5m]) by (error_code)

# Retry rate
rate(plaid_ex_http_retry_count_total[5m]) by (path)
```

### Sync Health

```promql
# Transactions synced per second
rate(plaid_ex_sync_page_added_total[5m])

# Sync pages per second
rate(plaid_ex_sync_page_count_total[5m])

# Items requiring reauth
increase(plaid_ex_sync_reauth_required_count_total[1h])
```

### Webhook Health

```promql
# Webhook ingestion rate by type
rate(plaid_ex_webhook_received_count_total[5m]) by (webhook_type)

# Webhook processing latency
histogram_quantile(0.95,
  rate(plaid_ex_webhook_dispatch_duration_ms_bucket[5m])
)

# Duplicate rate (should be low)
rate(plaid_ex_webhook_duplicate_count_total[5m])

# Invalid signature rate (security alert)
rate(plaid_ex_webhook_invalid_signature_count_total[5m])
```

### Reliability

```promql
# Circuit breaker opens (alert threshold: > 0)
increase(plaid_ex_circuit_breaker_open_count_total[5m]) by (environment)

# Rate limit hits
rate(plaid_ex_rate_limit_throttled_count_total[5m]) by (tenant_id)
```

## Alerting rules

```yaml
# prometheus/alerts.yml
groups:
  - name: plaid_ex
    rules:
      - alert: PlaidCircuitBreakerOpen
        expr: increase(plaid_ex_circuit_breaker_open_count_total[5m]) > 0
        for: 0m
        labels:
          severity: critical
        annotations:
          summary: "Plaid circuit breaker opened for {{ $labels.environment }}"

      - alert: PlaidHighErrorRate
        expr: |
          rate(plaid_ex_http_error_count_total[5m]) /
          rate(plaid_ex_http_stop_count_total[5m]) > 0.05
        for: 2m
        labels:
          severity: warning
        annotations:
          summary: "Plaid API error rate > 5%"

      - alert: PlaidInvalidSignatures
        expr: rate(plaid_ex_webhook_invalid_signature_count_total[5m]) > 0
        for: 1m
        labels:
          severity: warning
        annotations:
          summary: "Plaid webhook invalid signatures detected — possible spoofing"

      - alert: PlaidHighSyncReauth
        expr: increase(plaid_ex_sync_reauth_required_count_total[1h]) > 10
        for: 0m
        labels:
          severity: warning
        annotations:
          summary: "{{ $value }} items requiring reauth in last hour"

      - alert: PlaidHighLatency
        expr: |
          histogram_quantile(0.95,
            rate(plaid_ex_http_stop_duration_ms_bucket[5m])
          ) > 5000
        for: 5m
        labels:
          severity: warning
        annotations:
          summary: "Plaid API P95 latency > 5 seconds"
```

## Health endpoint

```elixir
defmodule MyAppWeb.HealthController do
  use MyAppWeb, :controller

  def plaid(conn, _params) do
    health = PlaidEx.health()

    status = if health.circuit_breakers[:production] == :open, do: :service_unavailable, else: :ok

    conn
    |> put_status(status)
    |> json(health)
  end
end
```

Response:

```json
{
  "status": "ok",
  "version": "1.0.0",
  "sync_workers": 42,
  "registered_tenants": 156,
  "circuit_breakers": {
    "sandbox": "closed",
    "development": "closed",
    "production": "closed"
  }
}
```
