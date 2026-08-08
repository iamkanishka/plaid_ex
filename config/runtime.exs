import Config

# Runtime configuration. Reads secrets from environment at startup.
# This is where you inject credentials from Vault, AWS Secrets Manager, etc.

if System.get_env("PLAID_CLIENT_ID") do
  config :plaid_ex,
    client_id: System.fetch_env!("PLAID_CLIENT_ID"),
    secret: System.fetch_env!("PLAID_SECRET"),
    environment: System.get_env("PLAID_ENVIRONMENT", "production") |> String.to_atom(),
    region: System.get_env("PLAID_REGION", "us") |> String.to_atom(),
    webhook_secret: System.get_env("PLAID_WEBHOOK_SECRET"),
    pool_size: System.get_env("PLAID_POOL_SIZE", "20") |> String.to_integer()
end
