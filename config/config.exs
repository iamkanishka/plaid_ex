import Config

# PlaidEx default configuration.
# Override in your application's config files.
config :plaid_ex,
  environment: :sandbox,
  region: :us,
  pool_size: 20,
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

import_config "#{config_env()}.exs"
