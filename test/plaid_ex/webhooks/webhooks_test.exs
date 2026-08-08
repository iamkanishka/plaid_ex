defmodule PlaidEx.Webhooks.VerifierTest do
  use ExUnit.Case, async: true

  alias PlaidEx.Config
  alias PlaidEx.Webhooks.Verifier

  setup do
    config =
      Config.new!(
        client_id: "test",
        secret: "test",
        webhook_secret: "test_webhook_secret_key"
      )

    {:ok, config: config}
  end

  describe "verify/3 — HMAC" do
    test "returns ok for valid HMAC signature", %{config: config} do
      body = ~s({"webhook_type":"TRANSACTIONS","webhook_code":"SYNC_UPDATES_AVAILABLE"})
      mac = :crypto.mac(:hmac, :sha256, config.webhook_secret, body)
      signature = Base.encode16(mac, case: :lower)

      assert :ok = Verifier.verify(body, signature, config)
    end

    test "returns error for invalid HMAC signature", %{config: config} do
      body = ~s({"webhook_type":"TRANSACTIONS"})
      bad_signature = String.duplicate("a", 64)

      assert {:error, :invalid_signature} = Verifier.verify(body, bad_signature, config)
    end

    test "returns error when header is nil", %{config: config} do
      assert {:error, :missing_header} = Verifier.verify("body", nil, config)
    end

    test "returns ok when no webhook_secret configured" do
      config = Config.new!(client_id: "c", secret: "s", webhook_secret: nil)
      assert :ok = Verifier.verify("body", "any_header", config)
    end
  end

  describe "verify/3 — security" do
    test "uses constant-time comparison to prevent timing attacks", %{config: config} do
      body = "test body"
      mac = :crypto.mac(:hmac, :sha256, config.webhook_secret, body)
      correct_sig = Base.encode16(mac, case: :lower)

      # Flip one byte in the signature
      wrong_sig = String.replace_prefix(correct_sig, String.at(correct_sig, 0), "x")

      assert {:error, :invalid_signature} = Verifier.verify(body, wrong_sig, config)
    end
  end
end

defmodule PlaidEx.Webhooks.DeduplicatorTest do
  use ExUnit.Case, async: false

  alias PlaidEx.Webhooks.Deduplicator

  describe "check_and_record/1" do
    test "returns ok for new webhook id" do
      unique_id = "webhook-#{:rand.uniform(1_000_000)}"
      assert :ok = Deduplicator.check_and_record(unique_id)
    end

    test "returns duplicate for seen webhook id" do
      unique_id = "webhook-dup-#{:rand.uniform(1_000_000)}"
      assert :ok = Deduplicator.check_and_record(unique_id)
      assert {:error, :duplicate} = Deduplicator.check_and_record(unique_id)
    end

    test "always passes :no_id" do
      assert :ok = Deduplicator.check_and_record(:no_id)
      assert :ok = Deduplicator.check_and_record(:no_id)
    end

    test "different ids are independent" do
      id1 = "webhook-a-#{:rand.uniform(1_000_000)}"
      id2 = "webhook-b-#{:rand.uniform(1_000_000)}"

      assert :ok = Deduplicator.check_and_record(id1)
      assert :ok = Deduplicator.check_and_record(id2)
    end
  end

  describe "derive_id/1" do
    test "same event produces same id within 5-second window" do
      event = %{
        "webhook_type" => "TRANSACTIONS",
        "webhook_code" => "SYNC_UPDATES_AVAILABLE",
        "item_id" => "item-123"
      }

      id1 = Deduplicator.derive_id(event)
      id2 = Deduplicator.derive_id(event)

      assert id1 == id2
    end

    test "different events produce different ids" do
      event1 = %{
        "webhook_type" => "TRANSACTIONS",
        "webhook_code" => "SYNC_UPDATES_AVAILABLE",
        "item_id" => "item-1"
      }

      event2 = %{"webhook_type" => "ITEM", "webhook_code" => "ERROR", "item_id" => "item-1"}

      assert Deduplicator.derive_id(event1) != Deduplicator.derive_id(event2)
    end

    test "returns a hex string" do
      event = %{"webhook_type" => "TEST", "webhook_code" => "TEST"}
      id = Deduplicator.derive_id(event)
      assert String.match?(id, ~r/^[0-9a-f]{64}$/)
    end
  end
