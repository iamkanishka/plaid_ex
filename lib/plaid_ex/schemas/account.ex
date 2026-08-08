defmodule PlaidEx.Schemas.Account do
  @moduledoc """
  A financial account returned by Plaid.

  Covers both depository accounts (checking, savings) and credit,
  investment, loan, and other account types.
  """

  require Logger

  @type account_type :: :depository | :credit | :loan | :investment | :other

  @type account_subtype ::
          :checking
          | :savings
          | :cd
          | :money_market
          | :paypal
          | :prepaid
          | :credit_card
          | :auto
          | :commercial
          | :construction
          | :consumer
          | :home_equity
          | :line_of_credit
          | :loan
          | :mortgage
          | :overdraft
          | :student
          | :"401a"
          | :"401k"
          | :"403b"
          | :"457b"
          | :"529"
          | :brokerage
          | :cash_isa
          | :education_savings_account
          | :fixed_annuity
          | :gic
          | :health_reimbursement_arrangement
          | :hsa
          | :isa
          | :ira
          | :lif
          | :life_insurance
          | :lira
          | :lrif
          | :lrsp
          | :mutual_fund
          | :non_custodial_wallet
          | :non_taxable_brokerage_account
          | :other_annuity
          | :other_insurance
          | :pension
          | :prif
          | :profit_sharing_plan
          | :rdsp
          | :resp
          | :rlif
          | :rrif
          | :rrsp
          | :sarsep
          | :sep_ira
          | :simple_ira
          | :sipp
          | :stock_plan
          | :thrift_savings_plan
          | :tfsa
          | :ugma
          | :utma
          | :variable_annuity

  @type t :: %__MODULE__{
          account_id: String.t(),
          balances: map(),
          mask: String.t() | nil,
          name: String.t(),
          official_name: String.t() | nil,
          type: account_type(),
          subtype: account_subtype() | nil,
          verification_status: String.t() | nil,
          persistent_account_id: String.t() | nil
        }

  defstruct [
    :account_id,
    :balances,
    :mask,
    :name,
    :official_name,
    :type,
    :subtype,
    :verification_status,
    :persistent_account_id
  ]

  @spec from_map(map()) :: t()
  def from_map(map) do
    %__MODULE__{
      account_id: map["account_id"],
      balances: parse_balances(map["balances"]),
      mask: map["mask"],
      name: map["name"],
      official_name: map["official_name"],
      type: parse_type(map["type"]),
      subtype: parse_subtype(map["subtype"]),
      verification_status: map["verification_status"],
      persistent_account_id: map["persistent_account_id"]
    }
  end

  defp parse_balances(nil), do: %{}

  defp parse_balances(b) do
    %{
      available: b["available"],
      current: b["current"],
      limit: b["limit"],
      iso_currency_code: b["iso_currency_code"],
      unofficial_currency_code: b["unofficial_currency_code"],
      last_updated_datetime: b["last_updated_datetime"]
    }
  end

  defp parse_type("depository"), do: :depository
  defp parse_type("credit"), do: :credit
  defp parse_type("loan"), do: :loan
  defp parse_type("investment"), do: :investment
  defp parse_type(_), do: :other

  defp parse_subtype(nil), do: nil

  defp parse_subtype(s) do
    String.to_existing_atom(s)
  rescue
    ArgumentError ->
      Logger.warning("[PlaidEx] Unknown account subtype from Plaid: #{inspect(s)}")
      nil
  end
end
