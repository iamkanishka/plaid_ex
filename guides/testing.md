# Testing

PlaidEx provides a complete testing toolkit: Bypass HTTP stubs with realistic
fixtures, webhook builders, Mox behaviour definitions, and helpers for testing
sync workers.

## Setup

```elixir
# mix.exs — test deps
{:bypass, "~> 2.1", only: :test},
{:mox, "~> 1.2", only: :test},
{:stream_data, "~> 1.1", only: [:dev, :test]}  # for property testing
```

```elixir
# test/test_helper.exs
ExUnit.start(exclude: [:integration, :slow])

# Set minimal PlaidEx config for tests
Application.put_env(:plaid_ex, :client_id, "test_client_id")
Application.put_env(:plaid_ex, :secret, "test_secret")
Application.put_env(:plaid_ex, :environment, :sandbox)
Application.put_env(:plaid_ex, :retry_max_attempts, 0)  # no retries in tests
```

## Bypass helpers

```elixir
defmodule MyApp.PlaidIntegrationTest do
  use ExUnit.Case, async: true
  use PlaidEx.Test.BypassHelpers

  setup do
    bypass = Bypass.open()
    config = test_config(bypass)
    {:ok, bypass: bypass, config: config}
  end

  test "creates a link token", %{bypass: bypass, config: config} do
    stub_create_link_token(bypass)

    {:ok, link_token} = PlaidEx.API.Link.create_token(config,
      user: %{client_user_id: "user-123"},
      client_name: "Test App",
      products: ["transactions"],
      country_codes: ["US"],
      language: "en"
    )

    assert link_token.link_token == "link-sandbox-test-token"
    assert link_token.expiration != nil
  end

  test "exchanges a public token", %{bypass: bypass, config: config} do
    stub_exchange_public_token(bypass)

    {:ok, result} = PlaidEx.API.Items.exchange_public_token(config, "public-test-token")

    assert result.access_token == "access-sandbox-test-access-token"
    assert result.item_id == "item-sandbox-test-item-id"
  end

  test "fetches accounts", %{bypass: bypass, config: config} do
    stub_get_accounts(bypass)

    {:ok, result} = PlaidEx.API.Accounts.get(config, "access-test")

    assert length(result.accounts) == 2
    assert hd(result.accounts).type == :depository
  end

  test "handles ITEM_LOGIN_REQUIRED", %{bypass: bypass, config: config} do
    stub_error(bypass, "/transactions/sync", "ITEM_LOGIN_REQUIRED",
      status: 400,
      error_type: "ITEM_ERROR"
    )

    {:error, error} = PlaidEx.API.Transactions.sync(config, access_token: "access-test")

    assert error.code == "ITEM_LOGIN_REQUIRED"
    assert PlaidEx.Error.requires_reauthentication?(error)
    refute PlaidEx.Error.retryable?(error)
  end

  test "handles server errors", %{bypass: bypass, config: config} do
    stub_server_error(bypass, "/accounts/get")

    # With retry_max_attempts: 0, this fails immediately
    {:error, error} = PlaidEx.API.Accounts.get(config, "access-test")

    assert error.code == "INTERNAL_SERVER_ERROR"
    assert PlaidEx.Error.retryable?(error)
  end
end
```

## Testing pagination

```elixir
test "handles multi-page sync", %{bypass: bypass, config: config} do
  # Set up two pages
  stub_transactions_sync_paginated(bypass, [
    transactions_sync_fixture(
      has_more: true,
      cursor: "cursor-page-1",
      added: [transaction_fixture(id: "txn-1"), transaction_fixture(id: "txn-2")]
    ),
    transactions_sync_fixture(
      has_more: false,
      cursor: "cursor-page-2",
      added: [transaction_fixture(id: "txn-3")]
    )
  ])

  # Fetch page 1
  {:ok, page1} = PlaidEx.API.Transactions.sync(config, access_token: "access-test")
  assert page1.has_more == true
  assert length(page1.added) == 2

  # Fetch page 2 (using cursor from page 1)
  {:ok, page2} = PlaidEx.API.Transactions.sync(config,
    access_token: "access-test",
    cursor: page1.next_cursor
  )
  assert page2.has_more == false
  assert length(page2.added) == 1
end
```

## Testing the sync worker

