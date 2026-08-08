defmodule PlaidEx.SchemasTest do
  use ExUnit.Case, async: true

  alias PlaidEx.Schemas.AccessToken
  alias PlaidEx.Schemas.Account
  alias PlaidEx.Schemas.Institution
  alias PlaidEx.Schemas.Item
  alias PlaidEx.Schemas.LinkToken
  alias PlaidEx.Schemas.Transaction
  alias PlaidEx.Schemas.Transfer

  describe "Account.from_map/1" do
    test "parses depository checking account" do
      raw = %{
        "account_id" => "acc-check-123",
        "balances" => %{
          "available" => 1000.00,
          "current" => 1050.00,
          "limit" => nil,
          "iso_currency_code" => "USD",
          "unofficial_currency_code" => nil,
          "last_updated_datetime" => "2024-01-15T10:00:00Z"
        },
        "mask" => "1234",
        "name" => "My Checking",
        "official_name" => "Premium Checking Account",
        "type" => "depository",
        "subtype" => "checking",
        "verification_status" => nil,
        "persistent_account_id" => "persistent-abc"
      }

      account = Account.from_map(raw)

      assert account.account_id == "acc-check-123"
      assert account.type == :depository
      assert account.subtype == :checking
      assert account.mask == "1234"
      assert account.balances.available == 1000.00
      assert account.balances.current == 1050.00
      assert account.balances.iso_currency_code == "USD"
      assert account.persistent_account_id == "persistent-abc"
    end

    test "parses credit card account" do
      raw = %{
        "account_id" => "acc-cc-456",
        "balances" => %{
          "available" => nil,
          "current" => 500.00,
          "limit" => 5000.00,
          "iso_currency_code" => "USD"
        },
        "mask" => "5678",
        "name" => "My Credit Card",
        "official_name" => nil,
        "type" => "credit",
        "subtype" => "credit_card",
        "verification_status" => nil
      }

      account = Account.from_map(raw)
      assert account.type == :credit
      assert account.subtype == :credit_card
      assert account.balances.limit == 5000.00
    end

    test "handles unknown type gracefully" do
      raw = %{
        "account_id" => "acc-other",
        "balances" => %{},
        "name" => "Other Account",
        "type" => "some_future_type",
        "subtype" => nil
      }

      account = Account.from_map(raw)
      assert account.type == :other
      assert is_nil(account.subtype)
    end

    test "handles nil balances" do
      raw = %{
        "account_id" => "acc-nil-bal",
        "balances" => nil,
        "name" => "Test",
        "type" => "depository",
        "subtype" => "checking"
      }

      account = Account.from_map(raw)
      assert account.balances == %{}
    end
  end

  describe "Transaction.from_map/1" do
    test "parses a complete transaction" do
      raw = %{
        "transaction_id" => "txn-abc123",
        "account_id" => "acc-456",
        "amount" => 12.50,
        "iso_currency_code" => "USD",
        "category" => ["Food and Drink", "Restaurants", "Fast Food"],
        "category_id" => "13005032",
        "date" => "2024-01-15",
        "datetime" => "2024-01-15T14:30:00Z",
        "authorized_date" => "2024-01-15",
        "authorized_datetime" => "2024-01-15T14:29:00Z",
        "location" => %{"city" => "San Francisco", "region" => "CA"},
        "name" => "CHIPOTLE MEXICAN GRILL",
        "merchant_name" => "Chipotle Mexican Grill",
        "pending" => false,
        "pending_transaction_id" => nil,
        "logo_url" => "https://example.com/chipotle.png",
        "website" => "chipotle.com",
        "personal_finance_category" => %{
          "primary" => "FOOD_AND_DRINK",
          "detailed" => "FOOD_AND_DRINK_FAST_FOOD",
          "confidence_level" => "VERY_HIGH"
        },
        "payment_meta" => %{},
        "payment_channel" => "in store",
        "counterparties" => [],
        "merchant_entity_id" => "entity-chipotle"
      }

      tx = Transaction.from_map(raw)

      assert tx.transaction_id == "txn-abc123"
      assert tx.amount == 12.50
      assert tx.pending == false
      assert tx.merchant_name == "Chipotle Mexican Grill"
      assert tx.logo_url == "https://example.com/chipotle.png"
      assert tx.personal_finance_category["primary"] == "FOOD_AND_DRINK"
      assert tx.location["city"] == "San Francisco"
      assert tx.merchant_entity_id == "entity-chipotle"
    end

    test "defaults pending to false when nil" do
      raw = %{
        "transaction_id" => "txn-nil-pending",
        "account_id" => "acc-1",
        "amount" => 5.00,
        "date" => "2024-01-01",
        "name" => "Test",
        "pending" => nil,
        "category" => [],
        "location" => %{},
        "payment_meta" => %{},
        "counterparties" => []
      }

      tx = Transaction.from_map(raw)
      assert tx.pending == false
    end
  end

  describe "Institution.from_map/1" do
    test "parses institution with OAuth support" do
      raw = %{
        "institution_id" => "ins_chase",
        "name" => "Chase",
        "products" => ["auth", "transactions", "identity"],
        "country_codes" => ["US"],
        "routing_numbers" => ["021000021"],
        "oauth" => true,
        "status" => %{"transactions" => %{"status" => "HEALTHY"}},
        "primary_color" => "#117ACA",
        "logo" => "base64_logo_data",
        "url" => "https://chase.com",
        "dtc_numbers" => []
      }

      inst = Institution.from_map(raw)

      assert inst.institution_id == "ins_chase"
      assert inst.name == "Chase"
      assert inst.oauth == true
      assert "auth" in inst.products
      assert inst.primary_color == "#117ACA"
    end
  end

  describe "Transfer.from_map/1" do
    test "parses a pending transfer" do
      raw = %{
        "id" => "transfer-abc",
        "ach_class" => "ppd",
        "account_id" => "acc-123",
        "type" => "debit",
        "user" => %{"legal_name" => "John Doe"},
        "amount" => "150.00",
        "iso_currency_code" => "USD",
        "description" => "Monthly subscription",
        "created" => "2024-01-15T00:00:00Z",
        "status" => "pending",
        "network" => "ach",
        "cancellable" => true,
        "failure_reason" => nil,
        "metadata" => %{"order_id" => "order-xyz"},
        "authorization_id" => "auth-789"
      }

      transfer = Transfer.from_map(raw)

      assert transfer.id == "transfer-abc"
      assert transfer.status == "pending"
      assert transfer.cancellable == true
      assert transfer.metadata["order_id"] == "order-xyz"
      assert transfer.authorization_id == "auth-789"
    end
  end

  describe "Item.from_map/1" do
    test "parses item with available products" do
      raw = %{
        "item_id" => "item-xyz",
        "institution_id" => "ins_chase",
        "webhook" => "https://myapp.com/webhooks/plaid",
        "error" => nil,
        "available_products" => ["auth", "transactions", "investments"],
        "billed_products" => ["transactions"],
        "consent_expiration_time" => "2025-01-01T00:00:00Z",
        "update_type" => "background"
      }

      item = Item.from_map(raw)

      assert item.item_id == "item-xyz"
      assert item.institution_id == "ins_chase"
      assert "auth" in item.available_products
      assert "transactions" in item.billed_products
      assert item.consent_expiration_time == "2025-01-01T00:00:00Z"
    end
  end

  describe "LinkToken.from_map/1" do
    test "parses link token response" do
      raw = %{
        "link_token" => "link-sandbox-abc123",
        "expiration" => "2024-01-15T16:00:00Z",
        "request_id" => "req_link_create"
      }

      token = LinkToken.from_map(raw)
      assert token.link_token == "link-sandbox-abc123"
      assert token.expiration == "2024-01-15T16:00:00Z"
      assert token.request_id == "req_link_create"
    end
  end

  describe "AccessToken.from_map/1" do
    test "parses access token response" do
      raw = %{
        "access_token" => "access-sandbox-xyz789",
        "item_id" => "item-test-123",
        "request_id" => "req_exchange"
      }

      token = AccessToken.from_map(raw)
      assert token.access_token == "access-sandbox-xyz789"
      assert token.item_id == "item-test-123"
    end
  end
end
