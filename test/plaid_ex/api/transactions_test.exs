defmodule PlaidEx.API.TransactionsTest do
  use ExUnit.Case, async: true

  import PlaidEx.Test.BypassHelpers

  alias PlaidEx.API.Transactions
  alias PlaidEx.Error
  alias PlaidEx.Schemas.Transaction
  alias PlaidEx.Schemas.TransactionSyncPage

  setup do: bypass_setup(retry_max_attempts: 0)

  describe "sync/2" do
    test "returns a sync page with typed transactions", %{bypass: bypass, config: config} do
      stub_transactions_sync(bypass,
        response:
          transactions_sync_fixture(
            added: [
              transaction_fixture(id: "txn-1"),
              transaction_fixture(id: "txn-2")
            ],
            has_more: false,
            cursor: "cursor-test-value"
          )
      )

      {:ok, page} = Transactions.sync(config, access_token: "access-test")

      assert %TransactionSyncPage{} = page
      assert length(page.added) == 2
      assert page.has_more == false
      assert page.next_cursor == "cursor-test-value"

      [tx | _] = page.added
      assert %Transaction{} = tx
      assert tx.transaction_id == "txn-1"
    end

    test "passes cursor in request body when provided", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/transactions/sync", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Verify cursor is present
        assert decoded["cursor"] == "my-test-cursor"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(transactions_sync_fixture()))
      end)

      Transactions.sync(config,
        access_token: "access-test",
        cursor: "my-test-cursor"
      )
    end

    test "omits cursor when nil", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/transactions/sync", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        # Cursor should not be present for initial sync
        refute Map.has_key?(decoded, "cursor")

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(transactions_sync_fixture()))
      end)

      Transactions.sync(config, access_token: "access-test", cursor: nil)
    end

    test "returns typed error on ITEM_LOGIN_REQUIRED", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/transactions/sync", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(plaid_error_fixture("ITEM_LOGIN_REQUIRED", error_type: "ITEM_ERROR"))
        )
      end)

      {:error, error} = Transactions.sync(config, access_token: "access-test")

      assert %Error{} = error
      assert error.code == "ITEM_LOGIN_REQUIRED"
      assert error.requires_reauthentication == true
      assert error.retryable == false
    end

    test "returns typed error on PRODUCT_NOT_READY", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/transactions/sync", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          400,
          Jason.encode!(plaid_error_fixture("PRODUCT_NOT_READY", error_type: "API_ERROR"))
        )
      end)

      {:error, error} = Transactions.sync(config, access_token: "access-test")

      assert error.code == "PRODUCT_NOT_READY"
      assert error.retryable == true
      assert error.suggested_action == :retry_with_delay
    end

    test "sends correct Plaid-Version header", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/transactions/sync", fn conn ->
        version = conn |> Plug.Conn.get_req_header("plaid-version") |> List.first()
        assert version == "2020-09-14"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(transactions_sync_fixture()))
      end)

      Transactions.sync(config, access_token: "access-test")
    end

    test "sends idempotency key header", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/transactions/sync", fn conn ->
        idempotency = conn |> Plug.Conn.get_req_header("idempotency-key") |> List.first()
        assert idempotency != nil
        assert byte_size(idempotency) > 0

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(transactions_sync_fixture()))
      end)

      Transactions.sync(config, access_token: "access-test")
    end
  end

  describe "get_recurring/2" do
    test "returns recurring streams", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/transactions/recurring/get", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "inflow_streams" => [],
            "outflow_streams" => [
              %{
                "stream_id" => "stream-1",
                "account_id" => "acc-1",
                "description" => "NETFLIX",
                "merchant_name" => "Netflix",
                "frequency" => "MONTHLY",
                "average_amount" => %{"amount" => 15.99, "iso_currency_code" => "USD"}
              }
            ],
            "updated_datetime" => "2024-01-15T10:00:00Z",
            "request_id" => "req_test"
          })
        )
      end)

      {:ok, result} =
        Transactions.get_recurring(config,
          access_token: "access-test",
          account_ids: ["acc-1"]
        )

      assert is_map(result)
      assert result["outflow_streams"] != nil
    end
  end

  describe "refresh/2" do
    test "triggers async data refresh", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/transactions/refresh", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{"request_id" => "req_refresh"}))
      end)

      {:ok, result} = Transactions.refresh(config, "access-test")
      assert result["request_id"] == "req_refresh"
    end
  end