```elixir
defmodule PlaidEx.Sync.TransactionSyncTest do
  use ExUnit.Case, async: false
  use PlaidEx.Test.BypassHelpers

  setup do
    bypass = Bypass.open()
    config = test_config(bypass, retry_max_attempts: 0)
    {:ok, bypass: bypass, config: config}
  end

  test "calls handler with received transactions", %{bypass: bypass, config: config} do
    test_pid = self()

    Bypass.expect_once(bypass, "POST", "/transactions/sync", fn conn ->
      body = transactions_sync_fixture(
        added: [transaction_fixture(id: "txn-sync-1")],
        has_more: false
      )
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end)

    {:ok, _pid} = PlaidEx.start_transaction_sync(config,
      "access-test-#{:rand.uniform(10_000)}",
      handler: fn page ->
        send(test_pid, {:page, page})
        :ok
      end,
      poll_interval_ms: 60_000
    )

    assert_receive {:page, page}, 2_000
    assert length(page.added) == 1
    assert hd(page.added).transaction_id == "txn-sync-1"
  end

  test "pauses on ITEM_LOGIN_REQUIRED", %{bypass: bypass, config: config} do
    access_token = "access-test-reauth-#{:rand.uniform(10_000)}"

    Bypass.expect_once(bypass, "POST", "/transactions/sync", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(
        plaid_error_fixture("ITEM_LOGIN_REQUIRED", error_type: "ITEM_ERROR")
      ))
    end)

    {:ok, _pid} = PlaidEx.start_transaction_sync(config,
      access_token,
      handler: fn _page -> :ok end,
      poll_interval_ms: 60_000
    )

    # Wait for worker to process the error
    Process.sleep(500)

    {:ok, status} = PlaidEx.transaction_sync_status(access_token)
    assert status.paused == true
    assert status.pause_reason == :item_login_required
  end
end
```

## Testing webhooks

```elixir
defmodule MyApp.WebhookHandlerTest do
  use ExUnit.Case, async: true

  import PlaidEx.Test.MockPlaidServer

  test "on_transactions_sync triggers item sync" do
    # Build a typed webhook event directly
    event = %PlaidEx.Webhooks.Schemas.TransactionsSyncEvent{
      webhook_type: "TRANSACTIONS",
      webhook_code: "SYNC_UPDATES_AVAILABLE",
      item_id: "item-test-sync",
      environment: "sandbox",
      initial_update_complete: true,
      historical_update_complete: true
    }

    # Call handler directly — no HTTP, no process needed
    assert :ok = MyApp.PlaidWebhooks.on_transactions_sync(event)
  end

  test "on_item_error handles ITEM_LOGIN_REQUIRED" do
    event = %PlaidEx.Webhooks.Schemas.ItemErrorEvent{
      webhook_type: "ITEM",
      webhook_code: "ERROR",
      item_id: "item-test-login",
      environment: "sandbox",
      error: %{"error_code" => "ITEM_LOGIN_REQUIRED", "error_type" => "ITEM_ERROR"}
    }

    # Should not raise
    assert :ok = MyApp.PlaidWebhooks.on_item_error(event)
  end
end

# Testing the complete webhook Plug
defmodule MyAppWeb.PlaidWebhookPlugTest do
  use MyAppWeb.ConnCase

  import PlaidEx.Test.MockPlaidServer

  test "accepts valid signed webhook" do
    config = %{webhook_secret: "test_webhook_secret_abc"}

    event = build_webhook("TRANSACTIONS", "SYNC_UPDATES_AVAILABLE",
      item_id: "item-web-test"
    )
    {body, signature} = build_signed_webhook(event, config.webhook_secret)

    conn =
      build_conn(:post, "/webhooks/plaid", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("plaid-verification", signature)

    response = MyAppWeb.Endpoint.call(conn, [])
    assert response.status == 200
  end

  test "rejects webhook with bad signature" do
    event = build_webhook("TRANSACTIONS", "SYNC_UPDATES_AVAILABLE")
    body = Jason.encode!(event)

    conn =
      build_conn(:post, "/webhooks/plaid", body)
      |> put_req_header("content-type", "application/json")
      |> put_req_header("plaid-verification", "aaaaaaaaaa")

    response = MyAppWeb.Endpoint.call(conn, [])
    assert response.status == 401
  end
end
```