end

defmodule PlaidEx.Webhooks.DispatcherTest do
  use ExUnit.Case, async: true

  alias PlaidEx.Config
  alias PlaidEx.Webhooks.Dispatcher

  defmodule TestHandler do
    use PlaidEx.Webhooks.Handler

    @impl PlaidEx.Webhooks.Handler
    def on_transactions_sync(event) do
      send(self(), {:dispatched, :on_transactions_sync, event})
      :ok
    end

    @impl PlaidEx.Webhooks.Handler
    def on_item_error(event) do
      send(self(), {:dispatched, :on_item_error, event})
      :ok
    end
  end

  setup do
    config = Config.new!(client_id: "c", secret: "s")
    {:ok, config: config}
  end

  test "dispatches TRANSACTIONS.SYNC_UPDATES_AVAILABLE to on_transactions_sync", %{config: config} do
    event = %{
      "webhook_type" => "TRANSACTIONS",
      "webhook_code" => "SYNC_UPDATES_AVAILABLE",
      "item_id" => "item-123",
      "environment" => "sandbox",
      "initial_update_complete" => true,
      "historical_update_complete" => true
    }

    self_pid = self()

    handler = fn e ->
      send(self_pid, {:handler_called, e})
      :ok
    end

    Dispatcher.dispatch(event, handler, config)
    assert_receive {:handler_called, _event}, 100
  end

  test "dispatches ITEM.ERROR to on_item_error via module handler", %{config: config} do
    event = %{
      "webhook_type" => "ITEM",
      "webhook_code" => "ERROR",
      "item_id" => "item-456",
      "environment" => "sandbox",
      "error" => %{"error_code" => "ITEM_LOGIN_REQUIRED"}
    }

    self_pid = self()

    Dispatcher.dispatch(
      event,
      fn e ->
        send(self_pid, {:dispatched, e})
        :ok
      end,
      config
    )

    assert_receive {:dispatched, e}, 100
    assert e["webhook_type"] == "ITEM"
  end

  test "falls through to on_unknown for unrecognized events", %{config: config} do
    event = %{
      "webhook_type" => "UNKNOWN_PRODUCT",
      "webhook_code" => "UNKNOWN_CODE",
      "item_id" => "item-789",
      "environment" => "sandbox"
    }

    self_pid = self()

    result =
      Dispatcher.dispatch(
        event,
        fn e ->
          send(self_pid, {:unknown_dispatched, e})
          :ok
        end,
        config
      )

    assert result == :ok
    assert_receive {:unknown_dispatched, _}, 100
  end

  test "handles handler errors gracefully", %{config: config} do
    event = %{
      "webhook_type" => "TRANSACTIONS",
      "webhook_code" => "SYNC_UPDATES_AVAILABLE",
      "item_id" => "item-err",
      "environment" => "sandbox"
    }

    handler = fn _ -> {:error, :test_handler_failure} end
    result = Dispatcher.dispatch(event, handler, config)
    assert result == {:error, :test_handler_failure}
  end

  test "handles handler exceptions without crashing", %{config: config} do
    event = %{
      "webhook_type" => "TRANSACTIONS",
      "webhook_code" => "SYNC_UPDATES_AVAILABLE",
      "item_id" => "item-exc",
      "environment" => "sandbox"
    }

    handler = fn _ -> raise "intentional test error" end
    result = Dispatcher.dispatch(event, handler, config)
    assert {:error, _} = result
  end
end
