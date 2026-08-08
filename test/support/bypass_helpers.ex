defmodule PlaidEx.Test.BypassHelpers do
  @moduledoc """
  Helpers for setting up Bypass HTTP stubs in tests.

  Provides pre-built stubs for all common Plaid API endpoints,
  plus helpers for simulating errors and edge cases.

  ## Usage

      defmodule MyTest do
        use ExUnit.Case
        use PlaidEx.Test.BypassHelpers

        setup do
          bypass = Bypass.open()
          config = test_config(bypass)
          {:ok, bypass: bypass, config: config}
        end

        test "fetches accounts", %{bypass: bypass, config: config} do
          stub_get_accounts(bypass)

          {:ok, result} = PlaidEx.API.Accounts.get(config, "access-sandbox-test")
          assert length(result.accounts) > 0
        end
      end
  """

  defmacro __using__(_) do
    quote do
      import PlaidEx.Test.BypassHelpers
    end
  end

  # Fixture builders below (`link_token_fixture/0` through
  # `transfer_fixture/0`) each unconditionally return one fixed, literal
  # map with known string keys. Dialyzer traces that literal shape as
  # their success typing, which is strictly narrower than anything
  # expressible as a source-level `@spec` — Elixir/Erlang typespecs can
  # only pin exact ("singleton") literal values for atom or integer map
  # keys, not binary/string keys, so `map()` (or any hand-written
  # string-keyed map type) is necessarily a supertype of what dialyzer
  # infers. This mirrors the documented rationale in
  # `PlaidEx.HTTP.Client` and `.dialyzer_ignore.exs` for preferring a
  # scoped attribute over an unwritable/misleading spec.
  @dialyzer {:nowarn_function,
             [
               link_token_fixture: 0,
               exchange_token_fixture: 0,
               accounts_fixture: 0,
               transactions_sync_fixture: 1,
               transaction_fixture: 1,
               item_fixture: 0,
               auth_fixture: 0,
               identity_fixture: 0,
               holdings_fixture: 0,
               transfer_authorization_fixture: 0,
               transfer_fixture: 0
             ]}

  @doc """
  Standard ExUnit setup — opens a Bypass server and builds a matching
  test config. Use as `setup do: bypass_setup()` or
  `setup do: bypass_setup(retry_max_attempts: 0)`.
  """
  @spec bypass_setup(keyword()) :: {:ok, bypass: Bypass.t(), config: PlaidEx.Config.t()}
  def bypass_setup(opts \\ []) do
    bypass = Bypass.open()
    config = test_config(bypass, opts)
    {:ok, bypass: bypass, config: config}
  end

  @doc "Returns a test PlaidEx.Config pointing at a Bypass server."
  @spec test_config(Bypass.t(), keyword()) :: PlaidEx.Config.t()
  def test_config(bypass, opts \\ []) do
    defaults = [
      client_id: "test_client_id",
      secret: "test_secret",
      environment: :sandbox,
      retry_max_attempts: 0,
      request_timeout_ms: 5_000
    ]

    merged_opts = Keyword.merge(defaults, opts)
    config = PlaidEx.Config.new!(merged_opts)
    with_bypass_url(config, bypass)
  end

  # ── Stub builders ────────────────────────────────────────────────────────────

  @doc "Stubs POST /link/token/create"
  @spec stub_create_link_token(Bypass.t(), keyword()) :: :ok
  def stub_create_link_token(bypass, opts \\ []) do
    response = Keyword.get(opts, :response, link_token_fixture())
    status = Keyword.get(opts, :status, 200)

    Bypass.expect_once(bypass, "POST", "/link/token/create", fn conn ->
      send_json(conn, status, response)
    end)
  end

  @doc "Stubs POST /item/public_token/exchange"
  @spec stub_exchange_public_token(Bypass.t(), keyword()) :: :ok
  def stub_exchange_public_token(bypass, opts \\ []) do
    response = Keyword.get(opts, :response, exchange_token_fixture())
    status = Keyword.get(opts, :status, 200)

    Bypass.expect_once(bypass, "POST", "/item/public_token/exchange", fn conn ->
      send_json(conn, status, response)
    end)
  end

  @doc "Stubs POST /accounts/get"
  @spec stub_get_accounts(Bypass.t(), keyword()) :: :ok
  def stub_get_accounts(bypass, opts \\ []) do
    response = Keyword.get(opts, :response, accounts_fixture())
    status = Keyword.get(opts, :status, 200)

    Bypass.expect_once(bypass, "POST", "/accounts/get", fn conn ->
      send_json(conn, status, response)
    end)
  end

  @doc "Stubs POST /transactions/sync"
  @spec stub_transactions_sync(Bypass.t(), keyword()) :: :ok
  def stub_transactions_sync(bypass, opts \\ []) do
    response = Keyword.get(opts, :response, transactions_sync_fixture())
    status = Keyword.get(opts, :status, 200)

    Bypass.expect_once(bypass, "POST", "/transactions/sync", fn conn ->
      send_json(conn, status, response)
    end)
  end

  @doc "Stubs repeated POST /transactions/sync calls for pagination testing."
  @spec stub_transactions_sync_paginated(Bypass.t(), [map()]) :: :ok
  def stub_transactions_sync_paginated(bypass, pages) do
    Enum.each(pages, fn page ->
      Bypass.expect_once(bypass, "POST", "/transactions/sync", fn conn ->
        send_json(conn, 200, page)
      end)
    end)
  end

  @doc "Stubs an error response."
  @spec stub_error(Bypass.t(), String.t(), String.t(), keyword()) :: :ok
  def stub_error(bypass, path, error_code, opts \\ []) do
    status = Keyword.get(opts, :status, 400)
    method = Keyword.get(opts, :method, "POST")

    Bypass.expect_once(bypass, method, path, fn conn ->
      send_json(conn, status, plaid_error_fixture(error_code))
    end)
  end

  @doc "Stubs a 500 error (triggers retry logic)."
  @spec stub_server_error(Bypass.t(), String.t(), keyword()) :: :ok
  def stub_server_error(bypass, path, opts \\ []) do
    stub_error(bypass, path, "INTERNAL_SERVER_ERROR", Keyword.put(opts, :status, 500))
  end

  @doc "Stubs a rate limit error."
  @spec stub_rate_limit(Bypass.t(), String.t()) :: :ok
  def stub_rate_limit(bypass, path) do
    Bypass.expect_once(bypass, "POST", path, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("retry-after", "1")
      |> send_json(429, plaid_error_fixture("RATE_LIMIT_EXCEEDED"))
    end)
  end

  @doc "Stubs a network timeout (Bypass closes the connection)."
  @spec stub_timeout(Bypass.t(), String.t()) :: :ok
  def stub_timeout(bypass, path) do
    Bypass.expect_once(bypass, "POST", path, fn _ ->
      Process.sleep(100_000)
    end)
  end

  @doc "Stubs POST /item/get"
  @spec stub_get_item(Bypass.t(), keyword()) :: :ok
  def stub_get_item(bypass, opts \\ []) do
    Bypass.expect_once(bypass, "POST", "/item/get", fn conn ->
      send_json(conn, 200, Keyword.get(opts, :response, item_fixture()))
    end)
  end

  @doc "Stubs POST /auth/get"
  @spec stub_get_auth(Bypass.t(), keyword()) :: :ok
  def stub_get_auth(bypass, opts \\ []) do
    Bypass.expect_once(bypass, "POST", "/auth/get", fn conn ->
      send_json(conn, 200, Keyword.get(opts, :response, auth_fixture()))
    end)
  end

  @doc "Stubs POST /identity/get"
  @spec stub_get_identity(Bypass.t(), keyword()) :: :ok
  def stub_get_identity(bypass, opts \\ []) do
    Bypass.expect_once(bypass, "POST", "/identity/get", fn conn ->
      send_json(conn, 200, Keyword.get(opts, :response, identity_fixture()))
    end)
  end

  @doc "Stubs POST /investments/holdings/get"
  @spec stub_get_holdings(Bypass.t(), keyword()) :: :ok
  def stub_get_holdings(bypass, opts \\ []) do
    Bypass.expect_once(bypass, "POST", "/investments/holdings/get", fn conn ->
      send_json(conn, 200, Keyword.get(opts, :response, holdings_fixture()))
    end)
  end

  @doc "Stubs POST /transfer/authorization/create"
  @spec stub_transfer_authorize(Bypass.t(), keyword()) :: :ok
  def stub_transfer_authorize(bypass, opts \\ []) do
    Bypass.expect_once(bypass, "POST", "/transfer/authorization/create", fn conn ->
      send_json(conn, 200, Keyword.get(opts, :response, transfer_authorization_fixture()))
    end)
  end

  @doc "Stubs POST /transfer/create"
  @spec stub_transfer_create(Bypass.t(), keyword()) :: :ok
  def stub_transfer_create(bypass, opts \\ []) do
    Bypass.expect_once(bypass, "POST", "/transfer/create", fn conn ->
      send_json(conn, 200, Keyword.get(opts, :response, transfer_fixture()))
    end)
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────────

  @spec link_token_fixture() :: map()
  def link_token_fixture do
    %{
      "link_token" => "link-sandbox-test-token",
      "expiration" => "2099-01-01T00:00:00Z",
      "request_id" => "req_test_link"
    }
  end

  @spec exchange_token_fixture() :: map()
  def exchange_token_fixture do
    %{
      "access_token" => "access-sandbox-test-access-token",
      "item_id" => "item-sandbox-test-item-id",
      "request_id" => "req_test_exchange"
    }
  end

  @spec accounts_fixture() :: map()
  def accounts_fixture do
    %{
      "accounts" => [
        %{
          "account_id" => "account-test-checking",
          "balances" => %{
            "available" => 1250.00,
            "current" => 1250.00,
            "limit" => nil,
            "iso_currency_code" => "USD"
          },
          "mask" => "1234",
          "name" => "Plaid Checking",
          "official_name" => "Plaid Gold Standard 0% Interest Checking",
          "type" => "depository",
          "subtype" => "checking",
          "verification_status" => nil
        },
        %{
          "account_id" => "account-test-savings",
          "balances" => %{
            "available" => 5100.00,
            "current" => 5100.00,
            "limit" => nil,
            "iso_currency_code" => "USD"
          },
          "mask" => "5678",
          "name" => "Plaid Saving",
          "official_name" => "Plaid Silver Standard 0.1% Interest Saving",
          "type" => "depository",
          "subtype" => "savings",
          "verification_status" => nil
        }
      ],
      "item" => item_fixture()["item"],
      "request_id" => "req_test_accounts"
    }
  end

  @spec transactions_sync_fixture(keyword()) :: map()
  def transactions_sync_fixture(opts \\ []) do
    has_more = Keyword.get(opts, :has_more, false)
    cursor = Keyword.get(opts, :cursor, "cursor-test-next-page-token")
    added = Keyword.get(opts, :added, [transaction_fixture()])

    %{
      "added" => added,
      "modified" => [],
      "removed" => [],
      "has_more" => has_more,
      "next_cursor" => cursor,
      "request_id" => "req_test_sync"
    }
  end

  @spec transaction_fixture(keyword()) :: map()
  def transaction_fixture(opts \\ []) do
    %{
      "transaction_id" => Keyword.get(opts, :id, "txn-test-#{:rand.uniform(100_000)}"),
      "account_id" => "account-test-checking",
      "amount" => 25.00,
      "iso_currency_code" => "USD",
      "category" => ["Food and Drink", "Restaurants"],
      "category_id" => "13005000",
      "date" => "2024-01-15",
      "datetime" => "2024-01-15T12:34:56Z",
      "name" => "CHIPOTLE 1234",
      "merchant_name" => "Chipotle",
      "pending" => false,
      "logo_url" => "https://plaid-merchant-logos.plaid.com/chipotle.png",
      "website" => "chipotle.com",
      "personal_finance_category" => %{
        "primary" => "FOOD_AND_DRINK",
        "detailed" => "FOOD_AND_DRINK_FAST_FOOD",
        "confidence_level" => "VERY_HIGH"
      },
      "payment_channel" => "in store",
      "location" => %{
        "address" => "1 Chipotle Way",
        "city" => "San Francisco",
        "region" => "CA",
        "postal_code" => "94105",
        "country" => "US"
      },
      "payment_meta" => %{},
      "counterparties" => []
    }
  end

  @spec item_fixture() :: map()
  def item_fixture do
    %{
      "item" => %{
        "item_id" => "item-sandbox-test-item-id",
        "institution_id" => "ins_109508",
        "webhook" => nil,
        "error" => nil,
        "available_products" => ["auth", "balance", "identity", "transactions"],
        "billed_products" => ["transactions"],
        "consent_expiration_time" => nil,
        "update_type" => "background"
      },
      "status" => %{},
      "request_id" => "req_test_item"
    }
  end

  @spec auth_fixture() :: map()
  def auth_fixture do
    %{
      "accounts" => [
        %{
          "account_id" => "account-test-checking",
          "balances" => %{"available" => 1250.00, "current" => 1250.00},
          "mask" => "1234",
          "name" => "Plaid Checking",
          "type" => "depository",
          "subtype" => "checking"
        }
      ],
      "numbers" => %{
        "ach" => [
          %{
            "account" => "9900009606",
            "account_id" => "account-test-checking",
            "routing" => "011401533",
            "wire_routing" => "021000021"
          }
        ],
        "eft" => [],
        "international" => [],
        "bacs" => []
      },
      "item" => item_fixture()["item"],
      "request_id" => "req_test_auth"
    }
  end

  @spec identity_fixture() :: map()
  def identity_fixture do
    %{
      "accounts" => [
        %{
          "account_id" => "account-test-checking",
          "owners" => [
            %{
              "names" => ["Alberta Bobbeth Charleson"],
              "phone_numbers" => [%{"data" => "4673956022", "primary" => true, "type" => "home"}],
              "emails" => [
                %{"data" => "accountholder0@example.com", "primary" => true, "type" => "primary"}
              ],
              "addresses" => [
                %{
                  "data" => %{
                    "city" => "San Matias",
                    "region" => "CA",
                    "street" => "2992 Cameron Road",
                    "postal_code" => "93458",
                    "country" => "US"
                  },
                  "primary" => true
                }
              ]
            }
          ]
        }
      ],
      "item" => item_fixture()["item"],
      "request_id" => "req_test_identity"
    }
  end

  @spec holdings_fixture() :: map()
  def holdings_fixture do
    %{
      "holdings" => [
        %{
          "account_id" => "account-test-brokerage",
          "security_id" => "security-test-aapl",
          "institution_price" => 185.43,
          "institution_price_as_of" => "2024-01-15",
          "institution_value" => 1854.30,
          "cost_basis" => 150.00,
          "quantity" => 10.0,
          "iso_currency_code" => "USD"
        }
      ],
      "securities" => [
        %{
          "security_id" => "security-test-aapl",
          "isin" => "US0378331005",
          "cusip" => "037833100",
          "name" => "Apple Inc.",
          "ticker_symbol" => "AAPL",
          "is_cash_equivalent" => false,
          "type" => "equity",
          "close_price" => 185.43,
          "close_price_as_of" => "2024-01-15",
          "iso_currency_code" => "USD"
        }
      ],
      "accounts" => [],
      "item" => item_fixture()["item"],
      "request_id" => "req_test_holdings"
    }
  end

  @spec transfer_authorization_fixture() :: map()
  def transfer_authorization_fixture do
    %{
      "authorization" => %{
        "id" => "auth-test-id",
        "created" => "2024-01-15T12:00:00Z",
        "decision" => "approved",
        "decision_rationale" => nil,
        "guarantee_decision" => nil,
        "guarantee_decision_rationale" => nil,
        "proposed_transfer" => %{
          "ach_class" => "ppd",
          "account_id" => "account-test-checking",
          "type" => "debit",
          "user" => %{"legal_name" => "Test User"},
          "amount" => "100.00",
          "network" => "ach",
          "origination_account_id" => nil
        }
      },
      "request_id" => "req_test_auth_create"
    }
  end

  @spec transfer_fixture() :: map()
  def transfer_fixture do
    %{
      "transfer" => %{
        "id" => "transfer-test-id",
        "ach_class" => "ppd",
        "account_id" => "account-test-checking",
        "type" => "debit",
        "user" => %{"legal_name" => "Test User"},
        "amount" => "100.00",
        "iso_currency_code" => "USD",
        "description" => "Test transfer",
        "created" => "2024-01-15T12:00:00Z",
        "status" => "pending",
        "network" => "ach",
        "cancellable" => true,
        "failure_reason" => nil,
        "metadata" => %{},
        "origination_account_id" => nil,
        "guarantee_decision" => nil,
        "authorization_id" => "auth-test-id"
      },
      "request_id" => "req_test_transfer"
    }
  end

  @spec plaid_error_fixture(String.t(), keyword()) :: map()
  def plaid_error_fixture(error_code, opts \\ []) do
    %{
      "error_type" => Keyword.get(opts, :error_type, "API_ERROR"),
      "error_code" => error_code,
      "error_message" => Keyword.get(opts, :message, "Test error: #{error_code}"),
      "display_message" => nil,
      "request_id" => "req_test_error",
      "causes" => []
    }
  end

  @spec webhook_fixture(String.t(), String.t(), keyword()) :: map()
  def webhook_fixture(type, code, opts \\ []) do
    %{
      "webhook_type" => type,
      "webhook_code" => code,
      "item_id" => Keyword.get(opts, :item_id, "item-sandbox-test"),
      "environment" => "sandbox"
    }
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp with_bypass_url(config, bypass) do
    url = "http://localhost:#{bypass.port}"

    # Override the base URL resolution by patching the Finch pool.
    # In tests, we intercept at the config level.
    %{config | metadata: Map.put(config.metadata, :bypass_url, url)}
  end
end
