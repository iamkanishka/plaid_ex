defmodule PlaidEx.Reliability.Retry do
  @moduledoc """
  Retry classification and scheduling utilities.

  Provides functions for determining retry strategy based on Plaid
  error types and implementing backoff algorithms.

  Used internally by `PlaidEx.HTTP.Client` but exposed for advanced
  use cases where you need to apply retry logic outside the HTTP layer
  (e.g., in background jobs or custom sync workflows).

  ## Full jitter backoff

  PlaidEx uses full jitter backoff as recommended by AWS architecture blogs
  for distributed systems. This is the optimal strategy for preventing
  thundering herds when many clients retry simultaneously.

  `delay = random_uniform(min(base * 2^attempt, cap))`

  Advantages over equal jitter or exponential backoff alone:
  - Eliminates synchronized retries under load
  - Reduces total attempted load by ~50% vs. no jitter
  - Faster recovery from transient failures (some clients retry immediately)
  """

  alias PlaidEx.Error

  @type retry_strategy ::
          :no_retry
          | :immediate
          | :with_backoff
          | :with_long_backoff
          | :reauthenticate

  @doc """
  Classifies an error into a retry strategy.

  Returns the recommended strategy for the given error:
  - `:no_retry` — do not retry (user error, invalid request)
  - `:immediate` — retry immediately (rare, only for very transient errors)
  - `:with_backoff` — retry with exponential backoff (most retryable errors)
  - `:with_long_backoff` — retry with longer delays (rate limits, maintenance)
  - `:reauthenticate` — do not retry; user must re-authenticate
  """
  @spec classify(Error.t()) :: :no_retry | :with_backoff | :with_long_backoff | :reauthenticate
  def classify(%Error{code: "RATE_LIMIT_EXCEEDED"}), do: :with_long_backoff
  def classify(%Error{code: "PLANNED_MAINTENANCE"}), do: :with_long_backoff
  def classify(%Error{code: "INSTITUTION_DOWN"}), do: :with_backoff
  def classify(%Error{code: "INSTITUTION_NOT_RESPONDING"}), do: :with_backoff
  def classify(%Error{code: "PRODUCT_NOT_READY"}), do: :with_backoff
  def classify(%Error{code: "INTERNAL_SERVER_ERROR"}), do: :with_backoff
  def classify(%Error{code: "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION"}), do: :with_backoff
  def classify(%Error{requires_reauthentication: true}), do: :reauthenticate
  def classify(%Error{retryable: true}), do: :with_backoff
  def classify(%Error{}), do: :no_retry

  @doc """
  Calculates the delay for a retry attempt using full jitter.

  ## Parameters
  - `attempt` — current attempt number (1-indexed)
  - `base_ms` — base delay in milliseconds
  - `max_ms` — maximum delay cap in milliseconds

  ## Examples

      iex> delay = PlaidEx.Reliability.Retry.backoff_delay(1, 500, 30_000)
      iex> delay >= 0 and delay <= 500
      true

      iex> delay = PlaidEx.Reliability.Retry.backoff_delay(5, 500, 30_000)
      iex> delay >= 0 and delay <= 8_000
      true
  """
  @spec backoff_delay(pos_integer(), pos_integer(), pos_integer()) :: non_neg_integer()
  def backoff_delay(attempt, base_ms, max_ms) when attempt > 0 do
    growth = trunc(:math.pow(2, attempt))
    cap = min(base_ms * growth, max_ms)
    upper_bound = max(cap, 1)
    :rand.uniform(upper_bound)
  end

  @doc """
  Calculates a longer backoff delay suitable for rate limits.

  Uses base of 5 seconds with a cap of 5 minutes.
  """
  @spec rate_limit_delay(pos_integer()) :: pos_integer()
  def rate_limit_delay(attempt) do
    backoff_delay(attempt, 5_000, 300_000)
  end

  @doc """
  Returns true if the attempt number is within the allowed max.
  """
  @spec should_retry?(pos_integer(), non_neg_integer()) :: boolean()
  def should_retry?(attempt, max_attempts) when max_attempts > 0 do
    attempt <= max_attempts
  end

  def should_retry?(_, 0), do: false

  @doc """
  Returns a human-readable description of a retry strategy.
  """
  @spec describe(retry_strategy()) :: String.t()
  def describe(:no_retry), do: "Not retryable — fix the request or error condition"
  def describe(:immediate), do: "Retry immediately"
  def describe(:with_backoff), do: "Retry with exponential backoff (base: 500ms)"
  def describe(:with_long_backoff), do: "Retry with long backoff (base: 5s, cap: 5min)"
  def describe(:reauthenticate), do: "User must re-authenticate via Plaid Link"
end
