# Transaction Sync

PlaidEx implements Plaid's `/transactions/sync` cursor-based endpoint with
full OTP supervision, durable cursor management, and correct handling of
every documented edge case.

## Why cursor-based sync?

Plaid's older `/transactions/get` endpoint retrieves transactions by date range
and has no concept of "what changed since last time." Every poll returns
a full dataset, making it impossible to detect deletions efficiently.

The `/transactions/sync` endpoint was designed for ongoing synchronization:

- Returns `added`, `modified`, and `removed` arrays — only what changed
- Cursor represents your position in Plaid's transaction event log
- `has_more: true` means more pages are ready — fetch immediately
- `has_more: false` means you're caught up — sleep until next poll

## Starting a sync worker

```elixir
{:ok, _pid} = PlaidEx.start_transaction_sync(access_token,
  handler: fn %PlaidEx.Schemas.TransactionSyncPage{} = page ->
    # Process added and modified (upsert)
    MyApp.Transactions.upsert_batch(page.added)
    MyApp.Transactions.upsert_batch(page.modified)

    # Process removals (delete)
    removed_ids = Enum.map(page.removed, & &1.transaction_id)
    MyApp.Transactions.delete_batch(removed_ids)

    # Return :ok on success, {:error, reason} to retry the same page
    :ok
  end,
  tenant_id: "acme_corp",           # optional, for multi-tenant
  poll_interval_ms: 30_000          # optional, default: 30s
)
```

## The handler contract

Your handler function MUST:

1. **Return `:ok`** on success — the cursor advances
2. **Return `{:error, reason}`** on failure — the same page is retried
3. **Be idempotent** — it may be called twice for the same page (explained below)
4. **Not raise** — exceptions are caught and treated as `{:error, ...}`

### Why idempotency matters

PlaidEx commits the cursor **before** calling your handler. This ensures:

- On handler success: cursor advances, data processed ✓
- On handler crash after cursor commit: same page re-delivered on restart ← your handler must handle duplicates
- On handler crash before cursor commit: impossible (cursor already saved)
- On process crash before cursor commit: restart from previous cursor ← some transactions may be re-delivered

The correct approach is upsert semantics using `plaid_transaction_id` as
the unique key:

```elixir
handler: fn page ->
  Repo.transaction(fn ->
    # Upsert — safe to call multiple times with same data
    Enum.each(page.added ++ page.modified, fn tx ->
      Repo.insert!(%MyTransaction{
        plaid_transaction_id: tx.transaction_id,
        # ... other fields
      },
      on_conflict: {:replace_all_except, [:id, :inserted_at]},
      conflict_target: :plaid_transaction_id
      )
    end)

    Enum.each(page.removed, fn r ->
      Repo.delete_all(from t in MyTransaction,
        where: t.plaid_transaction_id == ^r.transaction_id
      )
    end)
  end)
  :ok
end
```

## Cursor persistence (critical for production)

The default `CursorStore` uses ETS — cursors are lost on application restart.
This means a restart triggers a full historical re-sync.

For production, implement the `CursorStore.Behaviour` with a database backend:

```elixir
defmodule MyApp.PlaidCursorStore do
  @behaviour PlaidEx.Sync.CursorStore.Behaviour

  alias MyApp.Repo
  alias MyApp.PlaidItem

  @impl true
  def get(access_token) do
    case Repo.get_by(PlaidItem, access_token_hash: hash(access_token)) do
      nil -> nil
      item -> item.sync_cursor
    end
  end

  @impl true
  def put(access_token, cursor) do
    Repo.update_all(
      from(i in PlaidItem, where: i.access_token_hash == ^hash(access_token)),
      set: [sync_cursor: cursor, cursor_updated_at: DateTime.utc_now()]
    )
    :ok
  end

  @impl true
  def delete(access_token) do
    Repo.update_all(
      from(i in PlaidItem, where: i.access_token_hash == ^hash(access_token)),
      set: [sync_cursor: nil, cursor_updated_at: DateTime.utc_now()]
    )
    :ok
  end

  defp hash(access_token) do
    :crypto.hash(:sha256, access_token) |> Base.encode16(case: :lower)
  end
end

# config/config.exs
config :plaid_ex, cursor_store: MyApp.PlaidCursorStore
```

## Handling sync worker lifecycle

### Check if a worker is running

```elixir
case PlaidEx.transaction_sync_status(access_token) do
  {:ok, status} ->
    IO.inspect(status)
    # %{
    #   paused: false,
    #   pause_reason: nil,
    #   consecutive_errors: 0,
    #   total_pages_synced: 142,
    #   total_transactions_added: 8743,
    #   last_sync_at: ~U[2024-01-15 10:30:00Z],
    #   has_cursor: true
    # }

  {:error, :not_found} ->
    # No worker running for this access_token
    :ok
end
```

### Trigger an immediate sync

When you receive a `SYNC_UPDATES_AVAILABLE` webhook, trigger an immediate
sync rather than waiting for the next poll cycle:

```elixir
def on_transactions_sync(%{item_id: item_id}) do
  case MyApp.Items.get_access_token(item_id) do
    {:ok, access_token} ->
      PlaidEx.trigger_transaction_sync(access_token)
    {:error, :not_found} ->
      :ok
  end
  :ok
end
```

### Pause and resume

When a user revokes access or you detect suspicious activity:

