# PlaidEx is the library's public facade — it necessarily references every API and support module it delegates to.
# credo:disable-for-this-file Credo.Check.Refactor.ModuleDependencies
defmodule PlaidEx do
  @moduledoc """
  PlaidEx — Production-grade Plaid API client for Elixir/OTP.

  ## Features

  - **Full Plaid API coverage** — Link, Transactions, Auth, Identity, Investments,
    Liabilities, Transfer, Signal, Beacon, Assets, Income, Statements, Institutions,
    Sandbox, and more
  - **Typed schemas** — all responses are typed structs, never raw maps
  - **Resilient HTTP** — exponential backoff, full jitter, circuit breakers,
    idempotency, per-tenant rate limiting
  - **Webhook orchestration** — signature verification, deduplication, typed events,
    Oban integration
  - **Cursor-based sync** — durable transaction sync with OTP-supervised workers,
    pluggable cursor persistence
  - **Multi-tenant** — runtime credential injection, per-tenant process isolation
  - **OpenTelemetry** — distributed tracing across sync workers and webhook handlers
  - **Telemetry** — deep metrics for all operations

  ## Quick start

      # config/config.exs
      config :plaid_ex,
        client_id: System.get_env("PLAID_CLIENT_ID"),
        secret: System.get_env("PLAID_SECRET"),
        environment: :sandbox

      # Create a Link token (server-side only)
      {:ok, link} = PlaidEx.create_link_token(
        user: %{client_user_id: "user-abc123"},
        client_name: "Acme Finance",
        products: ["transactions"],
        country_codes: ["US"],
        language: "en"
      )

      # Exchange public token after Link completes
      {:ok, result} = PlaidEx.exchange_public_token("public-sandbox-...")
      access_token = result.access_token

      # Start continuous transaction sync
      {:ok, _pid} = PlaidEx.start_transaction_sync(access_token,
        handler: fn page ->
          MyApp.Transactions.upsert_batch(page.added)
          :ok
        end
      )

  ## Multi-tenant quick start

      # Register each tenant's credentials at runtime
      config = PlaidEx.Config.new!(
        client_id: vault.get("tenant/plaid/client_id"),
        secret: vault.get("tenant/plaid/secret"),
        environment: :production,
        tenant_id: "acme_corp"
      )
      TenantRegistry.register("acme_corp", config)

      # Use tenant config for all API calls
      {:ok, token} = PlaidEx.create_link_token(config, user: %{...})

  ## Webhook setup

      # In your Phoenix router
      forward "/webhooks/plaid", PlaidEx.Webhooks.Plug,
        config: PlaidEx.Config.load!(),
        handler: MyApp.PlaidWebhookHandler

      # Handler module
      defmodule MyApp.PlaidWebhookHandler do
        use PlaidEx.Webhooks.Handler

        @impl true
        def on_transactions_sync(%{item_id: item_id}) do
          TransactionSync.trigger_sync(
            MyApp.Items.get_access_token!(item_id)
          )
          :ok
        end
      end

  ## Configuration reference

  See `PlaidEx.Config` for all available configuration options.

  ## API modules

  | Module | Plaid Product |
  |--------|--------------|
  | `PlaidEx.API.Link` | Link Token lifecycle |
  | `PlaidEx.API.Items` | Item management |
  | `PlaidEx.API.Accounts` | Account data |
  | `PlaidEx.API.Transactions` | Transactions |
  | `PlaidEx.API.Auth` | ACH routing numbers |
  | `PlaidEx.API.Identity` | Account owner identity |
  | `PlaidEx.API.Investments` | Investment holdings/transactions |
  | `PlaidEx.API.Liabilities` | Loans, mortgages, credit cards |
  | `PlaidEx.API.Transfer` | ACH/RTP transfers |
  | `PlaidEx.API.Signal` | ACH return risk |
  | `PlaidEx.API.Beacon` | Fraud network |
  | `PlaidEx.API.Assets` | Asset reports |
  | `PlaidEx.API.Income` | Income verification |
  | `PlaidEx.API.Statements` | Bank statements |
  | `PlaidEx.API.Institutions` | Institution search/metadata |
  | `PlaidEx.API.Monitor` | Watchlist screening |
  | `PlaidEx.API.Processor` | Processor token operations |
  | `PlaidEx.API.Sandbox` | Sandbox test utilities |
  """

  alias PlaidEx.API.Accounts
  alias PlaidEx.API.Items
  alias PlaidEx.API.Link
  alias PlaidEx.Config
  alias PlaidEx.Config.TenantRegistry
  alias PlaidEx.Error
  alias PlaidEx.OAuth.Flow
  alias PlaidEx.Reliability.CircuitBreaker
  alias PlaidEx.Schemas.AccessToken
  alias PlaidEx.Schemas.LinkToken
  alias PlaidEx.Sync.SyncSupervisor
  alias PlaidEx.Sync.TransactionSync
  alias PlaidEx.Telemetry.Handler
  alias PlaidEx.Telemetry.Metrics

  # ── Config ───────────────────────────────────────────────────────────────────

  @doc """
  Returns the current application-level PlaidEx config.

  For multi-tenant usage, use `PlaidEx.Config.TenantRegistry.get/1` instead.
  """
  @spec config() :: Config.t()
  def config, do: Config.load!()

  # Dialyzer: The single-tenant convenience functions all call config/0 which
  # delegates to Config.load!/0. Config.load!/0 raises ArgumentError if the
  # application is not configured. Dialyzer correctly identifies this raise
  # path. We suppress no_return warnings here — in a properly configured
  # application these functions always return. Multi-tenant callers pass an
  # explicit Config.t() and avoid this entirely.
  @dialyzer {:nowarn_function,
             [
               create_link_token: 1,
               create_link_token: 2,
               exchange_public_token: 1,
               exchange_public_token: 2,
               remove_item: 1,
               remove_item: 2,
               get_accounts: 1,
               get_accounts: 2,
               get_balances: 1,
               get_balances: 2,
               start_transaction_sync: 2,
               initiate_oauth: 1,
               complete_oauth: 1,
               register_tenant: 2,
               get_tenant_config: 1,
               rotate_tenant_secret: 2,
               trigger_transaction_sync: 1,
               stop_transaction_sync: 1,
               transaction_sync_status: 1,
               circuit_breaker_status: 0,
               reset_circuit_breaker: 1,
               health: 0
             ]}

  # ── Link ─────────────────────────────────────────────────────────────────────

  @doc """
  Creates a Plaid Link token using application config.

  ## Example

      {:ok, %{link_token: token}} = PlaidEx.create_link_token(
        user: %{client_user_id: "user-123"},
        client_name: "My App",
        products: ["transactions"],
        country_codes: ["US"],
        language: "en"
      )
  """
  @spec create_link_token(keyword() | map()) :: {:ok, LinkToken.t()} | {:error, Error.t()}
  @spec create_link_token(keyword() | map(), keyword()) ::
          {:ok, LinkToken.t()} | {:error, Error.t()}
  def create_link_token(params, opts \\ []) do
    Link.create_token(config(), params, opts)
  end

  @doc "Creates a Link token with explicit config (for multi-tenant)."
  @spec create_link_token(Config.t(), keyword() | map(), keyword()) ::
          {:ok, LinkToken.t()} | {:error, Error.t()}
  def create_link_token(%Config{} = config, params, opts) do
    Link.create_token(config, params, opts)
  end

  # ── Items ────────────────────────────────────────────────────────────────────

  @doc """
  Exchanges a Link `public_token` for a permanent `access_token`.

  ## Example

      {:ok, %{access_token: token, item_id: id}} =
        PlaidEx.exchange_public_token("public-sandbox-abc123")
  """
  @spec exchange_public_token(String.t()) :: {:ok, AccessToken.t()} | {:error, Error.t()}
  @spec exchange_public_token(String.t(), keyword()) ::
          {:ok, AccessToken.t()} | {:error, Error.t()}
  def exchange_public_token(public_token, opts \\ []) do
    Items.exchange_public_token(config(), public_token, opts)
  end

  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  @spec exchange_public_token(Config.t(), String.t(), keyword()) ::
          {:ok, AccessToken.t()} | {:error, Error.t()}
  def exchange_public_token(%Config{} = config, public_token, opts) do
    Items.exchange_public_token(config, public_token, opts)
  end

  @doc "Removes an Item (revokes access token, disconnects accounts)."
  @spec remove_item(String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec remove_item(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def remove_item(access_token, opts \\ []) do
    Items.remove(config(), access_token, opts)
  end

  @spec remove_item(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def remove_item(%Config{} = config, access_token, opts) do
    Items.remove(config, access_token, opts)
  end

  # ── Accounts ─────────────────────────────────────────────────────────────────

  @doc "Returns accounts for an Item."
  @spec get_accounts(String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_accounts(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_accounts(access_token, opts \\ []) do
    Accounts.get(config(), access_token, opts)
  end

  @doc "Returns real-time balances."
  @spec get_balances(String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_balances(String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_balances(access_token, opts \\ []) do
    Accounts.get_balance(config(), access_token, opts)
  end

  # ── Transaction Sync ─────────────────────────────────────────────────────────

  @doc """
  Starts a continuous cursor-based transaction sync worker.

  The worker runs in a supervised process, polling for new transactions
  every `sync_poll_interval_ms` (default 30s). Handles all retry and
  error logic automatically.

  The handler function MUST:
  - Accept a `PlaidEx.Schemas.TransactionSyncPage` struct
  - Return `:ok` on success
  - Return `{:error, reason}` on failure
  - Be **idempotent** — may be called multiple times for the same page

  ## Example

      {:ok, _pid} = PlaidEx.start_transaction_sync(access_token,
        handler: fn page ->
          MyApp.Transactions.upsert_batch(page.added)
          MyApp.Transactions.update_batch(page.modified)
          MyApp.Transactions.remove_batch(Enum.map(page.removed, & &1.transaction_id))
          :ok
        end,
        tenant_id: "acme_corp"
      )
  """
  @spec start_transaction_sync(String.t(), keyword()) ::
          {:ok, pid()} | {:error, :already_started | term()}
  def start_transaction_sync(access_token, opts) do
    TransactionSync.start_worker(access_token, config(), opts)
  end

  @spec start_transaction_sync(Config.t(), String.t(), keyword()) ::
          {:ok, pid()} | {:error, :already_started | term()}
  def start_transaction_sync(%Config{} = config, access_token, opts) do
    TransactionSync.start_worker(access_token, config, opts)
  end

  @doc "Triggers an immediate sync cycle for an access token."
  @spec trigger_transaction_sync(String.t()) :: :ok | {:error, :not_found}
  def trigger_transaction_sync(access_token) do
    TransactionSync.trigger_sync(access_token)
  end

  @doc "Stops a running transaction sync worker."
  @spec stop_transaction_sync(String.t()) :: :ok | {:error, :not_found}
  def stop_transaction_sync(access_token) do
    TransactionSync.stop_worker(access_token)
  end

  @doc "Returns status of a transaction sync worker."
  @spec transaction_sync_status(String.t()) :: {:ok, map()} | {:error, :not_found}
  def transaction_sync_status(access_token) do
    TransactionSync.status(access_token)
  end

  # ── OAuth ────────────────────────────────────────────────────────────────────

  @doc """
  Initiates an OAuth Link flow for OAuth-required institutions.

  See `PlaidEx.OAuth.Flow` for full documentation.
  """
  @spec initiate_oauth(keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def initiate_oauth(opts) do
    Flow.initiate(config(), opts)
  end

  @spec initiate_oauth(Config.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def initiate_oauth(%Config{} = config, opts) do
    Flow.initiate(config, opts)
  end

  @doc "Completes an OAuth flow after the user is redirected back."
  @spec complete_oauth(keyword()) ::
          {:ok, map()} | {:error, Error.t() | atom()}
  def complete_oauth(opts) do
    Flow.complete(config(), opts)
  end

  # ── Circuit breakers ─────────────────────────────────────────────────────────

  @doc "Returns the status of all circuit breakers."
  @spec circuit_breaker_status() :: map()
  def circuit_breaker_status do
    [:sandbox, :development, :production]
    |> Enum.map(fn env ->
      {env, CircuitBreaker.status(env)}
    end)
    |> Map.new()
  end

  @doc "Manually resets a circuit breaker (use with caution)."
  @spec reset_circuit_breaker(atom()) :: :ok
  def reset_circuit_breaker(environment) do
    CircuitBreaker.reset(environment)
  end

  # ── Multi-tenant ─────────────────────────────────────────────────────────────

  @doc "Registers a tenant configuration at runtime."
  @spec register_tenant(String.t(), Config.t()) :: :ok
  def register_tenant(tenant_id, %Config{} = config) do
    TenantRegistry.register(tenant_id, config)
  end

  @doc "Retrieves a tenant configuration."
  @spec get_tenant_config(String.t()) :: {:ok, Config.t()} | :not_found
  def get_tenant_config(tenant_id) do
    TenantRegistry.get(tenant_id)
  end

  @doc "Rotates a tenant's API secret without full re-registration."
  @spec rotate_tenant_secret(String.t(), String.t()) :: :ok | :not_found
  def rotate_tenant_secret(tenant_id, new_secret) do
    TenantRegistry.update_secret(tenant_id, new_secret)
  end

  # ── Telemetry ────────────────────────────────────────────────────────────────

  @doc """
  Attaches the default structured logging telemetry handler.

  Call this in your application start to get automatic logging
  of all PlaidEx operations.

      def start(_type, _args) do
        PlaidEx.attach_telemetry()
        # ...
      end
  """
  @spec attach_telemetry() :: :ok
  @spec attach_telemetry(keyword()) :: :ok
  def attach_telemetry(opts \\ []) do
    Handler.attach_all(opts)
  end

  @doc "Returns all Telemetry.Metrics definitions for PlaidEx."
  @spec telemetry_metrics() :: [Telemetry.Metrics.t()]
  def telemetry_metrics do
    Metrics.metrics()
  end

  # ── Health checks ─────────────────────────────────────────────────────────────

  @doc """
  Returns the health status of the PlaidEx subsystem.

  Useful for health check endpoints and monitoring dashboards.

      GET /health/plaid -> PlaidEx.health()
  """
  @spec health() :: map()
  def health do
    %{
      status: :ok,
      version: to_string(Application.spec(:plaid_ex, :vsn)),
      sync_workers: SyncSupervisor.worker_count(),
      circuit_breakers: circuit_breaker_status(),
      registered_tenants: TenantRegistry.count()
    }
  end
end
