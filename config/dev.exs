import Config

config :plaid_ex,
  environment: :sandbox,
  pool_size: 4,
  pool_count: 1

config :logger, level: :debug
