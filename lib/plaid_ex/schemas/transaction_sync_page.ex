defmodule PlaidEx.Schemas.TransactionSyncPage do
  @moduledoc """
  A single page from the `/transactions/sync` endpoint.

  The `next_cursor` field MUST be persisted after each successful page.
  `has_more` indicates whether additional pages are available.
  """

  alias PlaidEx.Schemas.Transaction

  @type removed_transaction :: %{transaction_id: String.t()}

  @type t :: %__MODULE__{
          added: [Transaction.t()],
          modified: [Transaction.t()],
          removed: [removed_transaction()],
          has_more: boolean(),
          next_cursor: String.t(),
          request_id: String.t() | nil
        }

  defstruct [
    :next_cursor,
    :request_id,
    added: [],
    modified: [],
    removed: [],
    has_more: false
  ]

  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      added: Enum.map(map["added"] || [], &Transaction.from_map/1),
      modified: Enum.map(map["modified"] || [], &Transaction.from_map/1),
      removed: Enum.map(map["removed"] || [], fn r -> %{transaction_id: r["transaction_id"]} end),
      has_more: map["has_more"] == true,
      next_cursor: map["next_cursor"],
      request_id: map["request_id"]
    }
  end
end
