defmodule PlaidEx.Schemas.Transfer do
  @moduledoc "A Plaid Transfer object."

  @type t :: %__MODULE__{
          id: String.t(),
          ach_class: String.t() | nil,
          account_id: String.t(),
          funding_account_id: String.t() | nil,
          type: String.t(),
          user: map(),
          amount: String.t(),
          iso_currency_code: String.t(),
          description: String.t(),
          created: String.t(),
          status: String.t(),
          network: String.t(),
          cancellable: boolean(),
          failure_reason: map() | nil,
          metadata: map(),
          origination_account_id: String.t() | nil,
          guarantee_decision: String.t() | nil,
          guarantee_decision_rationale: map() | nil,
          authorization_id: String.t() | nil
        }

  defstruct [
    :id,
    :ach_class,
    :account_id,
    :funding_account_id,
    :type,
    :user,
    :amount,
    :iso_currency_code,
    :description,
    :created,
    :status,
    :network,
    :failure_reason,
    :origination_account_id,
    :guarantee_decision,
    :guarantee_decision_rationale,
    :authorization_id,
    cancellable: false,
    metadata: %{}
  ]

  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      id: map["id"],
      ach_class: map["ach_class"],
      account_id: map["account_id"],
      funding_account_id: map["funding_account_id"],
      type: map["type"],
      user: map["user"] || %{},
      amount: map["amount"],
      iso_currency_code: map["iso_currency_code"],
      description: map["description"],
      created: map["created"],
      status: map["status"],
      network: map["network"],
      cancellable: map["cancellable"] == true,
      failure_reason: map["failure_reason"],
      metadata: map["metadata"] || %{},
      origination_account_id: map["origination_account_id"],
      guarantee_decision: map["guarantee_decision"],
      guarantee_decision_rationale: map["guarantee_decision_rationale"],
      authorization_id: map["authorization_id"]
    }
  end
end
