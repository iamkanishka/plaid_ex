defmodule PlaidEx.Config do
  @moduledoc """
  Validated runtime configuration for PlaidEx.

  Supports three configuration patterns:

  ## 1. Application config (compile-time / release config)

      # config/config.exs
      config :plaid_ex,
        client_id: System.get_env("PLAID_CLIENT_ID"),
        secret: System.get_env("PLAID_SECRET"),
        environment: :sandbox

  ## 2. Runtime struct construction (for multi-tenant / secrets managers)

      config = PlaidEx.Config.new!(
        client_id: vault.get("plaid/client_id"),
        secret: vault.get("plaid/secret"),
        environment: :production,
        tenant_id: "acme_corp"
      )

  ## 3. Dynamic per-call overrides

      PlaidEx.API.Transactions.sync(config, access_token: "access-...")

  ## Regions

  Plaid routes to different base URLs based on region:
  - `:us` → `production.plaid.com` / `sandbox.plaid.com`
  - `:eu` → `production.eu.plaid.com`
  - `:uk` → alias for `:eu` (same EU infrastructure)

  ## Environments

  - `:sandbox` — Plaid sandbox (test data, no real bank connections)
  - `:development` — Plaid development (real bank connections, limited items)
  - `:production` — Plaid production (real bank connections, full capacity)
  """

  @plaid_api_version "2020-09-14"

  @schema NimbleOptions.new!(
            client_id: [
              type: :string,
              required: true,
              doc: "Your Plaid `client_id` from the Plaid Dashboard."
            ],
            secret: [
              type: :string,
              required: true,
              doc: """
              Your Plaid `secret` for the given environment. Secrets differ per
              environment (sandbox / development / production). Rotate without
              restart by calling `PlaidEx.MultiTenant.TenantRegistry.update_secret/2`.
              """
            ],
            environment: [
              type: {:in, [:sandbox, :development, :production]},
              default: :sandbox,
              doc: "Plaid environment. Defaults to `:sandbox`."
            ],
            region: [
              type: {:in, [:us, :eu, :uk]},
              default: :us,
              doc: """
              API region. `:eu` and `:uk` both route to `production.eu.plaid.com`.
              Affects base URL selection and may affect available products/institutions.
              """
            ],
            pool_size: [
              type: :pos_integer,
              default: 20,
              doc: "Finch connection pool size per base URL. Increase for high-throughput."
            ],
            pool_count: [
              type: :pos_integer,
              default: 4,
              doc: "Number of Finch connection pools per base URL."
            ],
            request_timeout_ms: [
              type: :pos_integer,
              default: 30_000,
              doc: "Per-request HTTP timeout in milliseconds."
            ],
            connect_timeout_ms: [
              type: :pos_integer,
              default: 5_000,
              doc: "TCP connection timeout in milliseconds."
            ],
            retry_max_attempts: [
              type: :non_neg_integer,
              default: 3,
              doc: """
              Maximum number of retry attempts for retryable errors (rate limits,
              transient institution errors, 5xx). Set to 0 to disable retries.
              """
            ],
            retry_base_delay_ms: [
              type: :pos_integer,
              default: 500,
              doc: """
              Base delay for exponential backoff. Actual delay uses full jitter:
              `random_uniform(base * 2^attempt)` capped at 30 seconds.
              """
            ],
            retry_max_delay_ms: [
              type: :pos_integer,
              default: 30_000,
              doc: "Maximum retry delay cap in milliseconds."
            ],
            circuit_breaker_threshold: [
              type: :pos_integer,
              default: 5,
              doc: "Number of consecutive failures before opening the circuit breaker."
            ],
            circuit_breaker_reset_ms: [
              type: :pos_integer,
              default: 30_000,
              doc: "Time in milliseconds before a tripped circuit breaker enters half-open state."
            ],
            webhook_secret: [
              type: {:or, [:string, nil]},
              default: nil,
              doc: """
              Plaid webhook signing secret used to verify `Plaid-Verification` HMAC
              signatures. Found in the Plaid Dashboard → Webhooks. If `nil`, signature
              verification is skipped (not recommended for production).
              """
            ],
            oban_queue: [
              type: :atom,
              default: :plaid_webhooks,
              doc: "Oban queue name for durable webhook processing (requires `oban` dep)."
            ],
            oban_max_attempts: [
              type: :pos_integer,
              default: 10,
              doc: "Max Oban job attempts before moving to the dead-letter queue."
            ],
            telemetry_prefix: [
              type: {:list, :atom},
              default: [:plaid_ex],
              doc: """
              Prefix for all `:telemetry` events emitted by this library.
              Change if you have naming conflicts with other telemetry producers.
              """
            ],
            sync_poll_interval_ms: [
              type: :pos_integer,
              default: 30_000,
              doc: """
              Polling interval between transaction sync cycles when fully caught up.
              Plaid recommends no more frequent than 30 seconds.
              """
            ],
            cache_institutions_ttl_ms: [
              type: :pos_integer,
              default: :timer.hours(24),
              doc: "TTL for cached institution data in milliseconds."
            ],
            tenant_id: [
              type: {:or, [:string, nil]},
              default: nil,
              doc: "Optional tenant identifier for multi-tenant deployments."
            ],
            metadata: [
              type: :map,
              default: %{},
              doc: "Arbitrary metadata attached to this config (for tracing / logging)."
            ]
          )

  @type environment :: :sandbox | :development | :production
  @type region :: :us | :eu | :uk

  @type t :: %__MODULE__{
          client_id: String.t(),
          secret: String.t(),
          environment: environment(),
          region: region(),
          pool_size: pos_integer(),
          pool_count: pos_integer(),
          request_timeout_ms: pos_integer(),
          connect_timeout_ms: pos_integer(),
          retry_max_attempts: non_neg_integer(),
          retry_base_delay_ms: pos_integer(),
          retry_max_delay_ms: pos_integer(),
          circuit_breaker_threshold: pos_integer(),
          circuit_breaker_reset_ms: pos_integer(),
          webhook_secret: String.t() | nil,
          oban_queue: atom(),
          oban_max_attempts: pos_integer(),
          telemetry_prefix: [atom()],
          sync_poll_interval_ms: pos_integer(),
          cache_institutions_ttl_ms: pos_integer(),
          tenant_id: String.t() | nil,
          metadata: map()
        }

  @enforce_keys [:client_id, :secret]
  defstruct [
    :client_id,
    :secret,
    :tenant_id,
    environment: :sandbox,
    region: :us,
    pool_size: 20,
    pool_count: 4,
    request_timeout_ms: 30_000,
    connect_timeout_ms: 5_000,
    retry_max_attempts: 3,
    retry_base_delay_ms: 500,
    retry_max_delay_ms: 30_000,
    circuit_breaker_threshold: 5,
    circuit_breaker_reset_ms: 30_000,
    webhook_secret: nil,
    oban_queue: :plaid_webhooks,
    oban_max_attempts: 10,
    telemetry_prefix: [:plaid_ex],
    sync_poll_interval_ms: 30_000,
    cache_institutions_ttl_ms: 86_400_000,
    metadata: %{}
  ]

  @doc """
  Builds a validated `PlaidEx.Config` from a keyword list.

  Raises `ArgumentError` on validation failure.

  ## Example

      config = PlaidEx.Config.new!(
        client_id: "your-client-id",
        secret: "your-secret",
        environment: :production,
        region: :us,
        pool_size: 50
      )
  """
  @spec new!(keyword()) :: t()
  def new!(opts) when is_list(opts) do
    case NimbleOptions.validate(opts, @schema) do
      {:ok, validated} ->
        struct!(__MODULE__, validated)

      {:error, %NimbleOptions.ValidationError{} = e} ->
        raise ArgumentError, """
        PlaidEx.Config validation failed:

          #{Exception.message(e)}

        See `PlaidEx.Config` documentation for all valid options.
        """
    end
  end

  @doc """
  Loads config from the application environment.

  Reads from `Application.get_all_env(:plaid_ex)` and validates.
  Raises on missing required keys or invalid values.

  Call this once at application start, not on every request.
  """
  @spec load!() :: t()
  def load! do
    env = Application.get_all_env(:plaid_ex)

    env
    |> Keyword.put_new(:environment, :sandbox)
    |> new!()
  end

  @doc """
  Returns the Plaid API base URL for the given config.

  ## Examples

      iex> PlaidEx.Config.base_url(%PlaidEx.Config{environment: :sandbox, region: :us})
      "https://sandbox.plaid.com"

      iex> PlaidEx.Config.base_url(%PlaidEx.Config{environment: :production, region: :eu})
      "https://production.eu.plaid.com"
  """
  @spec base_url(t()) :: String.t()
  def base_url(%__MODULE__{environment: :production, region: :us}),
    do: "https://production.plaid.com"

  def base_url(%__MODULE__{environment: :production, region: region})
      when region in [:eu, :uk],
      do: "https://production.eu.plaid.com"

  def base_url(%__MODULE__{environment: :development}),
    do: "https://development.plaid.com"

  def base_url(%__MODULE__{environment: :sandbox}),
    do: "https://sandbox.plaid.com"

  @doc """
  Returns the Plaid API version header value.
  """
  @spec api_version() :: String.t()
  def api_version, do: @plaid_api_version

  @doc """
  Returns a new config with the secret replaced.
  Useful for secret rotation without recreating the full config.
  """
  @spec rotate_secret(t(), String.t()) :: t()
  def rotate_secret(%__MODULE__{} = config, new_secret) when is_binary(new_secret) do
    %{config | secret: new_secret}
  end

  @doc """
  Returns `true` if this config targets a live (non-sandbox) environment.
  Use this to gate production-only safety checks.
  """
  @spec production?(t()) :: boolean()
  def production?(%__MODULE__{environment: :production}), do: true
  def production?(%__MODULE__{}), do: false

  @doc """
  Returns a scrubbed version of the config safe for logging.
  Replaces the secret with a redacted placeholder.
  """
  @spec scrub(t()) :: map()
  def scrub(%__MODULE__{} = config) do
    config
    |> Map.from_struct()
    |> Map.put(:secret, "[REDACTED]")
    |> Map.put(:webhook_secret, if(config.webhook_secret, do: "[REDACTED]", else: nil))
  end
end
