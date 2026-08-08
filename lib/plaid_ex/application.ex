# PlaidEx.Application wires up the full OTP supervision tree — by definition
# it references every top-level supervised module.
# credo:disable-for-this-file Credo.Check.Refactor.ModuleDependencies
defmodule PlaidEx.Application do
  @moduledoc false
  use Application
  require Logger

  alias PlaidEx.Reliability.CircuitBreakerSupervisor

  @impl Application
  def start(_, _) do
    config = load_config()

    Logger.info(
      "[PlaidEx] Starting v#{Application.spec(:plaid_ex, :vsn)} " <>
        "environment=#{config.environment} region=#{config.region}"
    )

    children =
      [
        # ── Process registries (must come first) ──────────────────────────────
        {Registry, keys: :unique, name: PlaidEx.SyncRegistry},
        {Registry, keys: :unique, name: PlaidEx.TenantRegistry},
        {Registry, keys: :unique, name: PlaidEx.CircuitBreakerRegistry},
        {Registry, keys: :unique, name: PlaidEx.BulkheadRegistry},

        # ── HTTP connection pools ─────────────────────────────────────────────
        finch_child_spec(config),

        # ── Tenant config registry (ETS) ─────────────────────────────────────
        PlaidEx.Config.TenantRegistry,

        # ── Rate limiter (ETS token buckets) ─────────────────────────────────
        PlaidEx.HTTP.RateLimiter,

        # ── Circuit breakers (DynamicSupervisor) ─────────────────────────────
        PlaidEx.Reliability.CircuitBreakerSupervisor,

        # ── OAuth state store (ETS, short-lived) ─────────────────────────────
        PlaidEx.OAuth.StateStore,

        # ── Webhook deduplication window (ETS) ───────────────────────────────
        PlaidEx.Webhooks.Deduplicator,

        # ── ETS cursor store for sync workers ────────────────────────────────
        PlaidEx.Sync.CursorStore.EtsBackend,

        # ── Transaction sync DynamicSupervisor ───────────────────────────────
        PlaidEx.Sync.SyncSupervisor,

        # ── Multi-tenant DynamicSupervisor ───────────────────────────────────
        PlaidEx.MultiTenant.TenantSupervisor,

        # ── Task supervisor for async webhook dispatch ────────────────────────
        {Task.Supervisor, name: PlaidEx.TaskSupervisor}
      ]

    children = maybe_add_oban_workers(children)

    opts = [strategy: :one_for_one, name: PlaidEx.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Bootstrap default circuit breakers for known environments
        boot_circuit_breakers(config)
        {:ok, pid}

      error ->
        error
    end
  end

  @impl Application
  def stop(_) do
    Logger.info("[PlaidEx] Application stopping, draining sync workers...")
    :ok
  end

  # ── Private helpers ─────────────────────────────────────────────────────────

  defp load_config do
    if Application.get_env(:plaid_ex, :client_id) do
      PlaidEx.Config.load!()
    else
      # Minimal default so the supervision tree can start even without full config.
      # Individual API calls will fail clearly with missing credentials.
      %PlaidEx.Config{client_id: "not_configured", secret: "not_configured"}
    end
  end

  defp finch_child_spec(config) do
    {Finch,
     name: PlaidEx.Finch,
     pools: %{
       "https://production.plaid.com" => [
         size: config.pool_size,
         count: config.pool_count,
         conn_opts: conn_opts(config)
       ],
       "https://production.eu.plaid.com" => [
         size: max(div(config.pool_size, 2), 4),
         count: max(div(config.pool_count, 2), 2),
         conn_opts: conn_opts(config)
       ],
       "https://sandbox.plaid.com" => [
         size: 8,
         count: 2,
         conn_opts: conn_opts(config)
       ],
       "https://development.plaid.com" => [
         size: 8,
         count: 2,
         conn_opts: conn_opts(config)
       ],
       # Default pool for any unmatched URLs
       :default => [size: 4, count: 1]
     }}
  end

  defp conn_opts(config) do
    [transport_opts: [timeout: config.connect_timeout_ms]]
  end

  defp boot_circuit_breakers(config) do
    environments = [:sandbox, :development, :production]

    Enum.each(environments, fn env ->
      CircuitBreakerSupervisor.ensure_started(env, config)
    end)
  end

  defp maybe_add_oban_workers(children) do
    if oban_available?() do
      Logger.debug("[PlaidEx] Oban detected — webhook jobs enabled")
      children
    else
      Logger.debug("[PlaidEx] Oban not available — webhook jobs use Task.Supervisor")
      children
    end
  end

  defp oban_available? do
    Code.ensure_loaded?(Oban)
  end
end