```elixir
# Pause
PlaidEx.Sync.TransactionSync.pause(access_token, :user_revoked)

# Resume (e.g., after user re-authenticates)
PlaidEx.Sync.TransactionSync.resume(access_token)
```

### Stop a worker

When an item is removed:

```elixir
def remove_plaid_item(item) do
  access_token = decrypt!(item.access_token)

  # Stop the sync worker first
  PlaidEx.stop_transaction_sync(access_token)

  # Remove from Plaid (revokes access)
  PlaidEx.API.Items.remove(config, access_token)

  # Remove from your database
  Repo.delete!(item)
end
```

## Edge cases PlaidEx handles automatically

### `ITEM_LOGIN_REQUIRED`

The worker pauses itself and emits a telemetry event. You do NOT need to
handle this in your handler — your webhook handler does:

```elixir
def on_item_error(%{error: %{"error_code" => "ITEM_LOGIN_REQUIRED"}, item_id: item_id}) do
  # Worker is already paused. Send user through Link update mode.
  MyApp.Notifications.notify_reconnect(item_id)
  :ok
end
```

After the user reconnects, resume the worker:

```elixir
PlaidEx.Sync.TransactionSync.resume(access_token)
```

### `TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION`

Plaid mutated the transaction log while you were paginating. The cursor is
invalidated. PlaidEx resets the cursor to `nil` and starts a fresh sync —
this is the correct documented behavior. Your handler will re-receive all
historical transactions. Ensure it uses upsert semantics.

### `PRODUCT_NOT_READY`

The item was just created and Plaid hasn't finished loading historical
data yet. PlaidEx retries automatically with backoff.

### Institution outages

Plaid returns `INSTITUTION_DOWN` or `INSTITUTION_NOT_RESPONDING`. PlaidEx
retries with exponential backoff:

```
Attempt 1 → fail → sleep 5s
Attempt 2 → fail → sleep 10s
Attempt 3 → fail → sleep 20s
Attempt 4 → fail → sleep 40s
...max 5 minutes
```

The circuit breaker also opens after 5 consecutive failures, protecting
the rest of your system from being slowed by a single institution's issues.

## High-throughput: Broadway pipeline

For platforms ingesting hundreds of items simultaneously, use the
Broadway pipeline instead of individual workers:

```elixir
defmodule MyApp.TransactionPipeline do
  use PlaidEx.Sync.BroadwayPipeline

  @impl true
  def handle_transaction(%PlaidEx.Schemas.Transaction{} = tx, _context) do
    case MyApp.Transactions.upsert(tx) do
      {:ok, _} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  @impl true
  def handle_removed(transaction_id, _context) do
    MyApp.Transactions.delete(transaction_id)
    :ok
  end
end

# In your application supervisor:
children = [
  {MyApp.TransactionPipeline,
    access_tokens: MyApp.Items.all_access_tokens(),
    config: PlaidEx.config(),
    concurrency: 20,
    batch_size: 100,
    batch_timeout_ms: 2_000
  }
]
```

## Monitoring sync health

Set up alerts on these telemetry events:

```elixir
# Alert when a worker enters reauth state
:telemetry.attach("sync_reauth_alert",
  [:plaid_ex, :sync, :reauth_required],
  fn _event, _measurements, %{tenant_id: tenant_id}, _ ->
    MyApp.Alerts.warn("Plaid item requires reauth", tenant_id: tenant_id)
  end,
  nil
)

# Track sync lag (time since last successful page)
:telemetry.attach("sync_page_tracker",
  [:plaid_ex, :sync, :page],
  fn _event, %{added: added}, %{tenant_id: tenant_id}, _ ->
    MyMetrics.gauge("plaid.sync.transactions_per_page", added,
      tags: [tenant_id: tenant_id]
    )
  end,
  nil
)
```

## Database schema recommendation

```elixir
# Ecto migration
create table(:plaid_items) do
  add :user_id, references(:users, on_delete: :delete_all), null: false
  add :item_id, :string, null: false
  add :access_token_encrypted, :binary, null: false   # encrypt at rest
  add :institution_id, :string
  add :sync_cursor, :text                             # Plaid transaction cursor
  add :cursor_updated_at, :utc_datetime_usec
  add :status, :string, default: "active"             # active|reauth_required|error|removed
  add :error_code, :string
  add :last_sync_at, :utc_datetime_usec
  add :webhook_url, :string

  timestamps()
end

create unique_index(:plaid_items, [:item_id])
create index(:plaid_items, [:user_id])
create index(:plaid_items, [:status])

create table(:plaid_transactions) do
  add :item_id, references(:plaid_items, on_delete: :delete_all), null: false
  add :plaid_transaction_id, :string, null: false     # Plaid's transaction ID
  add :account_id, :string, null: false
  add :amount, :decimal, null: false
  add :iso_currency_code, :string
  add :date, :date, null: false
  add :datetime, :utc_datetime_usec
  add :name, :string
  add :merchant_name, :string
  add :category, {:array, :string}
  add :personal_finance_category, :map
  add :pending, :boolean, default: false
  add :logo_url, :string
  add :website, :string
  add :payment_channel, :string

  timestamps()
end

create unique_index(:plaid_transactions, [:plaid_transaction_id])
create index(:plaid_transactions, [:item_id, :date])
create index(:plaid_transactions, [:account_id])
```
