defmodule PlaidEx.Telemetry.Metrics do
  @moduledoc """
  `Telemetry.Metrics` definitions for PlaidEx.

  Import these into your `Telemetry` supervisor to get standard
  metrics for Prometheus, StatsD, DataDog, etc.

  ## Usage

      # In your application's Telemetry supervisor (e.g., MyApp.Telemetry):
      def metrics do
        PlaidEx.Telemetry.Metrics.metrics() ++ your_own_metrics()
      end
  """

  import Telemetry.Metrics

  @doc "Returns all standard PlaidEx metric definitions."
  @spec metrics() :: [Telemetry.Metrics.t()]
  def metrics do
    [
      # ── HTTP ──────────────────────────────────────────────────────────────
      distribution("plaid_ex.http.stop.duration_ms",
        event_name: [:plaid_ex, :http, :stop],
        measurement: fn _, meta -> meta[:duration_ms] || 0 end,
        tags: [:path, :status, :tenant_id],
        unit: :millisecond,
        reporter_options: [buckets: [50, 100, 200, 500, 1000, 2000, 5000, 10_000]]
      ),
      counter("plaid_ex.http.stop.count",
        event_name: [:plaid_ex, :http, :stop],
        tags: [:path, :status, :tenant_id]
      ),
      counter("plaid_ex.http.error.count",
        event_name: [:plaid_ex, :http, :error],
        tags: [:path, :error_code, :error_type, :tenant_id]
      ),
      counter("plaid_ex.http.retry.count",
        event_name: [:plaid_ex, :http, :retry],
        tags: [:path, :error_code, :tenant_id]
      ),

      # ── Sync ──────────────────────────────────────────────────────────────
      counter("plaid_ex.sync.page.count",
        event_name: [:plaid_ex, :sync, :page],
        tags: [:tenant_id]
      ),
      sum("plaid_ex.sync.page.added",
        event_name: [:plaid_ex, :sync, :page],
        measurement: :added,
        tags: [:tenant_id]
      ),
      sum("plaid_ex.sync.page.modified",
        event_name: [:plaid_ex, :sync, :page],
        measurement: :modified,
        tags: [:tenant_id]
      ),
      sum("plaid_ex.sync.page.removed",
        event_name: [:plaid_ex, :sync, :page],
        measurement: :removed,
        tags: [:tenant_id]
      ),
      counter("plaid_ex.sync.reauth_required.count",
        event_name: [:plaid_ex, :sync, :reauth_required],
        tags: [:tenant_id]
      ),

      # ── Webhooks ──────────────────────────────────────────────────────────
      counter("plaid_ex.webhook.received.count",
        event_name: [:plaid_ex, :webhook, :received],
        tags: [:webhook_type, :webhook_code, :tenant_id]
      ),
      distribution("plaid_ex.webhook.dispatch.duration_ms",
        event_name: [:plaid_ex, :webhook, :dispatch],
        measurement: :duration_ms,
        tags: [:webhook_type, :webhook_code],
        unit: :millisecond,
        reporter_options: [buckets: [10, 50, 100, 500, 1000, 5000]]
      ),
      counter("plaid_ex.webhook.duplicate.count",
        event_name: [:plaid_ex, :webhook, :duplicate]
      ),
      counter("plaid_ex.webhook.invalid_signature.count",
        event_name: [:plaid_ex, :webhook, :invalid_signature]
      ),

      # ── Circuit breakers ──────────────────────────────────────────────────
      counter("plaid_ex.circuit_breaker.open.count",
        event_name: [:plaid_ex, :circuit_breaker, :open],
        tags: [:environment]
      ),
      counter("plaid_ex.circuit_breaker.close.count",
        event_name: [:plaid_ex, :circuit_breaker, :close],
        tags: [:environment]
      ),

      # ── Rate limiting ──────────────────────────────────────────────────────
      counter("plaid_ex.rate_limit.throttled.count",
        event_name: [:plaid_ex, :rate_limit, :throttled],
        tags: [:tenant_id]
      )
    ]
  end
end
