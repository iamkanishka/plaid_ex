defmodule PlaidEx.Telemetry.Handler do
  @moduledoc """
  Telemetry event handlers and attachment helpers.

  PlaidEx emits `:telemetry` events for every significant operation.
  Attach handlers to integrate with your metrics backend, logging
  pipeline, or alerting system.

  ## Attaching all handlers

      # In your application.ex start/2:
      PlaidEx.Telemetry.Handler.attach_all()

  ## Event reference

  ### HTTP events
  - `[:plaid_ex, :http, :start]` — request initiated
    - metadata: `%{path, attempt, tenant_id, url}`
  - `[:plaid_ex, :http, :stop]` — request completed
    - measurements: `%{system_time}`
    - metadata: `%{path, status, duration_ms, attempt, tenant_id}`
  - `[:plaid_ex, :http, :error]` — request failed (after retries)
    - metadata: `%{path, error_code, error_type, status, attempt, tenant_id}`
  - `[:plaid_ex, :http, :retry]` — retry scheduled
    - metadata: `%{path, attempt, delay_ms, error_code, tenant_id}`

  ### Sync events
  - `[:plaid_ex, :sync, :start]` — sync cycle started
  - `[:plaid_ex, :sync, :page]` — page fetched and processed
    - measurements: `%{added, modified, removed}`
    - metadata: `%{tenant_id, has_more, total_pages}`
  - `[:plaid_ex, :sync, :reauth_required]` — item needs reauthentication

  ### Webhook events
  - `[:plaid_ex, :webhook, :received]` — webhook received and ACK'd
    - metadata: `%{webhook_type, webhook_code, item_id, tenant_id}`
  - `[:plaid_ex, :webhook, :dispatch]` — dispatched to handler
    - measurements: `%{duration_ms}`
  - `[:plaid_ex, :webhook, :duplicate]` — duplicate discarded
  - `[:plaid_ex, :webhook, :invalid_signature]` — signature check failed

  ### Circuit breaker events
  - `[:plaid_ex, :circuit_breaker, :open]` — circuit opened
    - measurements: `%{failure_count}`
    - metadata: `%{environment}`
  - `[:plaid_ex, :circuit_breaker, :close]` — circuit closed (recovered)

  ### Rate limit events
  - `[:plaid_ex, :rate_limit, :throttled]` — request throttled client-side
    - metadata: `%{tenant_id}`
  """

  require Logger

  @all_events [
    [:plaid_ex, :http, :start],
    [:plaid_ex, :http, :stop],
    [:plaid_ex, :http, :error],
    [:plaid_ex, :http, :retry],
    [:plaid_ex, :sync, :start],
    [:plaid_ex, :sync, :page],
    [:plaid_ex, :sync, :reauth_required],
    [:plaid_ex, :webhook, :received],
    [:plaid_ex, :webhook, :dispatch],
    [:plaid_ex, :webhook, :duplicate],
    [:plaid_ex, :webhook, :invalid_signature],
    [:plaid_ex, :circuit_breaker, :open],
    [:plaid_ex, :circuit_breaker, :close],
    [:plaid_ex, :rate_limit, :throttled]
  ]

  @doc """
  Attaches the built-in structured logging handler for all PlaidEx events.
  """
  @spec attach_all(keyword()) :: :ok
  def attach_all(opts \\ []) do
    log_level = Keyword.get(opts, :log_level, :debug)

    result =
      :telemetry.attach_many(
        "plaid_ex_logger",
        @all_events,
        &__MODULE__.handle_event/4,
        %{log_level: log_level}
      )

    case result do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  @doc "Detaches the built-in handler."
  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    :telemetry.detach("plaid_ex_logger")
  end

  @doc "Returns all event names emitted by PlaidEx."
  @spec events() :: [[atom(), ...], ...]
  def events, do: @all_events

  # ── Default handler implementation ──────────────────────────────────────────

  @spec handle_event([atom()], map(), map(), map()) :: :ok
  def handle_event([:plaid_ex, :http, :start], _, meta, %{log_level: level}) do
    Logger.log(level, "[PlaidEx] HTTP start",
      path: meta[:path],
      attempt: meta[:attempt],
      tenant_id: meta[:tenant_id]
    )
  end

  def handle_event([:plaid_ex, :http, :stop], _, meta, %{log_level: level}) do
    Logger.log(level, "[PlaidEx] HTTP stop",
      path: meta[:path],
      status: meta[:status],
      duration_ms: meta[:duration_ms],
      attempt: meta[:attempt],
      tenant_id: meta[:tenant_id]
    )
  end

  def handle_event([:plaid_ex, :http, :error], _, meta, _) do
    Logger.warning("[PlaidEx] HTTP error",
      path: meta[:path],
      error_code: meta[:error_code],
      status: meta[:status],
      attempt: meta[:attempt],
      tenant_id: meta[:tenant_id]
    )
  end

  def handle_event([:plaid_ex, :http, :retry], _, meta, %{log_level: level}) do
    Logger.log(level, "[PlaidEx] HTTP retry",
      path: meta[:path],
      attempt: meta[:attempt],
      delay_ms: meta[:delay_ms],
      error_code: meta[:error_code]
    )
  end

  def handle_event([:plaid_ex, :sync, :page], measurements, meta, %{log_level: level}) do
    Logger.log(level, "[PlaidEx] Sync page",
      added: measurements[:added],
      modified: measurements[:modified],
      removed: measurements[:removed],
      has_more: meta[:has_more],
      total_pages: meta[:total_pages],
      tenant_id: meta[:tenant_id]
    )
  end

  def handle_event([:plaid_ex, :sync, :reauth_required], _, meta, _) do
    Logger.warning("[PlaidEx] Sync paused — item requires reauthentication",
      tenant_id: meta[:tenant_id]
    )
  end

  def handle_event([:plaid_ex, :webhook, :received], _, meta, %{log_level: level}) do
    Logger.log(level, "[PlaidEx] Webhook received",
      webhook_type: meta[:webhook_type],
      webhook_code: meta[:webhook_code],
      item_id: meta[:item_id],
      tenant_id: meta[:tenant_id]
    )
  end

  def handle_event([:plaid_ex, :webhook, :invalid_signature], _, meta, _) do
    Logger.warning("[PlaidEx] Webhook invalid signature",
      remote_ip: meta[:remote_ip]
    )
  end

  def handle_event([:plaid_ex, :circuit_breaker, :open], measurements, meta, _) do
    Logger.error("[PlaidEx] Circuit breaker OPENED",
      environment: meta[:environment],
      failure_count: measurements[:failure_count]
    )
  end

  def handle_event([:plaid_ex, :circuit_breaker, :close], _, meta, _) do
    Logger.info("[PlaidEx] Circuit breaker CLOSED (recovered)",
      environment: meta[:environment]
    )
  end

  def handle_event([:plaid_ex, :rate_limit, :throttled], _, meta, %{log_level: level}) do
    Logger.log(level, "[PlaidEx] Rate limited", tenant_id: meta[:tenant_id])
  end

  def handle_event(_, _, _, _), do: :ok
end
