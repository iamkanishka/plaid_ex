defmodule PlaidEx.Reliability.CircuitBreaker do
  @moduledoc """
  Per-environment GenServer circuit breaker.

  Implements the classic three-state circuit breaker pattern:

  - **Closed** — normal operation, all requests pass through
  - **Open** — fast-fail mode; all requests rejected without hitting Plaid
  - **Half-open** — recovery probe; one request allowed to test the service

  ## State transitions

      Closed ──[N failures]--> Open ──[reset_ms elapsed]--> Half-open
                                                                │
                  Closed <──[success]──────────────────────────┤
                  Open   <──[failure]──────────────────────────┘

  ## Per-environment isolation

  Each Plaid environment (sandbox / development / production) gets its
  own circuit breaker, supervised under `CircuitBreakerSupervisor`.
  An institution outage in sandbox never affects production.

  ## Plaid-specific triggers

  The circuit opens on `INSTITUTION_DOWN`, `INSTITUTION_NOT_RESPONDING`,
  `PLANNED_MAINTENANCE`, and consecutive 5xx errors. It does NOT open
  on `RATE_LIMIT_EXCEEDED` (those are handled by backoff in the client)
  or on `ITEM_LOGIN_REQUIRED` (user action errors).
  """

  use GenServer, restart: :permanent
  require Logger

  alias PlaidEx.Error

  @type state_name :: :closed | :open | :half_open

  defmodule State do
    @moduledoc false
    @type t :: %__MODULE__{
            environment: atom(),
            status: PlaidEx.Reliability.CircuitBreaker.state_name(),
            failure_count: non_neg_integer(),
            success_count: non_neg_integer(),
            last_failure_at: integer() | nil,
            opened_at: integer() | nil,
            threshold: pos_integer(),
            reset_ms: pos_integer(),
            half_open_successes_required: pos_integer()
          }

    defstruct [
      :environment,
      :opened_at,
      :last_failure_at,
      status: :closed,
      failure_count: 0,
      success_count: 0,
      threshold: 5,
      reset_ms: 30_000,
      half_open_successes_required: 2
    ]
  end

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Checks whether a request is allowed.

  Returns `:ok` if the circuit is closed or half-open,
  `{:error, :circuit_open}` if the circuit is open.
  """
  @spec check(atom(), PlaidEx.Config.t()) :: :ok | {:error, :circuit_open}
  def check(environment, _) do
    server = via(environment)

    case GenServer.call(server, :check) do
      :allow -> :ok
      :reject -> {:error, :circuit_open}
    end
  rescue
    # If the GenServer isn't started yet, allow the request through
    _ -> :ok
  end

  @doc """
  Records a successful response. Resets failure count; transitions
  half-open → closed after enough successes.
  """
  @spec record_success(atom()) :: :ok
  def record_success(environment) do
    server = via(environment)
    GenServer.cast(server, :success)
  rescue
    _ -> :ok
  end

  @doc """
  Records a failure response. Increments failure count and may open
  the circuit if the threshold is breached.
  """
  @spec record_failure(atom(), Error.t()) :: :ok
  def record_failure(environment, %Error{} = error) do
    if circuit_triggering_error?(error) do
      server = via(environment)
      GenServer.cast(server, {:failure, error})
    else
      :ok
    end
  rescue
    _ -> :ok
  end

  @doc """
  Returns the current state of the circuit breaker.
  """
  @spec status(atom()) :: state_name()
  def status(environment) do
    server = via(environment)
    GenServer.call(server, :status)
  rescue
    _ -> :closed
  end

  @doc """
  Manually resets the circuit breaker to closed state.
  Use this if you've confirmed the service is healthy.
  """
  @spec reset(atom()) :: :ok
  def reset(environment) do
    server = via(environment)
    GenServer.cast(server, :reset)
  end

  # ── GenServer lifecycle ──────────────────────────────────────────────────────

  @spec start_link({atom(), PlaidEx.Config.t()}) :: GenServer.on_start()
  def start_link({environment, config}) do
    GenServer.start_link(__MODULE__, {environment, config}, name: via(environment))
  end

  @impl GenServer
  def init({environment, config}) do
    state = %State{
      environment: environment,
      threshold: config.circuit_breaker_threshold,
      reset_ms: config.circuit_breaker_reset_ms
    }

    {:ok, state}
  end

  # ── GenServer callbacks ──────────────────────────────────────────────────────

  @impl GenServer
  def handle_call(:check, _, %State{status: :closed} = state) do
    {:reply, :allow, state}
  end

  def handle_call(:check, _, %State{status: :open} = state) do
    now_ms = now()

    if now_ms - state.opened_at >= state.reset_ms do
      # Transition to half-open — allow one probe request
      Logger.warning("[PlaidEx.CircuitBreaker] env=#{state.environment} :open → :half_open")
      new_state = %{state | status: :half_open, success_count: 0}
      {:reply, :allow, new_state}
    else
      remaining_ms = state.reset_ms - (now_ms - state.opened_at)

      Logger.debug(
        "[PlaidEx.CircuitBreaker] env=#{state.environment} rejecting — " <>
          "circuit open for #{remaining_ms}ms more"
      )

      {:reply, :reject, state}
    end
  end

  def handle_call(:check, _, %State{status: :half_open} = state) do
    # In half-open, allow the request — success/failure will decide next state
    {:reply, :allow, state}
  end

  def handle_call(:status, _, state) do
    {:reply, state.status, state}
  end

  @impl GenServer
  def handle_cast(:success, %State{status: :half_open} = state) do
    new_successes = state.success_count + 1

    if new_successes >= state.half_open_successes_required do
      Logger.info(
        "[PlaidEx.CircuitBreaker] env=#{state.environment} :half_open → :closed (service recovered)"
      )

      emit_telemetry(:closed, state)

      {:noreply, %{state | status: :closed, failure_count: 0, success_count: 0, opened_at: nil}}
    else
      {:noreply, %{state | success_count: new_successes}}
    end
  end

  def handle_cast(:success, %State{status: :open} = state) do
    # Spurious success in open state (shouldn't happen, but handle gracefully)
    {:noreply, state}
  end

  def handle_cast(:success, state) do
    # Closed — reset failure count on success
    {:noreply, %{state | failure_count: 0}}
  end

  def handle_cast({:failure, error}, %State{status: :half_open} = state) do
    Logger.warning(
      "[PlaidEx.CircuitBreaker] env=#{state.environment} :half_open → :open " <>
        "(probe failed: #{error.code})"
    )

    new_state = %{state | status: :open, failure_count: 1, opened_at: now()}
    emit_telemetry(:opened, new_state)
    {:noreply, new_state}
  end

  def handle_cast({:failure, _}, %State{status: :open} = state) do
    # Already open — just update last failure time
    {:noreply, %{state | last_failure_at: now()}}
  end

  def handle_cast({:failure, error}, %State{status: :closed} = state) do
    new_count = state.failure_count + 1

    if new_count >= state.threshold do
      Logger.warning(
        "[PlaidEx.CircuitBreaker] env=#{state.environment} :closed → :open " <>
          "(#{new_count} consecutive failures, last: #{error.code})"
      )

      new_state = %{
        state
        | status: :open,
          failure_count: new_count,
          last_failure_at: now(),
          opened_at: now()
      }

      emit_telemetry(:opened, new_state)
      {:noreply, new_state}
    else
      {:noreply, %{state | failure_count: new_count, last_failure_at: now()}}
    end
  end

  def handle_cast(:reset, state) do
    Logger.info("[PlaidEx.CircuitBreaker] env=#{state.environment} manually reset → :closed")
    {:noreply, %{state | status: :closed, failure_count: 0, success_count: 0, opened_at: nil}}
  end

  # ── Private helpers ──────────────────────────────────────────────────────────

  # Only count errors that indicate a systemic problem.
  # User errors (ITEM_LOGIN_REQUIRED) and client errors (INVALID_INPUT)
  # should not trip the circuit breaker.
  defp circuit_triggering_error?(%Error{type: type, status: status}) do
    type in [:institution_error, :api_error] or status >= 500
  end

  defp circuit_triggering_error?(_), do: false

  defp via(environment) do
    {:via, Registry, {PlaidEx.CircuitBreakerRegistry, environment}}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp emit_telemetry(:opened, state) do
    :telemetry.execute(
      [:plaid_ex, :circuit_breaker, :open],
      %{failure_count: state.failure_count},
      %{environment: state.environment}
    )
  end

  defp emit_telemetry(:closed, state) do
    :telemetry.execute(
      [:plaid_ex, :circuit_breaker, :close],
      %{},
      %{environment: state.environment}
    )
  end
end
