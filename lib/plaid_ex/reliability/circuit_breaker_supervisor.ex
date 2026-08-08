defmodule PlaidEx.Reliability.CircuitBreakerSupervisor do
  @moduledoc """
  DynamicSupervisor managing per-environment circuit breakers.

  Starts a `CircuitBreaker` process for each Plaid environment
  on demand. Circuit breakers are never restarted automatically
  (`:temporary`) because their state would reset on restart anyway.
  """

  use PlaidEx.Support.DynamicSupervisorBase

  require Logger

  alias PlaidEx.Reliability.CircuitBreaker

  @doc """
  Ensures a circuit breaker exists for the given environment.
  Safe to call multiple times — idempotent.
  """
  @spec ensure_started(atom(), PlaidEx.Config.t()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(environment, config) do
    case DynamicSupervisor.start_child(__MODULE__, {CircuitBreaker, {environment, config}}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  @spec check(atom(), PlaidEx.Config.t()) :: :ok | {:error, :circuit_open}
  def check(environment, config) do
    case ensure_started(environment, config) do
      {:ok, _} ->
        CircuitBreaker.check(environment, config)

      {:error, reason} ->
        Logger.warning(
          "[PlaidEx.CircuitBreakerSupervisor] Failed to start breaker for " <>
            "env=#{environment}: #{inspect(reason)} — failing open"
        )

        :ok
    end
  end

  @spec record_success(atom()) :: :ok
  def record_success(environment) do
    CircuitBreaker.record_success(environment)
  end

  @spec record_failure(atom(), PlaidEx.Error.t(), PlaidEx.Config.t()) :: :ok
  def record_failure(environment, error, config) do
    case ensure_started(environment, config) do
      {:ok, _} ->
        CircuitBreaker.record_failure(environment, error)

      {:error, reason} ->
        Logger.warning(
          "[PlaidEx.CircuitBreakerSupervisor] Failed to start breaker for " <>
            "env=#{environment}: #{inspect(reason)} — skipping failure record"
        )

        :ok
    end
  end
end
