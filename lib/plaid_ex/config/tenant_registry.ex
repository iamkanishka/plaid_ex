defmodule PlaidEx.Config.TenantRegistry do
  @moduledoc """
  ETS-backed registry for multi-tenant Plaid configurations.

  Stores per-tenant `PlaidEx.Config` structs for runtime lookup.
  Supports secret rotation without application restart.

  ## Usage

      # Register a tenant at runtime (e.g., when a user connects Plaid)
      PlaidEx.Config.TenantRegistry.register("acme_corp",
        PlaidEx.Config.new!(
          client_id: vault.get("acme/plaid/client_id"),
          secret: vault.get("acme/plaid/secret"),
          environment: :production,
          tenant_id: "acme_corp"
        )
      )

      # Retrieve tenant config for an API call
      {:ok, config} = PlaidEx.Config.TenantRegistry.get("acme_corp")

      # Rotate a secret without full re-registration
      PlaidEx.Config.TenantRegistry.update_secret("acme_corp", new_secret)

      # Remove a tenant (e.g., when they unsubscribe)
      PlaidEx.Config.TenantRegistry.deregister("acme_corp")
  """

  use PlaidEx.Support.EtsGenServer, table: :plaid_ex_tenant_registry

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc "Registers or updates a tenant configuration."
  @spec register(String.t(), PlaidEx.Config.t()) :: :ok
  def register(tenant_id, %PlaidEx.Config{} = config) when is_binary(tenant_id) do
    :ets.insert(@table, {tenant_id, config})
    :ok
  end

  @doc "Retrieves a tenant's configuration."
  @spec get(String.t()) :: {:ok, PlaidEx.Config.t()} | :not_found
  def get(tenant_id) when is_binary(tenant_id) do
    case :ets.lookup(@table, tenant_id) do
      [{^tenant_id, config}] -> {:ok, config}
      [] -> :not_found
    end
  end

  @doc """
  Retrieves a tenant config or raises if not found.
  Useful in pipelines where a missing tenant is a programming error.
  """
  @spec get!(String.t()) :: PlaidEx.Config.t()
  def get!(tenant_id) do
    case get(tenant_id) do
      {:ok, config} -> config
      :not_found -> raise ArgumentError, "PlaidEx: tenant #{inspect(tenant_id)} not registered"
    end
  end

  @doc "Rotates the secret for a tenant without full re-registration."
  @spec update_secret(String.t(), String.t()) :: :ok | :not_found
  def update_secret(tenant_id, new_secret) when is_binary(new_secret) do
    case get(tenant_id) do
      {:ok, config} ->
        updated = PlaidEx.Config.rotate_secret(config, new_secret)
        register(tenant_id, updated)
        :ok

      :not_found ->
        :not_found
    end
  end

  @doc "Removes a tenant from the registry."
  @spec deregister(String.t()) :: :ok
  def deregister(tenant_id) do
    :ets.delete(@table, tenant_id)
    :ok
  end

  @doc "Lists all registered tenant IDs."
  @spec list_tenants() :: [String.t()]
  def list_tenants do
    :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
  end

  @doc "Returns the number of registered tenants."
  @spec count() :: non_neg_integer()
  def count, do: :ets.info(@table, :size)

  # ── GenServer (owns the ETS table) ───────────────────────────────────────────
end
