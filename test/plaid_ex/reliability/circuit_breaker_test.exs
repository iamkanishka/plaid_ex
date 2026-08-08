defmodule PlaidEx.Reliability.CircuitBreakerTest do
  use ExUnit.Case, async: false

  alias PlaidEx.Config
  alias PlaidEx.Error
  alias PlaidEx.Reliability.CircuitBreaker
  alias PlaidEx.Reliability.CircuitBreakerSupervisor

  @env :test_cb_env

  setup do
    config =
      Config.new!(
        client_id: "c",
        secret: "s",
        circuit_breaker_threshold: 3,
        circuit_breaker_reset_ms: 100
      )

    # Start a fresh circuit breaker for each test
    # Unique, never-before-seen atom per test run — `to_existing_atom`
    # isn't applicable since there's no pre-existing atom to reuse.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    env = :"test_env_#{:rand.uniform(100_000)}"

    case CircuitBreakerSupervisor.ensure_started(env, config) do
      {:ok, _} -> :ok
      _ -> :ok
    end

    {:ok, env: env, config: config}
  end

  describe "check/2" do
    test "allows requests when closed", %{env: env, config: config} do
      assert :ok = CircuitBreaker.check(env, config)
    end

    test "rejects requests when open", %{env: env, config: config} do
      # Trip the circuit
      error = %Error{type: :api_error, code: "INTERNAL_SERVER_ERROR", message: "err", status: 500}
      for _ <- 1..3, do: CircuitBreaker.record_failure(env, error)

      assert {:error, :circuit_open} = CircuitBreaker.check(env, config)
    end

    test "transitions to half-open after reset timeout", %{env: env, config: config} do
      error = %Error{type: :api_error, code: "INTERNAL_SERVER_ERROR", message: "err", status: 500}
      for _ <- 1..3, do: CircuitBreaker.record_failure(env, error)

      # Wait for reset_ms (100ms in test config)
      Process.sleep(150)

      # Should now allow through (half-open)
      assert :ok = CircuitBreaker.check(env, config)
    end
  end

  describe "record_success/1" do
    test "resets failure count in closed state", %{env: env, config: config} do
      error = %Error{type: :api_error, code: "INTERNAL_SERVER_ERROR", message: "err", status: 500}

      # 2 failures (below threshold of 3)
      CircuitBreaker.record_failure(env, error)
      CircuitBreaker.record_failure(env, error)

      # Success resets the count
      CircuitBreaker.record_success(env)

      # Should still be closed and allow requests
      assert :ok = CircuitBreaker.check(env, config)
    end

    test "transitions half-open to closed after enough successes", %{env: env, config: config} do
      error = %Error{type: :api_error, code: "INTERNAL_SERVER_ERROR", message: "err", status: 500}

      # Trip the circuit
      for _ <- 1..3, do: CircuitBreaker.record_failure(env, error)
      # Wait for reset
      Process.sleep(150)

      # Probe succeeds
      CircuitBreaker.record_success(env)
      CircuitBreaker.record_success(env)

      # Should be closed now
      assert CircuitBreaker.status(env) == :closed
    end
  end

  describe "record_failure/2" do
    test "opens circuit after threshold failures", %{env: env, config: config} do
      error = %Error{type: :api_error, code: "INTERNAL_SERVER_ERROR", message: "err", status: 500}

      # Threshold is 3
      CircuitBreaker.record_failure(env, error)
      CircuitBreaker.record_failure(env, error)
      assert CircuitBreaker.status(env) == :closed

      CircuitBreaker.record_failure(env, error)
      assert CircuitBreaker.status(env) == :open
    end

    test "does not open circuit for user errors (ITEM_LOGIN_REQUIRED)", %{
      env: env,
      config: config
    } do
      # User errors should not trip the circuit breaker
      error = %Error{
        type: :item_error,
        code: "ITEM_LOGIN_REQUIRED",
        message: "login required",
        status: 400
      }

      for _ <- 1..10, do: CircuitBreaker.record_failure(env, error)

      # Circuit should remain closed — user errors are not systemic
      assert CircuitBreaker.status(env) == :closed
    end

    test "opens on half-open probe failure", %{env: env, config: config} do
      error = %Error{type: :api_error, code: "INTERNAL_SERVER_ERROR", message: "err", status: 500}

      # Trip the circuit
      for _ <- 1..3, do: CircuitBreaker.record_failure(env, error)
      # Wait for reset to half-open
      Process.sleep(150)

      # Probe check (allows request through)
      CircuitBreaker.check(env, config)

      # Probe fails — back to open
      CircuitBreaker.record_failure(env, error)
      assert CircuitBreaker.status(env) == :open
    end
  end

  describe "reset/1" do
    test "manually resets circuit to closed", %{env: env, config: config} do
      error = %Error{type: :api_error, code: "INTERNAL_SERVER_ERROR", message: "err", status: 500}
      for _ <- 1..3, do: CircuitBreaker.record_failure(env, error)

      assert CircuitBreaker.status(env) == :open
      CircuitBreaker.reset(env)
      assert CircuitBreaker.status(env) == :closed
      assert :ok = CircuitBreaker.check(env, config)
    end
  end

  describe "telemetry events" do
    test "emits circuit_breaker.open telemetry", %{env: env, config: config} do
      self_pid = self()

      :telemetry.attach(
        "test_cb_open_handler",
        [:plaid_ex, :circuit_breaker, :open],
        fn _, measurements, meta, _ ->
          send(self_pid, {:cb_opened, measurements, meta})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("test_cb_open_handler") end)

      error = %Error{type: :api_error, code: "INTERNAL_SERVER_ERROR", message: "err", status: 500}
      for _ <- 1..3, do: CircuitBreaker.record_failure(env, error)

      assert_receive {:cb_opened, %{failure_count: 3}, %{environment: ^env}}, 500
    end
  end
end
