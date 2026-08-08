# This is the sole HTTP transport module and cohesively owns retry,
# circuit-breaking, rate-limiting, and telemetry concerns for every outbound request.
# credo:disable-for-this-file Credo.Check.Refactor.ModuleDependencies
defmodule PlaidEx.HTTP.Client do
  @moduledoc """
  Core HTTP client for all Plaid API requests.

  Provides authentication injection, idempotency keys, exponential
  backoff with full jitter, circuit breaker integration, rate limiting,
  and structured telemetry events.

  OpenTelemetry tracing is handled separately by
  `PlaidEx.Telemetry.OpenTelemetry` — kept out of this module to
  prevent macro-expansion issues with Dialyzer.

  ## Telemetry events

  - `[:plaid_ex, :http, :start]`  — request initiated
  - `[:plaid_ex, :http, :stop]`   — successful response
  - `[:plaid_ex, :http, :error]`  — failed (after all retries)
  - `[:plaid_ex, :http, :retry]`  — retry scheduled
  """

  require Logger

  alias PlaidEx.Config

  alias PlaidEx.Error
  alias PlaidEx.HTTP.RateLimiter
  alias PlaidEx.Reliability.CircuitBreakerSupervisor
  alias PlaidEx.Reliability.Retry

  # Dialyzer: Req.post/1 dispatches through Finch/Mint via macro-generated
  # code that Dialyzer can't fully trace, so it can't establish that
  # {:ok, %Req.Response{}} is a reachable success return here. That
  # uncertainty otherwise cascades into "no local return" on `execute/1`
  # and its only caller, `post/4`. Scoped to these two functions — the
  # actual call site — rather than suppressed project-wide.
  @dialyzer {:nowarn_function, [post: 4, execute: 1]}

  @plaid_api_version "2020-09-14"

  @type request_opts :: [
          tenant_id: String.t() | nil,
          idempotency_key: String.t() | nil,
          timeout_ms: pos_integer() | nil,
          response: :json | :binary
        ]

  defmodule RequestContext do
    @moduledoc false
    @enforce_keys [:path, :body, :config, :idempotency_key, :timeout_ms, :attempt]
    defstruct [
      :path,
      :body,
      :config,
      :tenant_id,
      :idempotency_key,
      :timeout_ms,
      :attempt,
      response: :json
    ]

    @type t :: %__MODULE__{
            path: String.t(),
            body: map(),
            config: PlaidEx.Config.t(),
            tenant_id: String.t() | nil,
            idempotency_key: String.t(),
            timeout_ms: pos_integer(),
            attempt: pos_integer(),
            response: :json | :binary
          }
  end

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Executes a POST request to the Plaid API.

  Returns `{:ok, response_body}` on HTTP 2xx, or `{:error, PlaidEx.Error.t()}`
  on any failure including after all retries are exhausted.

  Pass `response: :binary` in `opts` for endpoints that return a raw
  file body (e.g. Asset Report and statement PDFs) instead of JSON —
  the raw bytes are returned as-is on success. Error responses are
  still parsed as JSON regardless of this option, since Plaid returns
  JSON error bodies even for otherwise-binary endpoints.
  """
  @spec post(String.t(), map(), Config.t()) ::
          {:ok, map()} | {:error, Error.t()}
  @spec post(String.t(), map(), Config.t(), request_opts()) ::
          {:ok, map() | binary()} | {:error, Error.t()}
  def post(path, body, %Config{} = config, opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, config.tenant_id)
    idempotency_key = Keyword.get(opts, :idempotency_key) || generate_idempotency_key()
    timeout_ms = Keyword.get(opts, :timeout_ms, config.request_timeout_ms)
    response = Keyword.get(opts, :response, :json)

    case RateLimiter.check(tenant_id || :global, config) do
      {:error, :rate_limited} ->
        error = %Error{
          type: :rate_limit_exceeded,
          code: "CLIENT_RATE_LIMITED",
          message: "Request rate limited by PlaidEx client — try again shortly",
          status: 429,
          retryable: true
        }

        emit_telemetry(:error, config, %{
          path: path,
          tenant_id: tenant_id,
          error_code: error.code,
          attempt: 1
        })

        {:error, error}

      :ok ->
        case CircuitBreakerSupervisor.check(config.environment, config) do
          {:error, :circuit_open} ->
            error = %Error{
              type: :api_error,
              code: "CIRCUIT_OPEN",
              message:
                "Circuit breaker open for environment=#{config.environment}. " <>
                  "Too many recent failures — requests temporarily paused.",
              status: 503,
              retryable: false
            }

            emit_telemetry(:error, config, %{
              path: path,
              tenant_id: tenant_id,
              error_code: error.code,
              attempt: 1
            })

            {:error, error}

          :ok ->
            ctx = %RequestContext{
              path: path,
              body: body,
              config: config,
              tenant_id: tenant_id,
              idempotency_key: idempotency_key,
              timeout_ms: timeout_ms,
              attempt: 1,
              response: response
            }

            execute(ctx)
        end
    end
  end

  # ── Internal execution with retry ───────────────────────────────────────────

  @spec execute(RequestContext.t()) :: {:ok, map() | binary()} | {:error, Error.t()}
  defp execute(%RequestContext{} = ctx) do
    config = ctx.config
    url = Config.base_url(config) <> ctx.path
    start_mono = System.monotonic_time()

    emit_telemetry(:start, config, %{
      path: ctx.path,
      tenant_id: ctx.tenant_id,
      attempt: ctx.attempt,
      url: url
    })

    request_body =
      Map.merge(ctx.body, %{
        "client_id" => config.client_id,
        "secret" => config.secret
      })

    req =
      Req.new(
        url: url,
        json: request_body,
        headers: build_headers(ctx.idempotency_key, ctx.tenant_id, ctx.attempt),
        receive_timeout: ctx.timeout_ms,
        connect_options: [timeout: config.connect_timeout_ms],
        finch: PlaidEx.Finch,
        retry: false,
        decode_body: false
      )

    case Req.post(req) do
      {:ok, %Req.Response{status: status, body: raw_body}} ->
        duration_ms = native_to_ms(System.monotonic_time() - start_mono)
        handle_response(status, raw_body, ctx, duration_ms)

      {:error, exception} ->
        duration_ms = native_to_ms(System.monotonic_time() - start_mono)
        error = Error.from_exception(exception)
        handle_failure(error, ctx, duration_ms)
    end
  end

  @spec handle_response(integer(), binary(), RequestContext.t(), integer()) ::
          {:ok, map() | binary()} | {:error, Error.t()}
  defp handle_response(status, raw_body, %RequestContext{} = ctx, duration_ms) do
    case decode_body(status, raw_body, ctx.response) do
      {:ok, decoded} ->
        emit_telemetry(:stop, ctx.config, %{
          path: ctx.path,
          tenant_id: ctx.tenant_id,
          status: status,
          duration_ms: duration_ms,
          attempt: ctx.attempt
        })

        CircuitBreakerSupervisor.record_success(ctx.config.environment)
        {:ok, decoded}

      {:error, %Error{} = error} ->
        handle_failure(error, ctx, duration_ms)
    end
  end

  @spec handle_failure(Error.t(), RequestContext.t(), integer()) ::
          {:ok, map() | binary()} | {:error, Error.t()}
  defp handle_failure(error, %RequestContext{} = ctx, duration_ms) do
    config = ctx.config
    CircuitBreakerSupervisor.record_failure(config.environment, error, config)

    if Error.retryable?(error) and ctx.attempt < config.retry_max_attempts do
      delay_ms =
        Retry.backoff_delay(ctx.attempt, config.retry_base_delay_ms, config.retry_max_delay_ms)

      Logger.debug(
        "[PlaidEx] Retry path=#{ctx.path} attempt=#{ctx.attempt + 1} delay_ms=#{delay_ms} error=#{error.code}"
      )

      emit_telemetry(:retry, config, %{
        path: ctx.path,
        tenant_id: ctx.tenant_id,
        attempt: ctx.attempt,
        delay_ms: delay_ms,
        error_code: error.code
      })

      Process.sleep(delay_ms)
      execute(%{ctx | attempt: ctx.attempt + 1})
    else
      emit_telemetry(:error, config, %{
        path: ctx.path,
        tenant_id: ctx.tenant_id,
        status: error.status,
        duration_ms: duration_ms,
        attempt: ctx.attempt,
        error_code: error.code,
        error_type: error.type
      })

      {:error, error}
    end
  end

  # ── Response decoding ────────────────────────────────────────────────────────

  @spec decode_body(integer(), binary(), :json | :binary) ::
          {:ok, map() | binary()} | {:error, Error.t()}
  defp decode_body(status, raw_body, :binary) when status in 200..299 do
    {:ok, raw_body}
  end

  defp decode_body(status, raw_body, _) when status in 200..299 do
    case Jason.decode(raw_body) do
      {:ok, decoded} ->
        {:ok, decoded}

      {:error, _} ->
        {:error,
         %Error{
           type: :api_error,
           code: "INVALID_JSON",
           message: "Plaid returned invalid JSON",
           status: status
         }}
    end
  end

  defp decode_body(status, raw_body, _) do
    case Jason.decode(raw_body) do
      {:ok, body} ->
        {:error, Error.from_plaid_response(status, body)}

      {:error, _} ->
        {:error,
         %Error{
           type: :api_error,
           code: "UNEXPECTED_RESPONSE",
           message: "Non-JSON error from Plaid",
           status: status
         }}
    end
  end

  # ── Headers ──────────────────────────────────────────────────────────────────

  @spec build_headers(String.t(), String.t() | nil, pos_integer()) :: [{String.t(), String.t()}]
  defp build_headers(idempotency_key, tenant_id, attempt) do
    vsn = to_string(Application.spec(:plaid_ex, :vsn) || "dev")

    base_headers = [
      {"plaid-version", @plaid_api_version},
      {"content-type", "application/json"},
      {"accept", "application/json"},
      {"user-agent", "plaid-ex/#{vsn} Elixir/OTP"},
      {"x-plaid-attempt", to_string(attempt)},
      {"idempotency-key", idempotency_key}
    ]

    maybe_add_header(base_headers, "x-plaid-tenant-id", tenant_id)
  end

  defp maybe_add_header(headers, _, nil), do: headers
  defp maybe_add_header(headers, _, ""), do: headers
  defp maybe_add_header(headers, name, value), do: [{name, value} | headers]

  # ── Backoff ──────────────────────────────────────────────────────────────────
  #
  # Delegates to PlaidEx.Reliability.Retry.backoff_delay/3 — this used to
  # be its own private, byte-for-byte identical implementation.

  # ── Telemetry ────────────────────────────────────────────────────────────────

  defp emit_telemetry(event, config, meta) do
    :telemetry.execute(
      config.telemetry_prefix ++ [:http, event],
      %{system_time: System.system_time()},
      meta
    )
  end

  # ── Utilities ────────────────────────────────────────────────────────────────

  @spec generate_idempotency_key() :: String.t()
  defp generate_idempotency_key do
    random_bytes = :crypto.strong_rand_bytes(16)
    Base.encode16(random_bytes, case: :lower)
  end

  @spec native_to_ms(integer()) :: integer()
  defp native_to_ms(native) do
    System.convert_time_unit(native, :native, :millisecond)
  end
end
