ExUnit.start(exclude: [:integration, :slow])

# Start application for tests
Application.put_env(:plaid_ex, :client_id, "test_client_id")
Application.put_env(:plaid_ex, :secret, "test_secret")
Application.put_env(:plaid_ex, :environment, :sandbox)
Application.put_env(:plaid_ex, :retry_max_attempts, 0)
