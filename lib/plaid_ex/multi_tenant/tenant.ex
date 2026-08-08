defmodule PlaidEx.MultiTenant.Tenant do
  @moduledoc """
  GenServer representing an active tenant context.

  Holds the tenant's config, provides a process boundary for
  tenant-scoped operations, and registers in the TenantRegistry.
  """

  use GenServer
  require Logger

  alias PlaidEx.Config.TenantRegistry
  alias PlaidEx.HTTP.RateLimiter

  @spec start_link({String.t(), PlaidEx.Config.t()}) :: GenServer.on_start()
  def start_link({tenant_id, config}) do
    GenServer.start_link(__MODULE__, {tenant_id, config})
  end

  @impl GenServer
  def init({tenant_id, config}) do
    case Registry.register(PlaidEx.TenantRegistry, tenant_id, %{started_at: DateTime.utc_now()}) do
      {:ok, _} ->
        TenantRegistry.register(tenant_id, config)
        RateLimiter.configure_tenant(tenant_id, requests_per_second: 50)

        Logger.info("[PlaidEx.Tenant] Started tenant_id=#{tenant_id} env=#{config.environment}")

        {:ok, %{tenant_id: tenant_id, config: config}}

      {:error, {:already_registered, pid}} ->
        Logger.warning(
          "[PlaidEx.Tenant] tenant_id=#{tenant_id} already has an active process " <>
            "pid=#{inspect(pid)} — refusing duplicate start"
        )

        {:stop, {:already_started, pid}}
    end
  end

  @impl GenServer
  def terminate(reason, %{tenant_id: tenant_id}) do
    Logger.info("[PlaidEx.Tenant] Stopping tenant_id=#{tenant_id} reason=#{inspect(reason)}")
    :ok
  end
end