## Mox for unit tests

Define mocks for the HTTP client to test higher-level code without HTTP:

```elixir
# test/support/mocks.ex
Mox.defmock(PlaidEx.MockHTTPClient, for: PlaidEx.HTTP.ClientBehaviour)

# test/my_app/plaid_service_test.exs
defmodule MyApp.PlaidServiceTest do
  use ExUnit.Case, async: true
  import Mox

  setup :verify_on_exit!

  test "creates link token" do
    expect(PlaidEx.MockHTTPClient, :post, fn "/link/token/create", _body, _config, _opts ->
      {:ok, %{
        "link_token" => "link-sandbox-mock",
        "expiration" => "2099-01-01T00:00:00Z",
        "request_id" => "req_mock"
      }}
    end)

    {:ok, token} = MyApp.PlaidService.create_link_token("tenant-1", "user-1", ["transactions"])
    assert token.link_token == "link-sandbox-mock"
  end

  test "handles API errors" do
    expect(PlaidEx.MockHTTPClient, :post, fn _path, _body, _config, _opts ->
      {:error, %PlaidEx.Error{
        type: :api_error,
        code: "INTERNAL_SERVER_ERROR",
        message: "Plaid is down",
        status: 500,
        retryable: true
      }}
    end)

    assert {:error, %PlaidEx.Error{code: "INTERNAL_SERVER_ERROR"}} =
      MyApp.PlaidService.create_link_token("tenant-1", "user-1", ["transactions"])
  end
end
```

## Property-based testing

Use `StreamData` to test schema parsing with generated inputs:

```elixir
defmodule PlaidEx.Schemas.TransactionPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PlaidEx.Schemas.Transaction

  property "Transaction.from_map/1 never raises on arbitrary maps" do
    check all map <- map_of(string(:alphanumeric), term()) do
      # Should never raise — always return a struct or gracefully handle nils
      result = Transaction.from_map(map)
      assert %Transaction{} = result
    end
  end

  property "Transaction amount is always the original value" do
    check all amount <- one_of([float(), integer(), nil]) do
      tx = Transaction.from_map(%{"transaction_id" => "t1", "amount" => amount})
      assert tx.amount == amount
    end
  end
end
```

## Integration test with sandbox API

For full end-to-end integration tests against Plaid's sandbox:

```elixir
defmodule PlaidEx.SandboxIntegrationTest do
  # Tag these so they don't run in CI unless explicitly requested
  @moduletag :integration

  use ExUnit.Case, async: false

  @config PlaidEx.Config.new!(
    client_id: System.get_env("PLAID_CLIENT_ID") || "test",
    secret: System.get_env("PLAID_SECRET") || "test",
    environment: :sandbox
  )

  test "complete link flow" do
    # Create a test item directly (bypasses Link UI)
    {:ok, %{public_token: public_token}} =
      PlaidEx.API.Sandbox.create_public_token(@config,
        institution_id: "ins_109508",
        initial_products: ["transactions"]
      )

    # Exchange
    {:ok, %{access_token: access_token}} =
      PlaidEx.exchange_public_token(@config, public_token)

    assert String.starts_with?(access_token, "access-sandbox-")

    # Get accounts
    {:ok, %{accounts: accounts}} = PlaidEx.get_accounts(access_token)
    assert length(accounts) > 0

    # Sync transactions
    {:ok, page} = PlaidEx.API.Transactions.sync(@config, access_token: access_token)
    assert page.next_cursor != nil

    # Clean up
    PlaidEx.API.Items.remove(@config, access_token)
  end
end
```

Run integration tests:
```bash
PLAID_CLIENT_ID=xxx PLAID_SECRET=yyy mix test --only integration
```

## CI configuration

```yaml
# .github/workflows/ci.yml (excerpt)
- name: Run tests
  run: mix test
  env:
    PLAID_CLIENT_ID: test_client_id
    PLAID_SECRET: test_secret

# Integration tests (optional, uses real Plaid sandbox)
- name: Run integration tests
  if: github.ref == 'refs/heads/main'
  run: mix test --only integration
  env:
    PLAID_CLIENT_ID: ${{ secrets.PLAID_SANDBOX_CLIENT_ID }}
    PLAID_SECRET: ${{ secrets.PLAID_SANDBOX_SECRET }}
```
