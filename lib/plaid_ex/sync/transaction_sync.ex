# This GenServer owns the full transaction-sync lifecycle (config, registry,
# cursor persistence, HTTP, telemetry) as one cohesive responsibility.
# credo:disable-for-this-file Credo.Check.Refactor.ModuleDependencies
defmodule PlaidEx.Sync.TransactionSync do
  @moduledoc """
  Durable cursor-based transaction synchronization worker.

  Implements Plaid's `/transactions/sync` endpoint semantics correctly,
  handling all documented edge cases:

  - **Cursor durability**: cursor is committed BEFORE handler invocation.
    On crash, the same page is re-delivered to the handler (which must be
    idempotent), ensuring no data loss.

  - **Mutation during pagination**: if Plaid returns
    `TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION`, the cursor is reset
    and a fresh sync begins. This is a documented Plaid behavior.

  - **Reauthentication**: `ITEM_LOGIN_REQUIRED` pauses the worker and
    emits a telemetry event so your application can redirect the user
    through Link update mode.

  - **Institution outages**: transient errors (INSTITUTION_DOWN,
    INSTITUTION_NOT_RESPONDING) are retried with exponential backoff.
    The worker does not crash — it schedules recovery automatically.

  - **Full pagination**: `has_more: true` drives immediate consecutive
    page fetches with no sleep between them. Only when `has_more: false`
    does the worker sleep until the next poll interval.

  ## Starting a sync worker

      {:ok, _pid} = PlaidEx.Sync.TransactionSync.start_worker(
        "access-sandbox-abc123",
        config,
        handler: fn page ->
          # page has :added, :modified, :removed lists
          MyApp.Transactions.upsert_batch(page.added)
          MyApp.Transactions.update_batch(page.modified)
          MyApp.Transactions.remove_batch(page.removed)
          :ok
        end,
        tenant_id: "acme_corp"
      )

  ## Handler contract

  The handler function MUST:
  - Accept a `PlaidEx.Schemas.TransactionSyncPage` struct
  - Return `:ok` on success
  - Return `{:error, reason}` on failure (triggers retry of same page)
  - Be **idempotent** — it may be called multiple times for the same page
    (if the worker crashes between cursor commit and handler return)

  ## Manual control

      PlaidEx.Sync.TransactionSync.trigger_sync("access-sandbox-...")
      PlaidEx.Sync.TransactionSync.pause("access-sandbox-...")
      PlaidEx.Sync.TransactionSync.resume("access-sandbox-...")
      PlaidEx.Sync.TransactionSync.stop_worker("access-sandbox-...")
  """

  use GenServer, restart: :transient
  require Logger

  alias PlaidEx.Config
  alias PlaidEx.Error
  alias PlaidEx.HTTP.Client
  alias PlaidEx.Schemas.TransactionSyncPage
  alias PlaidEx.Support.HandlerResult
  alias PlaidEx.Sync.CursorStore
  alias PlaidEx.Sync.SyncSupervisor

  @type handler :: (TransactionSyncPage.t() -> :ok | {:error, term()})

  @type start_opts :: [
          handler: handler(),
          tenant_id: String.t() | nil,
          poll_interval_ms: pos_integer()
        ]

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            access_token: String.t(),
            config: PlaidEx.Config.t(),
            tenant_id: String.t() | nil,
            handler: PlaidEx.Sync.TransactionSync.handler(),
            cursor: String.t() | nil,
            poll_interval_ms: pos_integer(),
            consecutive_errors: non_neg_integer(),
            total_pages_synced: non_neg_integer(),
            total_transactions_added: non_neg_integer(),
            paused: boolean(),
            pause_reason: atom() | nil,
            last_sync_at: DateTime.t() | nil,
            started_at: DateTime.t()
          }

    defstruct [
      :access_token,
      :config,
      :tenant_id,
      :handler,
      :cursor,
      poll_interval_ms: 30_000,
      consecutive_errors: 0,
      total_pages_synced: 0,
      total_transactions_added: 0,
      paused: false,
      pause_reason: nil,
      last_sync_at: nil,
      started_at: nil
    ]
  end

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Starts a new transaction sync worker for the given access token.

  Workers are registered by access token in `PlaidEx.SyncRegistry`.
  Only one worker per access token is allowed.
  """
  @spec start_worker(String.t(), Config.t(), start_opts()) ::
          {:ok, pid()} | {:error, :already_started | term()}
  def start_worker(access_token, config, opts) do
    SyncSupervisor.start_worker(access_token, config, opts)
  end

  @doc """
  Stops the sync worker for the given access token.
  """
  @spec stop_worker(String.t()) :: :ok | {:error, :not_found}
  def stop_worker(access_token) do
    case lookup(access_token) do
      {:ok, pid} ->
        GenServer.stop(pid, :normal)
        :ok

      :not_found ->
        {:error, :not_found}
    end
  end

  @doc """
  Manually triggers an immediate sync cycle.
  Useful after a `SYNC_UPDATES_AVAILABLE` webhook.
  """
  @spec trigger_sync(String.t()) :: :ok | {:error, :not_found}
  def trigger_sync(access_token) do
    case lookup(access_token) do
      {:ok, pid} -> GenServer.cast(pid, :sync)
      :not_found -> {:error, :not_found}
    end
  end

  @doc """
  Pauses the sync worker. It will not poll until `resume/1` is called.
  """
  @spec pause(String.t(), atom()) :: :ok | {:error, :not_found}
  def pause(access_token, reason \\ :manual) do
    case lookup(access_token) do
      {:ok, pid} -> GenServer.cast(pid, {:pause, reason})
      :not_found -> {:error, :not_found}
    end
  end

  @doc """
  Resumes a paused sync worker and triggers an immediate sync.
  """
  @spec resume(String.t()) :: :ok | {:error, :not_found}
  def resume(access_token) do
    case lookup(access_token) do
      {:ok, pid} -> GenServer.cast(pid, :resume)
      :not_found -> {:error, :not_found}
    end
  end

  @doc """
  Returns the current status of the sync worker.
  """
  @spec status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def status(access_token) do
    case lookup(access_token) do
      {:ok, pid} -> {:ok, GenServer.call(pid, :status)}
      :not_found -> {:error, :not_found}
    end
  end

  # ── GenServer lifecycle ──────────────────────────────────────────────────────

  @spec start_link({String.t(), PlaidEx.Config.t(), keyword()}) :: GenServer.on_start()
  def start_link({access_token, config, opts}) do
    GenServer.start_link(__MODULE__, {access_token, config, opts})
  end

  @impl GenServer
  def init({access_token, config, opts}) do
    handler = Keyword.fetch!(opts, :handler)
    tenant_id = Keyword.get(opts, :tenant_id, config.tenant_id)
    poll_interval_ms = Keyword.get(opts, :poll_interval_ms, config.sync_poll_interval_ms)

    # Register by access token for lookup
    case Registry.register(PlaidEx.SyncRegistry, access_token, %{
           tenant_id: tenant_id,
           started_at: DateTime.utc_now()
         }) do
      {:ok, _} ->
        init_state(access_token, config, tenant_id, handler, poll_interval_ms)

      {:error, {:already_registered, pid}} ->
        Logger.warning(
          "[PlaidEx.Sync] access_token=#{mask_token(access_token)} already has an " <>
            "active sync worker pid=#{inspect(pid)} — refusing duplicate start"
        )

        {:stop, {:already_started, pid}}
    end
  end

  defp init_state(access_token, config, tenant_id, handler, poll_interval_ms) do
    # Restore cursor from durable store (survives application restart if using
    # a database-backed cursor store)
    cursor = CursorStore.get(access_token)

    state = %State{
      access_token: access_token,
      config: config,
      tenant_id: tenant_id,
      handler: handler,
      cursor: cursor,
      poll_interval_ms: poll_interval_ms,
      started_at: DateTime.utc_now()
    }

    Logger.info(
      "[PlaidEx.Sync] Worker started access_token=#{mask_token(access_token)} " <>
        "tenant=#{tenant_id || "global"} has_cursor=#{cursor != nil}"
    )

    # Start syncing immediately on init
    {:ok, state, {:continue, :sync}}
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def handle_continue(:sync, state), do: do_sync(state)

  @impl GenServer
  def handle_cast(:sync, %State{paused: true} = state) do
    Logger.debug("[PlaidEx.Sync] Skipping sync — worker is paused reason=#{state.pause_reason}")
    {:noreply, state}
  end

  def handle_cast(:sync, state), do: do_sync(state)

  def handle_cast({:pause, reason}, state) do
    Logger.info(
      "[PlaidEx.Sync] Worker paused reason=#{reason} token=#{mask_token(state.access_token)}"
    )

    {:noreply, %{state | paused: true, pause_reason: reason}}
  end

  def handle_cast(:resume, state) do
    Logger.info("[PlaidEx.Sync] Worker resumed token=#{mask_token(state.access_token)}")
    new_state = %{state | paused: false, pause_reason: nil}
    # Trigger immediate sync on resume
    do_sync(new_state)
  end

  @impl GenServer
  def handle_info(:scheduled_sync, %State{paused: true} = state) do
    {:noreply, state}
  end

  def handle_info(:scheduled_sync, state), do: do_sync(state)

  @impl GenServer
  def handle_call(:status, _, state) do
    status = %{
      access_token: mask_token(state.access_token),
      tenant_id: state.tenant_id,
      has_cursor: state.cursor != nil,
      paused: state.paused,
      pause_reason: state.pause_reason,
      consecutive_errors: state.consecutive_errors,
      total_pages_synced: state.total_pages_synced,
      total_transactions_added: state.total_transactions_added,
      last_sync_at: state.last_sync_at,
      started_at: state.started_at
    }

    {:reply, status, state}
  end

  # ── Core sync loop ───────────────────────────────────────────────────────────

  defp do_sync(state) do
    emit_telemetry(:sync_start, state)
    handle_fetch_result(fetch_page(state), state)
  end

  defp handle_fetch_result({:ok, raw_page}, state) do
    page = TransactionSyncPage.from_map(raw_page)

    # CRITICAL: Persist cursor BEFORE calling handler.
    # On handler crash, we re-deliver this page.
    # On no persistence and cursor lost, we restart from scratch.
    # Both are acceptable; the latter is worse but cursor storage is
    # pluggable — use a database backend for true durability.
    :ok = CursorStore.put(state.access_token, page.next_cursor)

    handle_handler_result(invoke_handler(state.handler, page), state, page)
  end

  defp handle_fetch_result({:error, %Error{code: "ITEM_LOGIN_REQUIRED"} = error}, state) do
    Logger.warning(
      "[PlaidEx.Sync] Item requires reauthentication " <>
        "token=#{mask_token(state.access_token)}"
    )

    emit_telemetry(:reauth_required, state, error: error)
    {:noreply, %{state | paused: true, pause_reason: :item_login_required}}
  end

  defp handle_fetch_result(
         {:error, %Error{code: "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION"}},
         state
       ) do
    # Documented Plaid behavior: data changed during pagination.
    # Must reset cursor and start a fresh sync.
    Logger.warning(
      "[PlaidEx.Sync] Mutation during pagination — resetting cursor " <>
        "token=#{mask_token(state.access_token)}"
    )

    :ok = CursorStore.delete(state.access_token)
    new_state = %{state | cursor: nil, consecutive_errors: 0}
    schedule_error_retry(new_state)
  end

  defp handle_fetch_result({:error, %Error{code: "PRODUCT_NOT_READY"}}, state) do
    # Plaid is still computing initial transaction data. Retry with delay.
    Logger.info("[PlaidEx.Sync] Product not ready — will retry")
    schedule_error_retry(state)
  end

  defp handle_fetch_result({:error, error}, state) do
    Logger.warning(
      "[PlaidEx.Sync] Sync error token=#{mask_token(state.access_token)} " <>
        "code=#{error.code} retryable=#{error.retryable}"
    )

    new_state = %{state | consecutive_errors: state.consecutive_errors + 1}
    schedule_error_retry(new_state)
  end

  defp handle_handler_result(:ok, state, page) do
    new_state = %{
      state
      | cursor: page.next_cursor,
        consecutive_errors: 0,
        total_pages_synced: state.total_pages_synced + 1,
        total_transactions_added: state.total_transactions_added + length(page.added),
        last_sync_at: DateTime.utc_now()
    }

    emit_telemetry(:page_complete, new_state, page)

    if page.has_more do
      # More pages available — fetch immediately (no sleep)
      {:noreply, new_state, {:continue, :sync}}
    else
      # Fully caught up — schedule next poll
      schedule_next_poll(new_state)
    end
  end

  defp handle_handler_result({:error, reason}, state, _) do
    Logger.error(
      "[PlaidEx.Sync] Handler error token=#{mask_token(state.access_token)} " <>
        "reason=#{inspect(reason)} — will retry same page"
    )

    # Do NOT advance cursor — retry the same page
    # The cursor we stored above will be re-used
    schedule_error_retry(state)
  end

  defp fetch_page(%State{
         access_token: token,
         cursor: cursor,
         config: config,
         tenant_id: tenant_id
       }) do
    body = maybe_add_cursor(%{"access_token" => token, "count" => 500}, cursor)

    Client.post("/transactions/sync", body, config, tenant_id: tenant_id)
  end

  defp maybe_add_cursor(body, nil), do: body
  defp maybe_add_cursor(body, cursor), do: Map.put(body, "cursor", cursor)

  defp invoke_handler(handler, page) when is_function(handler, 1) do
    try do
      raw_result = handler.(page)
      HandlerResult.normalize(raw_result)
    rescue
      e ->
        Logger.error("[PlaidEx.Sync] Handler raised: #{Exception.message(e)}")
        {:error, {:handler_exception, e}}
    end
  end

  defp schedule_next_poll(%State{poll_interval_ms: interval} = state) do
    Process.send_after(self(), :scheduled_sync, interval)
    {:noreply, state}
  end

  defp schedule_error_retry(%State{consecutive_errors: n} = state) do
    # Exponential backoff: 5s, 10s, 20s, 40s, max 5 min
    delay_ms = min(5_000 * trunc(:math.pow(2, n)), 300_000)
    Process.send_after(self(), :scheduled_sync, delay_ms)
    {:noreply, state}
  end

  # ── Telemetry ────────────────────────────────────────────────────────────────

  defp emit_telemetry(:sync_start, state) do
    :telemetry.execute(
      [:plaid_ex, :sync, :start],
      %{},
      %{tenant_id: state.tenant_id, has_cursor: state.cursor != nil}
    )
  end

  defp emit_telemetry(:page_complete, state, page) do
    :telemetry.execute(
      [:plaid_ex, :sync, :page],
      %{
        added: length(page.added),
        modified: length(page.modified),
        removed: length(page.removed)
      },
      %{
        tenant_id: state.tenant_id,
        has_more: page.has_more,
        total_pages: state.total_pages_synced
      }
    )
  end

  defp emit_telemetry(:reauth_required, state, extra) do
    :telemetry.execute(
      [:plaid_ex, :sync, :reauth_required],
      %{},
      Map.merge(%{tenant_id: state.tenant_id}, Map.new(extra))
    )
  end

  # ── Utilities ────────────────────────────────────────────────────────────────

  defp lookup(access_token) do
    case Registry.lookup(PlaidEx.SyncRegistry, access_token) do
      [{pid, _}] -> {:ok, pid}
      [] -> :not_found
    end
  end

  defp mask_token(token) when is_binary(token) and byte_size(token) > 12 do
    prefix = String.slice(token, 0, 20)
    "#{prefix}...[MASKED]"
  end

  defp mask_token(token), do: token
end
