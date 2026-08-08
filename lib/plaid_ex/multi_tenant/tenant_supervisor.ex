defmodule PlaidEx.MultiTenant.TenantSupervisor do
  @moduledoc """
  DynamicSupervisor managing per-tenant process subtrees.

  Each tenant gets an isolated `Tenant` GenServer that owns:
  - Its own rate limiter token bucket (via TenantRegistry metadata)
  - Its own circuit breaker references
  - Lifecycle management (start/stop/restart)

  For most use cases, `PlaidEx.Config.TenantRegistry` is sufficient.
  Use this supervisor when you need active per-tenant processes
  (e.g., dedicated sync workers, polling loops).
  """

  use PlaidEx.Support.DynamicSupervisorBase
  require Logger

  @doc "Starts a tenant subtree if not already running."
  @spec ensure_tenant(String.t(), PlaidEx.Config.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_tenant(tenant_id, config) do
    case Registry.lookup(PlaidEx.TenantRegistry, tenant_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        child = %{
          id: {:tenant, tenant_id},
          start: {PlaidEx.MultiTenant.Tenant, :start_link, [{tenant_id, config}]},
          restart: :transient
        }

        DynamicSupervisor.start_child(__MODULE__, child)
    end
  end

  @doc "Stops a tenant's subtree."
  @spec stop_tenant(String.t()) :: :ok | {:error, :not_found}
  def stop_tenant(tenant_id) do
    case Registry.lookup(PlaidEx.TenantRegistry, tenant_id) do
      [{pid, _}] ->
        case DynamicSupervisor.terminate_child(__MODULE__, pid) do
          :ok ->
            Logger.info("[PlaidEx] Tenant stopped tenant_id=#{tenant_id}")
            :ok

          {:error, :not_found} ->
            {:error, :not_found}
        end

      [] ->
        {:error, :not_found}
    end
  end
end
