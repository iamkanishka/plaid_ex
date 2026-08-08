defmodule PlaidEx.Sync.TransactionSyncTest do
  use ExUnit.Case, async: false

  import PlaidEx.Test.BypassHelpers

  alias PlaidEx.Schemas.TransactionSyncPage
  alias PlaidEx.Sync.CursorStore
  alias PlaidEx.Sync.SyncSupervisor
  alias PlaidEx.Sync.TransactionSync

  setup do
    bypass = Bypass.open()
    config = test_config(bypass, retry_max_attempts: 0)
    # Clean up any lingering sync workers
    on_exit(fn ->
      # Give workers time to stop
      Process.sleep(50)
    end)

    {:ok, bypass: bypass, config: config}
  end

  describe "TransactionSyncPage.from_map/1" do
    test "parses a sync page with added transactions" do
      raw = %{
        "added" => [
          %{
            "transaction_id" => "txn-1",
            "account_id" => "acc-1",
            "amount" => 25.00,
            "date" => "2024-01-15",
            "name" => "Test Transaction",
            "pending" => false,
            "iso_currency_code" => "USD",
            "category" => ["Food and Drink"],
            "location" => %{},
            "payment_meta" => %{},
            "counterparties" => []
          }
        ],
        "modified" => [],
        "removed" => [%{"transaction_id" => "txn-old"}],
        "has_more" => false,
        "next_cursor" => "cursor-abc123",
        "request_id" => "req_test"
      }

      page = TransactionSyncPage.from_map(raw)

      assert length(page.added) == 1
      assert length(page.removed) == 1
      assert page.has_more == false
      assert page.next_cursor == "cursor-abc123"

      [tx] = page.added
      assert tx.transaction_id == "txn-1"
      assert tx.amount == 25.00
      assert tx.pending == false
    end

    test "handles empty arrays gracefully" do
      raw = %{
        "added" => [],
        "modified" => [],
        "removed" => [],
        "has_more" => false,
        "next_cursor" => "cursor-empty"
      }

      page = TransactionSyncPage.from_map(raw)
      assert page.added == []
      assert page.modified == []
      assert page.removed == []
    end

    test "marks removed transactions with transaction_id" do
      raw = %{
        "added" => [],
        "modified" => [],
        "removed" => [
          %{"transaction_id" => "removed-txn-1"},
          %{"transaction_id" => "removed-txn-2"}
        ],
        "has_more" => false,
        "next_cursor" => "cursor-x"
      }

      page = TransactionSyncPage.from_map(raw)
      assert length(page.removed) == 2
      assert hd(page.removed).transaction_id == "removed-txn-1"
    end
  end

  describe "CursorStore" do
    test "returns nil for unknown item" do
      assert CursorStore.get("nonexistent-item-id") == nil
    end

    test "stores and retrieves a cursor" do
      item_id = "test-item-#{:rand.uniform(100_000)}"
      cursor = "cursor-test-value"

      :ok = CursorStore.put(item_id, cursor)
      assert CursorStore.get(item_id) == cursor
    end

    test "deletes a cursor" do
      item_id = "test-item-delete-#{:rand.uniform(100_000)}"
      CursorStore.put(item_id, "cursor-to-delete")
      CursorStore.delete(item_id)
      assert CursorStore.get(item_id) == nil
    end

    test "overwrites existing cursor" do
      item_id = "test-item-overwrite-#{:rand.uniform(100_000)}"
      CursorStore.put(item_id, "cursor-v1")
      CursorStore.put(item_id, "cursor-v2")
      assert CursorStore.get(item_id) == "cursor-v2"
    end
  end

  describe "TransactionSync.trigger_sync/1" do
    test "returns error for unknown access token" do
      result = TransactionSync.trigger_sync("nonexistent-access-token")
      assert result == {:error, :not_found}
    end
  end

  describe "TransactionSync.stop_worker/1" do
    test "returns error for unknown access token" do
      result = TransactionSync.stop_worker("nonexistent-access-token")
      assert result == {:error, :not_found}
    end
  end

  describe "TransactionSync integration" do
    test "starts a worker and receives page via handler", %{bypass: bypass, config: config} do
      test_pid = self()
      access_token = "access-sandbox-sync-test-#{:rand.uniform(100_000)}"

      # Stub first sync page (has_more: false — no pagination)
      Bypass.expect_once(bypass, "POST", "/transactions/sync", fn conn ->
        body = %{
          "added" => [
            %{
              "transaction_id" => "txn-integration-1",
              "account_id" => "acc-1",
              "amount" => 10.00,
              "date" => "2024-01-15",
              "name" => "Test",
              "pending" => false,
              "iso_currency_code" => "USD",
              "category" => [],
              "location" => %{},
              "payment_meta" => %{},
              "counterparties" => []
            }
          ],
          "modified" => [],
          "removed" => [],
          "has_more" => false,
          "next_cursor" => "cursor-after-first-page"
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(body))
      end)

      handler = fn page ->
        send(test_pid, {:page_received, page})
        :ok
      end

      {:ok, _} =
        TransactionSync.start_worker(access_token, config,
          handler: handler,
          poll_interval_ms: 60_000
        )

      assert_receive {:page_received, page}, 2_000
      assert length(page.added) == 1
      assert hd(page.added).transaction_id == "txn-integration-1"
      assert page.next_cursor == "cursor-after-first-page"

      # Cursor should be persisted
      assert CursorStore.get(access_token) == "cursor-after-first-page"

      # Cleanup
      TransactionSync.stop_worker(access_token)
    end

    test "handles duplicate start gracefully", %{config: config} do
      access_token = "access-sandbox-dup-#{:rand.uniform(100_000)}"
      handler = fn _ -> :ok end

      # We need at least one bypass stub to prevent the worker from immediately failing
      # For this test we just care about the duplicate detection
      {:ok, _} =
        SyncSupervisor.start_worker(access_token, config,
          handler: handler,
          poll_interval_ms: 60_000
        )

      result = SyncSupervisor.start_worker(access_token, config, handler: handler)

      assert result == {:error, :already_started}

      TransactionSync.stop_worker(access_token)
    end
  end
end