end

defmodule PlaidEx.API.AccountsTest do
  use ExUnit.Case, async: true

  import PlaidEx.Test.BypassHelpers

  alias PlaidEx.API.Accounts
  alias PlaidEx.Schemas.Account

  setup do: bypass_setup(retry_max_attempts: 0)

  describe "get/3" do
    test "returns typed account structs", %{bypass: bypass, config: config} do
      stub_get_accounts(bypass)

      {:ok, result} = Accounts.get(config, "access-test")

      assert length(result.accounts) == 2
      assert Enum.all?(result.accounts, fn a -> match?(%Account{}, a) end)

      [checking, savings] = result.accounts
      assert checking.type == :depository
      assert checking.subtype == :checking
      assert checking.balances.available == 1250.00
      assert savings.subtype == :savings
    end

    test "filters by account_ids when provided", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/accounts/get", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)

        assert decoded["options"]["account_ids"] == ["acc-1"]

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(accounts_fixture()))
      end)

      Accounts.get(config, "access-test", account_ids: ["acc-1"])
    end
  end

  describe "get_balance/3" do
    test "returns real-time balances", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/accounts/balance/get", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(accounts_fixture()))
      end)

      {:ok, result} = Accounts.get_balance(config, "access-test")
      assert result.accounts != []
    end
  end
end

defmodule PlaidEx.API.ItemsTest do
  use ExUnit.Case, async: true

  import PlaidEx.Test.BypassHelpers

  alias PlaidEx.API.Items
  alias PlaidEx.Schemas.AccessToken
  alias PlaidEx.Schemas.Item

  setup do: bypass_setup(retry_max_attempts: 0)

  describe "exchange_public_token/3" do
    test "returns typed access token response", %{bypass: bypass, config: config} do
      stub_exchange_public_token(bypass)

      {:ok, result} = Items.exchange_public_token(config, "public-test-token")

      assert %AccessToken{} = result
      assert result.access_token == "access-sandbox-test-access-token"
      assert result.item_id == "item-sandbox-test-item-id"
    end

    test "returns error for invalid public token", %{bypass: bypass, config: config} do
      stub_error(bypass, "/item/public_token/exchange", "INVALID_PUBLIC_TOKEN", status: 400)

      {:error, error} = Items.exchange_public_token(config, "bad-token")
      assert error.code == "INVALID_PUBLIC_TOKEN"
      assert error.retryable == false
    end
  end

  describe "get/3" do
    test "returns typed item", %{bypass: bypass, config: config} do
      stub_get_item(bypass)

      {:ok, result} = Items.get(config, "access-test")

      assert %Item{} = result.item
      assert result.item.item_id == "item-sandbox-test-item-id"
      assert "auth" in result.item.available_products
    end
  end

  describe "remove/3" do
    test "removes item successfully", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/item/remove", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "removed" => true,
            "request_id" => "req_remove"
          })
        )
      end)

      {:ok, result} = Items.remove(config, "access-test")
      assert result["removed"] == true
    end
  end

  describe "create_processor_token/5" do
    test "creates a Dwolla processor token", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/processor/token/create", fn conn ->
        {:ok, body, _} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["processor"] == "dwolla"

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{
            "processor_token" => "processor-sandbox-dwolla-test",
            "request_id" => "req_proc"
          })
        )
      end)

      {:ok, result} =
        Items.create_processor_token(
          config,
          "access-test",
          "account-test",
          "dwolla"
        )

      assert result.processor_token == "processor-sandbox-dwolla-test"
    end
  end
end
