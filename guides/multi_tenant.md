# Multi-Tenant Deployments

PlaidEx is designed for multi-tenant SaaS platforms where each tenant
has their own Plaid credentials, isolated processes, and independent rate limits.

## Architecture overview

```
TenantRegistry (ETS)
  ├── "acme_corp" → %PlaidEx.Config{client_id: ..., secret: ...}
  ├── "beta_inc"  → %PlaidEx.Config{client_id: ..., secret: ...}
  └── "gamma_llc" → %PlaidEx.Config{client_id: ..., secret: ...}

TenantSupervisor (DynamicSupervisor)
  ├── Tenant("acme_corp")  ← per-tenant rate limiter config
  ├── Tenant("beta_inc")
  └── Tenant("gamma_llc")

SyncSupervisor (DynamicSupervisor)
  ├── TransactionSync("access-acme-...") ← tagged with tenant_id
  ├── TransactionSync("access-beta-...")
  └── TransactionSync("access-gamma-...")

RateLimiter (ETS)
  ├── :global          → 200 req/s (fallback)
  ├── {:tenant, "acme_corp"} → 100 req/s
  ├── {:tenant, "beta_inc"}  → 50 req/s
  └── {:tenant, "gamma_llc"} → 25 req/s
```

## Tenant registration

### On tenant onboarding

```elixir
defmodule MyApp.PlaidTenants do
  alias PlaidEx.Config
  alias PlaidEx.Config.TenantRegistry

  def onboard_tenant(tenant, plaid_credentials) do
    config = Config.new!(
      client_id: plaid_credentials.client_id,
      secret: plaid_credentials.secret,
      environment: :production,
      region: :us,
      webhook_secret: plaid_credentials.webhook_secret,
      tenant_id: tenant.id,
      pool_size: 20,
      # Add tenant-specific metadata for tracing
      metadata: %{
        tenant_name: tenant.name,
        plan: tenant.plan
      }
    )

    # Register config for fast runtime lookup
    TenantRegistry.register(tenant.id, config)

    # Configure rate limit based on tenant plan
    rps = rate_limit_for_plan(tenant.plan)
    PlaidEx.HTTP.RateLimiter.configure_tenant(tenant.id, requests_per_second: rps)

    # Optionally start a supervised tenant process
    PlaidEx.MultiTenant.TenantSupervisor.ensure_tenant(tenant.id, config)

    :ok
  end

  defp rate_limit_for_plan(:starter), do: 20
  defp rate_limit_for_plan(:growth), do: 50
  defp rate_limit_for_plan(:enterprise), do: 200
end
```

### On tenant offboarding

```elixir
def offboard_tenant(tenant) do
  # Stop all sync workers for this tenant
  PlaidEx.Sync.SyncSupervisor.list_workers()
  |> Enum.filter(fn w -> w[:tenant_id] == tenant.id end)
  |> Enum.each(fn w -> PlaidEx.Sync.TransactionSync.stop_worker(w.access_token) end)

  # Stop the tenant process
  PlaidEx.MultiTenant.TenantSupervisor.stop_tenant(tenant.id)

  # Deregister config
  PlaidEx.Config.TenantRegistry.deregister(tenant.id)
end
```

## Using tenant configs in API calls

```elixir
defmodule MyApp.PlaidService do
  alias PlaidEx.Config.TenantRegistry

  def create_link_token(tenant_id, user_id, products) do
    with {:ok, config} <- TenantRegistry.get(tenant_id) do
      PlaidEx.API.Link.create_token(config,
        user: %{client_user_id: user_id},
        client_name: "Acme Platform",
        products: products,
        country_codes: ["US"],
        language: "en"
      )
    else
      :not_found -> {:error, :tenant_not_configured}
    end
  end

  def get_accounts(tenant_id, access_token) do
    config = TenantRegistry.get!(tenant_id)
    PlaidEx.API.Accounts.get(config, access_token)
  end

  def start_sync(tenant_id, access_token) do
    config = TenantRegistry.get!(tenant_id)

    PlaidEx.start_transaction_sync(config, access_token,
      handler: fn page ->
        MyApp.Transactions.process(tenant_id, page)
        :ok
      end,
      tenant_id: tenant_id
    )
  end
end
```

## Secret rotation

Rotate secrets without application restart:

```elixir
defmodule MyApp.PlaidSecretRotation do
  def rotate(tenant_id, new_secret) do
    # Update in PlaidEx runtime registry
    case PlaidEx.rotate_tenant_secret(tenant_id, new_secret) do
      :ok ->
        # Update in your database/vault
        MyApp.Repo.update_all(
          from(t in Tenant, where: t.id == ^tenant_id),
          set: [plaid_secret_encrypted: MyApp.Vault.encrypt!(new_secret)]
        )
        {:ok, :rotated}

      :not_found ->
        {:error, :tenant_not_found}
    end
  end
end
```

