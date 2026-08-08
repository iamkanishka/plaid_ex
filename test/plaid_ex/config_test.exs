defmodule PlaidEx.ConfigTest do
  use ExUnit.Case, async: true
  doctest PlaidEx.Config

  alias PlaidEx.Config

  describe "new!/1" do
    test "creates config with required fields" do
      config = Config.new!(client_id: "cid", secret: "sec")
      assert config.client_id == "cid"
      assert config.secret == "sec"
      assert config.environment == :sandbox
      assert config.region == :us
    end

    test "creates config with all options" do
      config =
        Config.new!(
          client_id: "cid",
          secret: "sec",
          environment: :production,
          region: :eu,
          pool_size: 50,
          retry_max_attempts: 5,
          webhook_secret: "whsec_test"
        )

      assert config.environment == :production
      assert config.region == :eu
      assert config.pool_size == 50
      assert config.retry_max_attempts == 5
      assert config.webhook_secret == "whsec_test"
    end

    test "raises ArgumentError on missing client_id" do
      assert_raise ArgumentError, ~r/validation failed/, fn ->
        Config.new!(secret: "sec")
      end
    end

    test "raises ArgumentError on invalid environment" do
      assert_raise ArgumentError, ~r/validation failed/, fn ->
        Config.new!(client_id: "cid", secret: "sec", environment: :unknown)
      end
    end

    test "raises ArgumentError on invalid pool_size" do
      assert_raise ArgumentError, fn ->
        Config.new!(client_id: "cid", secret: "sec", pool_size: 0)
      end
    end
  end

  describe "base_url/1" do
    test "production US" do
      config = Config.new!(client_id: "c", secret: "s", environment: :production, region: :us)
      assert Config.base_url(config) == "https://production.plaid.com"
    end

    test "production EU" do
      config = Config.new!(client_id: "c", secret: "s", environment: :production, region: :eu)
      assert Config.base_url(config) == "https://production.eu.plaid.com"
    end

    test "production UK routes to EU" do
      config = Config.new!(client_id: "c", secret: "s", environment: :production, region: :uk)
      assert Config.base_url(config) == "https://production.eu.plaid.com"
    end

    test "sandbox" do
      config = Config.new!(client_id: "c", secret: "s", environment: :sandbox)
      assert Config.base_url(config) == "https://sandbox.plaid.com"
    end

    test "development" do
      config = Config.new!(client_id: "c", secret: "s", environment: :development)
      assert Config.base_url(config) == "https://development.plaid.com"
    end
  end

  describe "rotate_secret/2" do
    test "returns new config with updated secret" do
      config = Config.new!(client_id: "cid", secret: "old_secret")
      updated = Config.rotate_secret(config, "new_secret")

      assert updated.secret == "new_secret"
      assert updated.client_id == "cid"
    end
  end

  describe "production?/1" do
    test "returns true for production" do
      config = Config.new!(client_id: "c", secret: "s", environment: :production)
      assert Config.production?(config) == true
    end

    test "returns false for sandbox" do
      config = Config.new!(client_id: "c", secret: "s", environment: :sandbox)
      assert Config.production?(config) == false
    end
  end

  describe "scrub/1" do
    test "redacts secret" do
      config = Config.new!(client_id: "cid", secret: "supersecret")
      scrubbed = Config.scrub(config)

      assert scrubbed.secret == "[REDACTED]"
      assert scrubbed.client_id == "cid"
    end

    test "redacts webhook_secret when present" do
      config = Config.new!(client_id: "c", secret: "s", webhook_secret: "wh_secret")
      scrubbed = Config.scrub(config)

      assert scrubbed.webhook_secret == "[REDACTED]"
    end

    test "keeps webhook_secret nil when not set" do
      config = Config.new!(client_id: "c", secret: "s")
      scrubbed = Config.scrub(config)

      assert is_nil(scrubbed.webhook_secret)
    end
  end
end
