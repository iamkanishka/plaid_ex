# This Plug performs end-to-end webhook handling (parsing, verification,
# deduplication, dispatch, telemetry) in one cohesive request lifecycle.
# credo:disable-for-this-file Credo.Check.Refactor.ModuleDependencies
defmodule PlaidEx.Webhooks.Plug do
  @moduledoc """
  Phoenix Plug for Plaid webhook ingestion.

  Handles the complete webhook lifecycle:

  1. **Body preservation** — reads and caches raw body for signature verification
  2. **Signature verification** — HMAC or JWT verification against your webhook secret
  3. **Deduplication** — ETS-backed sliding window dedup (handles Plaid re-deliveries)
  4. **Immediate ACK** — responds `200 OK` before processing (Plaid requires fast ACK)
  5. **Async dispatch** — routes typed events to your handler via Task.Supervisor or Oban

  ## Usage in your Phoenix router

      # router.ex
      pipeline :plaid_webhooks do
        plug :accepts, ["json"]
      end

      scope "/webhooks/plaid" do
        pipe_through :plaid_webhooks
        forward "/", PlaidEx.Webhooks.Plug,
          config: Application.fetch_env!(:my_app, :plaid_config),
          handler: MyApp.PlaidWebhookHandler
      end

  ## Handler behaviour

  Implement `PlaidEx.Webhooks.Handler` in your handler module:

      defmodule MyApp.PlaidWebhookHandler do
        @behaviour PlaidEx.Webhooks.Handler

        @impl true
        def on_transactions_sync(%PlaidEx.Webhooks.Schemas.TransactionsSyncEvent{} = event) do
          # Trigger sync for this item
          PlaidEx.Sync.TransactionSync.trigger_sync(event.item_id)
          :ok
        end

        @impl true
        def on_item_error(%PlaidEx.Webhooks.Schemas.ItemErrorEvent{} = event) do
          MyApp.Items.mark_error(event.item_id, event.error)
          :ok
        end

        # Default no-op for unhandled events
        @impl true
        def on_unknown(event) do
          require Logger
          Logger.debug("Unhandled Plaid webhook: " <> inspect(event))
          :ok
        end
      end

  ## Oban integration

  If Oban is available, webhook processing is automatically made durable.
  Enable by setting `oban_queue` in your config.

  ## Raw body requirement

  Plaid signature verification requires the raw (unparsed) request body.
  If you use `Plug.Parsers` in your pipeline, it consumes the body.
  This plug reads the body before parsing using `Plug.Conn.read_body/2`.

  **Important**: Do not put `Plug.Parsers` before this plug in the pipeline.
  """

  @behaviour Plug

  import Plug.Conn

  require Logger

  alias PlaidEx.Webhooks.Deduplicator
  alias PlaidEx.Webhooks.Dispatcher
  alias PlaidEx.Webhooks.ObanWorker
  alias PlaidEx.Webhooks.Verifier

  @impl Plug
  def init(opts) do
    config = Keyword.fetch!(opts, :config)
    handler = Keyword.fetch!(opts, :handler)

    %{
      config: config,
      handler: handler,
      max_body_bytes: Keyword.get(opts, :max_body_bytes, 2_000_000)
    }
  end

  @impl Plug
  def call(conn, %{config: config, handler: handler, max_body_bytes: max_bytes}) do
    with {:ok, raw_body, conn} <- read_raw_body(conn, max_bytes),
         {:ok, event} <- parse_json(raw_body),
         :ok <- verify_signature(conn, raw_body, config),
         {:ok, dedup_id} <- derive_dedup_id(event),
         :ok <- Deduplicator.check_and_record(dedup_id) do
      handle_success(conn, event, handler, config)
    else
      error -> handle_error(error, conn, handler, config, max_bytes)
    end
  end

  defp handle_success(conn, event, handler, config) do
    # ACK Plaid immediately — NEVER block on handler logic
    conn = send_resp(conn, 200, ~s({"status":"ok"}))

    :telemetry.execute(
      [:plaid_ex, :webhook, :received],
      %{system_time: System.system_time()},
      %{
        webhook_type: event["webhook_type"],
        webhook_code: event["webhook_code"],
        item_id: event["item_id"],
        tenant_id: config.tenant_id
      }
    )

    # Dispatch asynchronously after ACK
    dispatch_async(event, handler, config)
    conn
  end

  defp handle_error({:error, :body_too_large}, conn, _, _, _) do
    Logger.warning("[PlaidEx.Webhooks] Oversized webhook body rejected")
    send_resp(conn, 413, ~s({"error":"payload_too_large"}))
  end

  defp handle_error({:error, :invalid_json}, conn, _, _, _) do
    Logger.warning("[PlaidEx.Webhooks] Invalid JSON in webhook body")
    send_resp(conn, 400, ~s({"error":"invalid_json"}))
  end

  defp handle_error({:error, :missing_header}, conn, handler, config, max_bytes) do
    if config.webhook_secret do
      Logger.warning("[PlaidEx.Webhooks] Missing Plaid-Verification header")
      send_resp(conn, 401, ~s({"error":"missing_verification_header"}))
    else
      # No secret configured — pass through without verification
      handle_unverified_passthrough(conn, handler, config, max_bytes)
    end
  end

  defp handle_error({:error, :invalid_signature}, conn, _, _, _) do
    Logger.warning("[PlaidEx.Webhooks] Invalid webhook signature — possible spoofing attempt")

    :telemetry.execute(
      [:plaid_ex, :webhook, :invalid_signature],
      %{},
      %{remote_ip: format_ip(conn.remote_ip)}
    )

    send_resp(conn, 401, ~s({"error":"invalid_signature"}))
  end

  defp handle_error({:error, :expired_webhook}, conn, _, _, _) do
    Logger.warning("[PlaidEx.Webhooks] Expired webhook rejected (outside 5-minute window)")
    send_resp(conn, 200, ~s({"status":"expired_ignored"}))
  end

  defp handle_error({:error, :duplicate}, conn, _, _, _) do
    Logger.debug("[PlaidEx.Webhooks] Duplicate webhook discarded")
    # ACK duplicates — don't cause Plaid to retry a webhook we've seen
    send_resp(conn, 200, ~s({"status":"duplicate_ignored"}))
  end

  defp handle_error({:error, reason}, conn, _, _, _) do
    Logger.error("[PlaidEx.Webhooks] Unexpected error: #{inspect(reason)}")
    send_resp(conn, 500, ~s({"error":"internal_error"}))
  end

  defp handle_unverified_passthrough(conn, handler, config, max_bytes) do
    with {:ok, raw_body, conn} <- read_raw_body(conn, max_bytes),
         {:ok, event} <- parse_json(raw_body) do
      conn = send_resp(conn, 200, ~s({"status":"ok"}))
      dispatch_async(event, handler, config)
      conn
    else
      _ -> send_resp(conn, 400, ~s({"error":"bad_request"}))
    end
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  defp read_raw_body(conn, max_bytes) do
    case Plug.Conn.read_body(conn, length: max_bytes, read_timeout: 5_000) do
      {:ok, body, conn} -> {:ok, body, conn}
      {:more, _, _} -> {:error, :body_too_large}
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_json(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, :invalid_json}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  defp verify_signature(conn, raw_body, config) do
    header = conn |> get_req_header("plaid-verification") |> List.first()
    Verifier.verify(raw_body, header, config)
  end

  defp derive_dedup_id(event) do
    id = Deduplicator.derive_id(event)
    {:ok, id}
  end

  defp dispatch_async(event, handler, config) do
    result =
      if oban_available?() and config.oban_queue do
        dispatch_via_oban(event, handler, config)
      else
        dispatch_via_task(event, handler, config)
      end

    case result do
      {:ok, _} ->
        :ok

      {:ok, _, _} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[PlaidEx.Webhooks] Failed to dispatch webhook " <>
            "type=#{event["webhook_type"]} code=#{event["webhook_code"]} — " <>
            "webhook was ACKed but will NOT be processed: #{inspect(reason)}"
        )

        :ok

      :ignore ->
        Logger.error(
          "[PlaidEx.Webhooks] Dispatch ignored for webhook " <>
            "type=#{event["webhook_type"]} code=#{event["webhook_code"]} — " <>
            "webhook was ACKed but will NOT be processed"
        )

        :ok
    end
  end

  defp dispatch_via_task(event, handler, config) do
    Task.Supervisor.start_child(
      PlaidEx.TaskSupervisor,
      fn ->
        try do
          Dispatcher.dispatch(event, handler, config)
        rescue
          e ->
            Logger.error(
              "[PlaidEx.Webhooks] Handler exception: #{Exception.message(e)}\n" <>
                Exception.format_stacktrace(__STACKTRACE__)
            )
        end
      end,
      restart: :transient
    )
  end

  defp dispatch_via_oban(event, _, config) do
    if Code.ensure_loaded?(Oban) do
      %{
        "webhook_type" => event["webhook_type"],
        "webhook_code" => event["webhook_code"],
        "raw_event" => event,
        "tenant_id" => config.tenant_id
      }
      |> ObanWorker.new(queue: config.oban_queue, max_attempts: config.oban_max_attempts)
      |> Oban.insert()
    else
      dispatch_via_task(event, nil, config)
    end
  end

  defp oban_available?, do: Code.ensure_loaded?(Oban)

  defp format_ip({a, b, c, d}), do: "#{a}.#{b}.#{c}.#{d}"
  defp format_ip({a, b, c, d, e, f, g, h}), do: "#{a}:#{b}:#{c}:#{d}:#{e}:#{f}:#{g}:#{h}"
  defp format_ip(_), do: "unknown"
end