## Tenant-aware telemetry

All PlaidEx telemetry events include `tenant_id` in their metadata.
Use this to build per-tenant metrics:

```elixir
:telemetry.attach_many("my_tenant_metrics",
  [
    [:plaid_ex, :http, :stop],
    [:plaid_ex, :http, :error],
    [:plaid_ex, :sync, :page],
    [:plaid_ex, :webhook, :received]
  ],
  fn event_name, measurements, %{tenant_id: tenant_id}, _ ->
    metric_name = Enum.join(event_name, ".")
    MyMetrics.increment(metric_name, tags: [tenant: tenant_id])
  end,
  nil
)
```

## Multi-tenant webhook routing

If each tenant has their own webhook endpoint:

```elixir
# router.ex
scope "/webhooks/plaid/:tenant_id" do
  pipe_through :plaid_webhooks
  forward "/", PlaidEx.Webhooks.Plug,
    config: &MyApp.PlaidTenants.config_for_tenant/1,
    handler: MyApp.PlaidWebhooks
end
```

Or use a single endpoint with tenant resolution from the event:

```elixir
defmodule MyApp.PlaidWebhooks do
  use PlaidEx.Webhooks.Handler

  @impl true
  def on_transactions_sync(%{item_id: item_id} = event) do
    # Look up tenant from item_id
    case MyApp.PlaidItems.get_tenant_by_item_id(item_id) do
      nil -> :ok
      tenant_id ->
        access_token = MyApp.PlaidItems.get_access_token!(item_id)
        PlaidEx.trigger_transaction_sync(access_token)
        :ok
    end
  end
end
```

## Tenant isolation guarantees

PlaidEx provides these isolation properties:

| Resource | Isolation level |
|----------|----------------|
| API credentials | Full — each tenant has own `client_id`/`secret` |
| Rate limits | Per-tenant ETS token buckets |
| Sync workers | Per-item processes, tagged with `tenant_id` |
| Circuit breakers | Per-environment (shared — institution outages affect all) |
| Telemetry | `tenant_id` tag on all events |
| Log context | `tenant_id` in all structured log lines |
| Process crashes | Transient worker isolation — one crash doesn't affect others |

## Persistence on startup

In multi-tenant systems, tenants must be re-registered on application restart
since TenantRegistry uses ETS (in-memory):

```elixir
defmodule MyApp.Application do
  use Application

  def start(_type, _args) do
    children = [
      MyApp.Repo,
      MyAppWeb.Endpoint
      # PlaidEx starts automatically
    ]

    {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one)

    # Re-register all active tenants after supervision tree is up
    Task.start(fn ->
      Process.sleep(500)  # Brief wait for PlaidEx to initialize
      rehydrate_tenants()
    end)

    {:ok, sup}
  end

  defp rehydrate_tenants do
    require Logger

    MyApp.Repo.all(from t in MyApp.Tenant, where: t.plaid_enabled == true)
    |> Enum.each(fn tenant ->
      credentials = MyApp.Vault.decrypt_credentials!(tenant)

      PlaidEx.register_tenant(tenant.id,
        PlaidEx.Config.new!(
          client_id: credentials.client_id,
          secret: credentials.secret,
          environment: :production,
          tenant_id: tenant.id
        )
      )

      Logger.info("Re-registered Plaid tenant", tenant_id: tenant.id)
    end)
  end
end
```

## Load balancing across nodes

In a clustered deployment, each node has its own TenantRegistry. Use your
shared database as the authoritative source of credentials:

```elixir
# On each node startup:
defp rehydrate_tenants do
  MyApp.Repo.all(active_tenants_query())
  |> Enum.each(&register_tenant/1)
end

# On credential update (broadcast to all nodes):
defmodule MyApp.PlaidCredentialUpdater do
  use Phoenix.PubSub

  def rotate_secret(tenant_id, new_secret) do
    # Update database
    update_in_db(tenant_id, new_secret)

    # Update local node
    PlaidEx.rotate_tenant_secret(tenant_id, new_secret)

    # Broadcast to all other nodes
    Phoenix.PubSub.broadcast(MyApp.PubSub, "plaid_credentials",
      {:rotate_secret, tenant_id, new_secret}
    )
  end

  # On each node, subscribe and handle:
  def handle_info({:rotate_secret, tenant_id, new_secret}, state) do
    PlaidEx.rotate_tenant_secret(tenant_id, new_secret)
    {:noreply, state}
  end
end
```
