defmodule PlaidEx.Webhooks.Deduplicator do
  @moduledoc """
  ETS-based webhook deduplication with sliding expiry window.

  Plaid may deliver the same webhook more than once (at-least-once
  delivery semantics). This module maintains a sliding window of seen
  webhook IDs to detect and discard duplicates.

  ## Architecture

  Uses a GenServer to own the ETS table and run periodic cleanup.
  The fast path (check + record) is a single ETS operation — no
  GenServer call required for normal traffic.

  ## Webhook ID derivation

  Plaid does not include a stable unique ID in all webhook payloads.
  IDs are derived from:
  - `webhook_type` + `webhook_code` + `item_id` + quantized timestamp (5s window)

  This means the same event delivered twice within 5 seconds is
  deduplicated. Events delivered more than 5 seconds apart are
  treated as distinct (edge case — rare in practice).

  ## Window size

  Default: 1 hour. Configurable via `:webhook_dedup_window_seconds`.
  For high-volume deployments, reduce this if ETS memory is a concern.
  """

  use PlaidEx.Support.EtsGenServer, table: :plaid_ex_webhook_dedup

  require Logger

  @cleanup_interval_ms :timer.minutes(5)

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Checks if a webhook has been seen before.

  If not seen, records it and returns `:ok`.
  If already seen, returns `{:error, :duplicate}`.

  This is an atomic check-and-set using ETS `insert_new/2`.
  """
  @spec check_and_record(term()) :: :ok | {:error, :duplicate}
  def check_and_record(:no_id) do
    # Unidentifiable webhooks always pass through
    :ok
  end

  def check_and_record(webhook_id) do
    window_seconds = Application.get_env(:plaid_ex, :webhook_dedup_window_seconds, 3600)
    expires_at = System.system_time(:second) + window_seconds

    # insert_new returns false if the key already exists — atomic and fast
    if :ets.insert_new(@table, {webhook_id, expires_at}) do
      :ok
    else
      :telemetry.execute([:plaid_ex, :webhook, :duplicate], %{}, %{
        webhook_id: webhook_id
      })

      {:error, :duplicate}
    end
  end

  @doc """
  Derives a deduplication ID from webhook event fields.
  """
  @spec derive_id(map()) :: String.t()
  def derive_id(%{} = event) do
    # Quantize to 5-second windows to tolerate minor timing differences
    quantized_ts = div(System.system_time(:second), 5)

    key =
      [
        event["webhook_type"] || "",
        event["webhook_code"] || "",
        event["item_id"] || "",
        event["account_id"] || "",
        to_string(quantized_ts)
      ]

    key = Enum.join(key, ":")

    hash = :crypto.hash(:sha256, key)
    Base.encode16(hash, case: :lower)
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  defp init_state(table) do
    schedule_cleanup()
    %{table: table}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    deleted = :ets.select_delete(@table, [{{:_, :"$1"}, [{:<, :"$1", now}], [true]}])

    if deleted > 0 do
      Logger.debug("[PlaidEx.Deduplicator] Cleaned up #{deleted} expired webhook IDs")
    end

    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup do
    Process.send_after(self(), :cleanup, @cleanup_interval_ms)
  end
end
