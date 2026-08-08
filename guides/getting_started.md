# Getting Started with PlaidEx

This guide walks you through a complete Plaid integration from zero to a
production-ready account linking and transaction sync setup.

## Prerequisites

- Elixir ~> 1.18 and OTP ~> 28
- A [Plaid account](https://dashboard.plaid.com/signup) with `client_id` and `secret`
- A Phoenix application (optional — PlaidEx works without Phoenix)

## Installation

Add PlaidEx to your `mix.exs`:

```elixir
def deps do
  [
    {:plaid_ex, "~> 0.1"},

    # Recommended for production webhooks
    {:oban, "~> 2.18"},

    # Optional for high-throughput sync pipelines
    {:broadway, "~> 1.1"},
    {:gen_stage, "~> 1.2"}
  ]
end
```

Run:

```bash
mix deps.get
```

## Configuration

### Development / sandbox

```elixir
# config/dev.exs
config :plaid_ex,
  client_id: System.get_env("PLAID_CLIENT_ID"),
  secret: System.get_env("PLAID_SECRET"),
  environment: :sandbox,
  region: :us
```

### Production (runtime.exs — preferred)

```elixir
# config/runtime.exs
if System.get_env("PLAID_CLIENT_ID") do
  config :plaid_ex,
    client_id: System.fetch_env!("PLAID_CLIENT_ID"),
    secret: System.fetch_env!("PLAID_SECRET"),
    environment: :production,
    region: :us,
    webhook_secret: System.fetch_env!("PLAID_WEBHOOK_SECRET"),
    pool_size: 30,
    pool_count: 4,
    retry_max_attempts: 3,
    sync_poll_interval_ms: 30_000
end
```

### Environment variables

```bash
export PLAID_CLIENT_ID="your-client-id"
export PLAID_SECRET="your-sandbox-secret"      # use sandbox secret for development
export PLAID_WEBHOOK_SECRET="your-webhook-secret"
```

## Starting the application

PlaidEx starts automatically as an OTP application. Nothing additional needed
in your `Application.start/2` unless you want telemetry:

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    # Attach PlaidEx telemetry (optional but recommended)
    PlaidEx.attach_telemetry(log_level: :info)

    children = [
      MyApp.Repo,
      MyAppWeb.Endpoint,
      # PlaidEx starts itself — no entry needed here
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
  end
end
```

## Step 1: Create a Link token

The Link token authorises a specific Link session. **Create it server-side** —
never expose your `client_id` or `secret` to the browser.

```elixir
defmodule MyAppWeb.PlaidController do
  use MyAppWeb, :controller

  def create_link_token(conn, _params) do
    user = conn.assigns.current_user

    case PlaidEx.create_link_token(
      user: %{client_user_id: to_string(user.id)},
      client_name: "Acme Finance",
      products: ["transactions"],
      country_codes: ["US"],
      language: "en",
      webhook: "https://yourapp.com/webhooks/plaid"
    ) do
      {:ok, link_token} ->
        json(conn, %{link_token: link_token.link_token})

      {:error, error} ->
        conn
        |> put_status(:internal_server_error)
        |> json(%{error: error.message})
    end
  end
end
```

## Step 2: Initialize Plaid Link (frontend)

```javascript
// Using @plaid/link (React example)
import { usePlaidLink } from 'react-plaid-link';

function ConnectBank({ linkToken, onSuccess }) {
  const { open } = usePlaidLink({
    token: linkToken,
    onSuccess: (publicToken, metadata) => {
      // POST the publicToken to your server
      onSuccess(publicToken, metadata);
    },
  });

  return <button onClick={open}>Connect Bank Account</button>;
}
```

## Step 3: Exchange the public token

```elixir
def exchange_token(conn, %{"public_token" => public_token}) do
  user = conn.assigns.current_user

  case PlaidEx.exchange_public_token(public_token) do
    {:ok, result} ->
      # Encrypt and store access_token — it's the permanent credential
      {:ok, item} = MyApp.PlaidItems.create(%{
        user_id: user.id,
        item_id: result.item_id,
        access_token: MyApp.Vault.encrypt!(result.access_token)
      })

      # Start syncing immediately
      start_sync(item)

      json(conn, %{success: true})

    {:error, error} ->
      conn
      |> put_status(:unprocessable_entity)
      |> json(%{error: error.message, code: error.code})
  end
end

defp start_sync(item) do
  access_token = MyApp.Vault.decrypt!(item.access_token)

  PlaidEx.start_transaction_sync(access_token,
    handler: fn page ->
      MyApp.Transactions.process_sync_page(item.id, page)
      :ok
    end
  )
end
```

## Step 4: Process transaction pages

```elixir
defmodule MyApp.Transactions do
  def process_sync_page(item_id, %PlaidEx.Schemas.TransactionSyncPage{} = page) do
    # All three operations should be idempotent
    # The handler may be called multiple times for the same page on restart

    Repo.transaction(fn ->
      # Upsert new/updated transactions
      Enum.each(page.added ++ page.modified, fn tx ->
        upsert_transaction(item_id, tx)
      end)

      # Remove deleted transactions
      Enum.each(page.removed, fn removed ->
        delete_transaction(item_id, removed.transaction_id)
      end)
    end)
  end

  defp upsert_transaction(item_id, %PlaidEx.Schemas.Transaction{} = tx) do
    Repo.insert!(
      %Transaction{
        item_id: item_id,
        plaid_transaction_id: tx.transaction_id,
        account_id: tx.account_id,
        amount: tx.amount,
        date: tx.date,
        name: tx.name,
        merchant_name: tx.merchant_name,
        category: tx.category,
        pending: tx.pending
      },
      on_conflict: {:replace_all_except, [:inserted_at]},
      conflict_target: :plaid_transaction_id
    )
  end

  defp delete_transaction(item_id, plaid_transaction_id) do
    Repo.delete_all(
      from t in Transaction,
        where: t.item_id == ^item_id and
               t.plaid_transaction_id == ^plaid_transaction_id
    )
  end
end
```

## Step 5: Handle webhooks

```elixir
# router.ex
pipeline :plaid_webhooks do
  plug :accepts, ["json"]
end

scope "/webhooks" do
  pipe_through :plaid_webhooks
  forward "/plaid", PlaidEx.Webhooks.Plug,
    config: PlaidEx.Config.load!(),
    handler: MyApp.PlaidWebhooks
end
```

```elixir
defmodule MyApp.PlaidWebhooks do
  use PlaidEx.Webhooks.Handler

  @impl true
  def on_transactions_sync(%{item_id: item_id}) do
    case MyApp.PlaidItems.get_by_item_id(item_id) do
      nil ->
        :ok  # Item not in our system — ignore

      item ->
        access_token = MyApp.Vault.decrypt!(item.access_token)
        PlaidEx.trigger_transaction_sync(access_token)
        :ok
    end
  end

  @impl true
  def on_item_error(%{item_id: item_id, error: error}) do
    MyApp.PlaidItems.mark_error(item_id, error["error_code"])

    case error["error_code"] do
      "ITEM_LOGIN_REQUIRED" ->
        MyApp.Notifications.notify_reconnect_required(item_id)
      _ ->
        MyApp.Alerts.notify(:plaid_item_error, %{item_id: item_id, error: error})
    end

    :ok
  end

  @impl true
  def on_item_pending_expiration(%{item_id: item_id}) do
    MyApp.Notifications.notify_expiring_connection(item_id)
    :ok
  end
end
```

## Step 6: Handle reconnection (update mode)

When an item enters `ITEM_LOGIN_REQUIRED`, create a Link token in update mode:

```elixir
def create_update_link_token(conn, %{"item_id" => item_id}) do
  user = conn.assigns.current_user
  item = MyApp.PlaidItems.get!(item_id, user_id: user.id)
  access_token = MyApp.Vault.decrypt!(item.access_token)

  case PlaidEx.create_link_token(
    user: %{client_user_id: to_string(user.id)},
    client_name: "Acme Finance",
    # Pass access_token instead of products to enter update mode
    access_token: access_token,
    country_codes: ["US"],
    language: "en"
  ) do
    {:ok, link_token} ->
      json(conn, %{link_token: link_token.link_token})
    {:error, error} ->
      json(conn, %{error: error.message})
  end
end
```

After the user re-authenticates, **no new public token exchange is needed** —
the same `access_token` continues to work.

## Verifying the setup

Run the Plaid sandbox test:

```elixir
# In iex -S mix:
config = PlaidEx.config()

# Create a test item without Link
{:ok, %{public_token: token}} = PlaidEx.API.Sandbox.create_public_token(config,
  institution_id: "ins_109508",
  initial_products: ["transactions"]
)

# Exchange it
{:ok, result} = PlaidEx.exchange_public_token(token)
IO.inspect(result.access_token, label: "access_token")

# Fetch accounts
{:ok, %{accounts: accounts}} = PlaidEx.get_accounts(result.access_token)
IO.inspect(length(accounts), label: "account_count")

# Sync one page of transactions
{:ok, page} = PlaidEx.API.Transactions.sync(config,
  access_token: result.access_token
)
IO.inspect(length(page.added), label: "transactions_added")
IO.inspect(page.has_more, label: "has_more")
```

## Next steps

- **[Configuration](configuration.md)** — full reference for all config options
- **[Transaction Sync](transaction_sync.md)** — deep dive into sync workers and cursor management
- **[Webhooks](webhooks.md)** — webhook verification, deduplication, and Oban integration
- **[OAuth Flows](oauth_flows.md)** — handling OAuth institutions (Chase, Wells Fargo, etc.)
- **[Multi-Tenant](multi_tenant.md)** — running PlaidEx in a multi-tenant SaaS platform
- **[Observability](observability.md)** — telemetry, metrics, and OpenTelemetry
- **[Testing](testing.md)** — testing strategies with Bypass and Mox
- **[Production](production.md)** — production hardening and operational checklist
