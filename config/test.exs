import Config

config :plaid_ex,
  environment: :sandbox,
  pool_size: 2,
  pool_count: 1,
  retry_max_attempts: 0,
  request_timeout_ms: 5_000

config :logger, level: :warning
