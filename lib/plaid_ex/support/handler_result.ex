defmodule PlaidEx.Support.HandlerResult do
  @moduledoc """
  Normalizes the return value of a user-supplied handler callback
  (webhook handlers, sync page handlers) into a consistent
  `:ok | {:error, term()}` shape.

  Both `PlaidEx.Sync.TransactionSync` and `PlaidEx.Webhooks.Dispatcher`
  invoke user callbacks and need to interpret the result the same way —
  this was previously duplicated identically in both.
  """

  @spec normalize(term()) :: :ok | {:error, term()}
  def normalize(:ok), do: :ok
  def normalize({:error, _} = err), do: err
  def normalize(other), do: {:error, {:unexpected_return, other}}
end
