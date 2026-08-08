defmodule PlaidEx.Test.MockPlaidServer do
  @moduledoc """
  A complete mock Plaid API server for integration testing.

  Implements the full Plaid API contract using Bypass, returning
  realistic fixture data and supporting configurable error injection.

  ## Usage

      defmodule MyIntegrationTest do
        use ExUnit.Case
        use PlaidEx.Test.MockPlaidServer

        test "full link flow", %{config: config} do
          PlaidEx.Test.MockPlaidServer.stub_link_flow(bypass())

          {:ok, link} = PlaidEx.API.Link.create_token(config, ...)
          {:ok, tokens} = PlaidEx.API.Items.exchange_public_token(config, "public-...")
          {:ok, accounts} = PlaidEx.API.Accounts.get(config, tokens.access_token)

          assert accounts.accounts != []
        end
      end
  """

  alias PlaidEx.Test.BypassHelpers

  defmacro __using__(_) do
    quote do
      use ExUnit.Case, async: true
      import PlaidEx.Test.MockPlaidServer
      import PlaidEx.Test.BypassHelpers

      setup do
        bypass = Bypass.open()
        Process.put(:bypass, bypass)
        config = build_test_config(bypass)
        {:ok, bypass: bypass, config: config}
      end

      defp bypass, do: Process.get(:bypass)
    end
  end

  @doc "Builds a test config for a Bypass server."
  @spec build_test_config(Bypass.t()) :: PlaidEx.Config.t()
  def build_test_config(bypass) do
    BypassHelpers.test_config(bypass)
  end

  @doc "Stubs the complete Link + token exchange flow."
  @spec stub_link_flow(Bypass.t()) :: :ok
  def stub_link_flow(bypass) do
    BypassHelpers.stub_create_link_token(bypass)
    BypassHelpers.stub_exchange_public_token(bypass)
  end

  @doc "Stubs a complete account + transaction sync flow."
  @spec stub_accounts_and_sync(Bypass.t(), keyword()) :: :ok
  def stub_accounts_and_sync(bypass, opts \\ []) do
    BypassHelpers.stub_get_accounts(bypass)

    pages =
      Keyword.get(opts, :pages, [
        BypassHelpers.transactions_sync_fixture(has_more: true),
        BypassHelpers.transactions_sync_fixture(has_more: false)
      ])

    BypassHelpers.stub_transactions_sync_paginated(bypass, pages)
  end

  @doc "Stubs an ITEM_LOGIN_REQUIRED error on sync."
  @spec stub_item_login_required(Bypass.t()) :: :ok
  def stub_item_login_required(bypass) do
    Bypass.expect_once(bypass, "POST", "/transactions/sync", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        400,
        Jason.encode!(
          BypassHelpers.plaid_error_fixture("ITEM_LOGIN_REQUIRED",
            error_type: "ITEM_ERROR"
          )
        )
      )
    end)
  end

  @doc "Sets up a flaky endpoint that fails N times then succeeds."
  @spec stub_flaky(Bypass.t(), String.t(), non_neg_integer(), map()) :: :ok
  def stub_flaky(bypass, path, fail_count, success_response) do
    {:ok, agent} = Agent.start_link(fn -> 0 end)

    Bypass.expect(bypass, "POST", path, fn conn ->
      count = Agent.get_and_update(agent, fn c -> {c, c + 1} end)

      if count < fail_count do
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          500,
          Jason.encode!(BypassHelpers.plaid_error_fixture("INTERNAL_SERVER_ERROR"))
        )
      else
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(success_response))
      end
    end)
  end

  @doc "Generates a valid Plaid webhook payload for testing."
  @spec build_webhook(String.t(), String.t(), keyword()) :: map()
  def build_webhook(type, code, opts \\ []) do
    base = %{
      "webhook_type" => type,
      "webhook_code" => code,
      "item_id" => Keyword.get(opts, :item_id, "item-sandbox-test"),
      "environment" => "sandbox",
      "error" => Keyword.get(opts, :error)
    }

    case {type, code} do
      {"TRANSACTIONS", "SYNC_UPDATES_AVAILABLE"} ->
        Map.merge(base, %{
          "initial_update_complete" => true,
          "historical_update_complete" => true
        })

      {"TRANSFER", "TRANSFER_EVENTS_UPDATE"} ->
        base

      _ ->
        base
    end
  end

  @doc "Builds a raw HMAC-signed webhook for Plug testing."
  @spec build_signed_webhook(map(), String.t()) :: {binary(), String.t()}
  def build_signed_webhook(event, secret) do
    body = Jason.encode!(event)
    mac = :crypto.mac(:hmac, :sha256, secret, body)
    signature = Base.encode16(mac, case: :lower)
    {body, signature}
  end
end
