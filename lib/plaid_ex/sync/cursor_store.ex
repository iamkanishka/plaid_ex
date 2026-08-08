defmodule PlaidEx.Sync.CursorStore do
  @moduledoc """
  Pluggable store for Plaid transaction sync cursors.

  Cursors represent the position in Plaid's transaction event log.
  They MUST be persisted durably — if a cursor is lost, the next
  sync call will restart from the beginning (full historical replay).

  ## Production persistence note

  By default, cursors are persisted via `PlaidEx.Sync.CursorStore.EtsBackend`,
  which means cursors are LOST on application restart. For production
  systems, implement `Behaviour` with a database backend (Ecto, Redix,
  etc.) and configure it:

      config :plaid_ex,
        cursor_store: MyApp.PlaidCursorStore

  ## Custom cursor store

      defmodule MyApp.PlaidCursorStore do
        @behaviour PlaidEx.Sync.CursorStore.Behaviour

        @impl true
        def get(item_id) do
          case Repo.get_by(PlaidItem, item_id: item_id) do
            nil -> nil
            item -> item.sync_cursor
          end
        end

        @impl true
        def put(item_id, cursor) do
          Repo.update_all(
            from(i in PlaidItem, where: i.item_id == ^item_id),
            set: [sync_cursor: cursor]
          )
          :ok
        end

        @impl true
        def delete(item_id) do
          Repo.delete_all(from(i in PlaidItem, where: i.item_id == ^item_id))
          :ok
        end
      end
  """

  # ── Behaviour ────────────────────────────────────────────────────────────────

  defmodule Behaviour do
    @moduledoc "Behaviour for pluggable cursor persistence backends."

    @callback get(item_id :: String.t()) :: String.t() | nil
    @callback put(item_id :: String.t(), cursor :: String.t()) :: :ok
    @callback delete(item_id :: String.t()) :: :ok
  end

  # ── Default ETS-backed implementation ───────────────────────────────────────

  defmodule EtsBackend do
    @moduledoc """
    Default `Behaviour` implementation — an ETS-backed GenServer that
    owns the cursor table. Cursors are LOST on application restart; see
    `PlaidEx.Sync.CursorStore` moduledoc for how to plug in durable
    storage instead.
    """

    @behaviour Behaviour

    use PlaidEx.Support.EtsGenServer, table: :plaid_ex_cursors

    @impl Behaviour
    def get(item_id) do
      case :ets.lookup(@table, item_id) do
        [{^item_id, cursor}] -> cursor
        [] -> nil
      end
    end

    @impl Behaviour
    def put(item_id, cursor) do
      :ets.insert(@table, {item_id, cursor})
      :ok
    end

    @impl Behaviour
    def delete(item_id) do
      :ets.delete(@table, item_id)
      :ok
    end
  end

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Retrieves the cursor for the given item ID.
  Returns `nil` if no cursor exists (fresh sync).
  """
  @spec get(String.t()) :: String.t() | nil
  def get(item_id) do
    backend().get(item_id)
  end

  @doc """
  Persists a cursor for the given item ID.

  IMPORTANT: Call this BEFORE processing the page data. This ensures
  that on crash, the sync restarts from the correct cursor position
  (processing the same page again) rather than losing the cursor
  and starting over.
  """
  @spec put(String.t(), String.t()) :: :ok
  def put(item_id, cursor) when is_binary(cursor) do
    backend().put(item_id, cursor)
  end

  @doc """
  Deletes the cursor for an item, forcing a full re-sync on next run.

  Use this when Plaid returns
  `TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION` — the cursor is
  invalidated and a fresh sync must begin from the start.
  """
  @spec delete(String.t()) :: :ok
  def delete(item_id) do
    backend().delete(item_id)
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp backend do
    Application.get_env(:plaid_ex, :cursor_store, EtsBackend)
  end
end
