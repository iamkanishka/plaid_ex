defmodule PlaidEx.Reliability.RetryTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PlaidEx.Error
  alias PlaidEx.Reliability.Retry

  describe "classify/1" do
    test "classifies rate limit as long backoff" do
      error = %Error{
        type: :rate_limit_exceeded,
        code: "RATE_LIMIT_EXCEEDED",
        message: "rate limited",
        status: 429
      }

      assert Retry.classify(error) == :with_long_backoff
    end

    test "classifies institution down as backoff" do
      error = %Error{
        type: :institution_error,
        code: "INSTITUTION_DOWN",
        message: "down",
        status: 503
      }

      assert Retry.classify(error) == :with_backoff
    end

    test "classifies ITEM_LOGIN_REQUIRED as reauthenticate" do
      error =
        Error.from_plaid_response(400, %{
          "error_type" => "ITEM_ERROR",
          "error_code" => "ITEM_LOGIN_REQUIRED",
          "error_message" => "login required"
        })

      assert Retry.classify(error) == :reauthenticate
    end

    test "classifies INVALID_INPUT as no_retry" do
      error = %Error{
        type: :invalid_input,
        code: "INVALID_ACCESS_TOKEN",
        message: "invalid",
        status: 400,
        retryable: false
      }

      assert Retry.classify(error) == :no_retry
    end

    test "classifies generic retryable errors as with_backoff" do
      error = %Error{
        type: :api_error,
        code: "INTERNAL_SERVER_ERROR",
        message: "error",
        status: 500,
        retryable: true
      }

      assert Retry.classify(error) == :with_backoff
    end
  end

  describe "backoff_delay/3" do
    test "delay is 0 or positive" do
      for attempt <- 1..10 do
        delay = Retry.backoff_delay(attempt, 500, 30_000)
        assert delay >= 0
      end
    end

    test "delay never exceeds cap" do
      for attempt <- 1..20 do
        delay = Retry.backoff_delay(attempt, 500, 30_000)
        assert delay <= 30_000, "delay #{delay} exceeded cap at attempt #{attempt}"
      end
    end

    test "delay uses full jitter (varies between calls)" do
      # Generate 20 delays at attempt 3 — they should not all be the same
      delays =
        for _ <- 1..20 do
          Retry.backoff_delay(3, 500, 30_000)
        end

      # With full jitter, we expect variance
      unique_delays = Enum.uniq(delays)

      assert length(unique_delays) > 1,
             "Full jitter should produce varied delays, got: #{inspect(delays)}"
    end

    property "delay is always between 0 and cap" do
      check all(
              attempt <- integer(1..20),
              base_ms <- integer(100..5_000),
              max_ms <- integer(1_000..60_000)
            ) do
        delay = Retry.backoff_delay(attempt, base_ms, max_ms)
        assert delay >= 0
        assert delay <= max_ms
      end
    end
  end

  describe "should_retry?/2" do
    test "returns true when attempt is within max" do
      assert Retry.should_retry?(1, 3) == true
      assert Retry.should_retry?(2, 3) == true
      assert Retry.should_retry?(3, 3) == true
    end

    test "returns false when attempt exceeds max" do
      assert Retry.should_retry?(4, 3) == false
      assert Retry.should_retry?(10, 3) == false
    end

    test "returns false when max is 0" do
      assert Retry.should_retry?(1, 0) == false
    end
  end

  describe "describe/1" do
    test "returns non-empty description for all strategies" do
      strategies = [:no_retry, :immediate, :with_backoff, :with_long_backoff, :reauthenticate]

      Enum.each(strategies, fn s ->
        desc = Retry.describe(s)
        assert is_binary(desc)
        assert byte_size(desc) > 0
      end)
    end
  end
end

defmodule PlaidEx.Reliability.BulkheadTest do
  use ExUnit.Case, async: false

  alias PlaidEx.Reliability.Bulkhead

  # Start bulkheads for testing
  setup do
    # Use a unique pool name per test to avoid conflicts
    # Unique, never-before-seen atom per test run — `to_existing_atom`
    # isn't applicable since there's no pre-existing atom to reuse.
    # credo:disable-for-next-line Credo.Check.Warning.UnsafeToAtom
    name = :"test_pool_#{:rand.uniform(100_000)}"

    {:ok, _} =
      DynamicSupervisor.start_child(
        PlaidEx.Reliability.CircuitBreakerSupervisor,
        %{
          id: {Bulkhead, name},
          start: {Bulkhead, :start_link, [{name, 3}]}
        }
      )

    {:ok, pool: name}
  end

  describe "run/3" do
    test "executes the function and returns result", %{pool: pool} do
      result = Bulkhead.run(pool, fn -> {:ok, "computed"} end)
      assert result == {:ok, {:ok, "computed"}}
    end

    test "rejects when pool is full", %{pool: pool} do
      # Fill the pool (max 3)
      pids =
        for _ <- 1..3 do
          Task.async(fn ->
            Bulkhead.run(pool, fn -> Process.sleep(500) end)
          end)
        end

      # Brief wait for tasks to acquire slots
      Process.sleep(50)

      # Should be rejected
      result = Bulkhead.run(pool, fn -> :ok end, timeout: 100)
      assert result == {:error, :bulkhead_full}

      # Clean up
      Task.shutdown_many(pids, :brutal_kill)
    end

    test "releases slot after function completes", %{pool: pool} do
      # Fill and drain
      Bulkhead.run(pool, fn -> :ok end)

      status = Bulkhead.status(pool)
      assert status.current == 0
      assert status.available == status.max
    end

    test "releases slot even when function raises", %{pool: pool} do
      catch_exit(Bulkhead.run(pool, fn -> raise "oops" end))
      # Pool should be released
      status = Bulkhead.status(pool)
      assert status.current == 0
    end
  end

  describe "status/1" do
    test "returns pool stats", %{pool: pool} do
      status = Bulkhead.status(pool)
      assert is_map(status)
      assert status.max == 3
      assert status.current == 0
      assert status.available == 3
    end
  end
end
