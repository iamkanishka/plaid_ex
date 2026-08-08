defmodule PlaidEx.HTTP.RateLimiter do
  @moduledoc """
  ETS-backed token bucket rate limiter with per-tenant isolation.

  Each tenant (or `:global` for single-tenant deployments) gets its own
  token bucket. Buckets are refilled on a configurable interval.

  Plaid's rate limits vary by plan and endpoint. This limiter acts as a
  client-side guard to prevent hammering Plaid before their server responds
  with `RATE_LIMIT_EXCEEDED`. When Plaid does return a rate limit error,
  the HTTP client's retry logic handles it with backoff.

  ## Architecture

  Uses a GenServer to own the ETS table (so the table survives the
  calling process crashing) with an ETS-based fast path for the common
  check case. Refill happens via `Process.send_after`.

  ## Bucket defaults

  - `:global`    — 200 requests/second (conservative Plaid production limit)
  - Per-tenant   — 50 requests/second (safe default for multi-tenant)

  Override by calling `configure_tenant/2`.
  """

  use PlaidEx.Support.EtsGenServer, table: :plaid_ex_rate_limiter

  require Logger

  @default_global_rps 200
  @default_tenant_rps 50
  @refill_interval_ms 100

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Checks whether a request is allowed under the current rate limit.

  Returns `:ok` if allowed, `{:error, :rate_limited}` if the bucket
  is empty. Does NOT block — callers should treat `:rate_limited` as
  a fast-fail signal and apply their own backoff.
  """
  @spec check(String.t() | :global, PlaidEx.Config.t()) :: :ok | {:error, :rate_limited}
  def check(tenant_id, _) do
    key = bucket_key(tenant_id)

    # Use a two-step lookup + update to avoid passing an invalid ETS default.
    # lookup/2 is O(1) and safe for Dialyzer — returns [] or [{key, tokens, max}].
    case :ets.lookup(@table, key) do
      [] ->
        # Bucket doesn't exist yet — create and allow
        ensure_bucket(tenant_id)
        :ok

      [{^key, 0, _}] ->
        :telemetry.execute([:plaid_ex, :rate_limit, :throttled], %{}, %{tenant_id: tenant_id})
        {:error, :rate_limited}

      [{^key, _, _}] ->
        # Atomically decrement, floor at 0. The returned post-decrement
        # value isn't needed — the prior lookup already determined we're
        # in the "tokens available" branch.
        _ = :ets.update_counter(@table, key, [{2, -1, 0, 0}])
        :ok
    end
  end

  @doc """
  Configures a custom rate limit for a specific tenant.

      PlaidEx.HTTP.RateLimiter.configure_tenant("acme", requests_per_second: 100)
  """
  @spec configure_tenant(String.t() | :global, keyword()) :: :ok
  def configure_tenant(tenant_id, opts) do
    rps = Keyword.get(opts, :requests_per_second, @default_tenant_rps)
    GenServer.cast(__MODULE__, {:configure, tenant_id, rps})
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  @spec init_state(:ets.table()) :: %{
          table: :ets.table(),
          configs: %{(String.t() | :global) => pos_integer()}
        }
  defp init_state(table) do
    create_bucket(:global, @default_global_rps)
    schedule_refill()
    %{table: table, configs: %{global: @default_global_rps}}
  end

  @impl GenServer
  def handle_cast({:configure, tenant_id, rps}, state) do
    key = bucket_key(tenant_id)
    :ets.insert(@table, {key, rps, rps})
    {:noreply, put_in(state, [:configs, tenant_id], rps)}
  end

  @impl GenServer
  def handle_info(:refill, state) do
    refill_all_buckets(state.configs)
    schedule_refill()
    {:noreply, state}
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  @spec ensure_bucket(String.t() | :global) :: boolean()
  defp ensure_bucket(tenant_id) do
    key = bucket_key(tenant_id)
    rps = if tenant_id == :global, do: @default_global_rps, else: @default_tenant_rps
    :ets.insert_new(@table, {key, rps, rps})
  end

  @spec create_bucket(:global, 200) :: true
  defp create_bucket(tenant_id, rps) do
    key = bucket_key(tenant_id)
    :ets.insert(@table, {key, rps, rps})
  end

  @spec refill_all_buckets(map()) :: :ok
  defp refill_all_buckets(configs) do
    Enum.each(configs, fn {tenant_id, rps} ->
      key = bucket_key(tenant_id)
      refill_amount = max(div(rps, 10), 1)

      :ets.update_counter(@table, key, [{2, refill_amount, rps, rps}], {key, rps, rps})
    end)
  end

  defp schedule_refill do
    Process.send_after(self(), :refill, @refill_interval_ms)
  end

  @spec bucket_key(String.t() | :global) :: :global | {:tenant, String.t()}
  defp bucket_key(:global), do: :global
  defp bucket_key(tenant_id), do: {:tenant, tenant_id}
end
