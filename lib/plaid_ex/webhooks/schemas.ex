defmodule PlaidEx.Webhooks.Schemas do
  @moduledoc """
  Typed structs for all Plaid webhook event payloads.

  Each struct maps directly to Plaid's documented webhook schemas.
  Fields use snake_case Elixir conventions regardless of Plaid's
  camelCase JSON fields.
  """

  # ── Base event fields shared by all webhooks ────────────────────────────────

  defmodule BaseEvent do
    @moduledoc false
    @type t :: %__MODULE__{
            webhook_type: String.t(),
            webhook_code: String.t(),
            item_id: String.t() | nil,
            environment: String.t()
          }
    defstruct [:webhook_type, :webhook_code, :item_id, :environment]

    @spec base_fields(map()) :: %{
            webhook_type: String.t() | nil,
            webhook_code: String.t() | nil,
            item_id: String.t() | nil,
            environment: String.t()
          }
    def base_fields(map) do
      %{
        webhook_type: map["webhook_type"],
        webhook_code: map["webhook_code"],
        item_id: map["item_id"],
        environment: map["environment"] || "production"
      }
    end
  end

  # ── Transactions ─────────────────────────────────────────────────────────────

  # ── Shared struct shapes ─────────────────────────────────────────────────────
  #
  # A few distinct webhook events happen to share an identical field
  # shape today (though they represent unrelated Plaid webhook types,
  # so they stay separate structs rather than being merged into one —
  # that would incorrectly couple their futures together). These two
  # macros exist only to remove the literal duplication of the
  # @type/defstruct/from_map boilerplate between them.

  defmodule EventShapes do
    @moduledoc false

    defmacro base_event_with_account_id(moduledoc) do
      quote do
        @moduledoc unquote(moduledoc)

        @type t :: %__MODULE__{
                webhook_type: String.t(),
                webhook_code: String.t(),
                item_id: String.t(),
                environment: String.t(),
                account_id: String.t() | nil
              }

        defstruct [:webhook_type, :webhook_code, :item_id, :environment, :account_id]

        @spec from_map(map()) :: t()
        def from_map(map) do
          base = BaseEvent.base_fields(map)
          fields = Map.merge(base, %{account_id: map["account_id"]})
          struct!(__MODULE__, fields)
        end
      end
    end

    defmacro environment_only_event(moduledoc) do
      quote do
        @moduledoc unquote(moduledoc)

        @type t :: %__MODULE__{
                webhook_type: String.t(),
                webhook_code: String.t(),
                environment: String.t()
              }

        defstruct [:webhook_type, :webhook_code, :environment]

        @spec from_map(map()) :: t()
        def from_map(map) do
          # struct!/2 raises if handed keys the struct doesn't have (unlike
          # struct/2, which silently filters them) — base_fields/1 always
          # includes :item_id, which this struct doesn't have, so it must
          # be dropped first.
          base = BaseEvent.base_fields(map)
          fields = Map.take(base, [:webhook_type, :webhook_code, :environment])
          struct!(__MODULE__, fields)
        end
      end
    end
  end

  defmodule TransactionsSyncEvent do
    @moduledoc "TRANSACTIONS.SYNC_UPDATES_AVAILABLE webhook payload."

    @type t :: %__MODULE__{
            webhook_type: String.t(),
            webhook_code: String.t(),
            item_id: String.t(),
            environment: String.t(),
            initial_update_complete: boolean(),
            historical_update_complete: boolean()
          }

    defstruct [
      :webhook_type,
      :webhook_code,
      :item_id,
      :environment,
      initial_update_complete: false,
      historical_update_complete: false
    ]

    @spec from_map(map()) :: t()
    def from_map(map) do
      base = BaseEvent.base_fields(map)

      fields =
        Map.merge(base, %{
          initial_update_complete: map["initial_update_complete"] == true,
          historical_update_complete: map["historical_update_complete"] == true
        })

      struct!(__MODULE__, fields)
    end
  end

  defmodule TransactionsEvent do
    @moduledoc "TRANSACTIONS.INITIAL_UPDATE / HISTORICAL_UPDATE / DEFAULT_UPDATE webhook."

    @type t :: %__MODULE__{
            webhook_type: String.t(),
            webhook_code: String.t(),
            item_id: String.t(),
            environment: String.t(),
            new_transactions: integer(),
            removed_transactions: [String.t()]
          }

    defstruct [
      :webhook_type,
      :webhook_code,
      :item_id,
      :environment,
      new_transactions: 0,
      removed_transactions: []
    ]

    @spec from_map(map()) :: t()
    def from_map(map) do
      base = BaseEvent.base_fields(map)

      fields =
        Map.merge(base, %{
          new_transactions: map["new_transactions"] || 0,
          removed_transactions: map["removed_transactions"] || []
        })

      struct!(__MODULE__, fields)
    end
  end

  # ── Items ─────────────────────────────────────────────────────────────────────

  defmodule ItemEvent do
    @moduledoc "Generic ITEM webhook (PENDING_EXPIRATION, USER_PERMISSION_REVOKED, etc.)."

    @type t :: %__MODULE__{
            webhook_type: String.t(),
            webhook_code: String.t(),
            item_id: String.t(),
            environment: String.t(),
            consent_expiration_time: String.t() | nil
          }

    defstruct [:webhook_type, :webhook_code, :item_id, :environment, :consent_expiration_time]

    @spec from_map(map()) :: t()
    def from_map(map) do
      base = BaseEvent.base_fields(map)

      fields =
        Map.merge(base, %{
          consent_expiration_time: map["consent_expiration_time"]
        })

      struct!(__MODULE__, fields)
    end
  end

  defmodule ItemErrorEvent do
    @moduledoc "ITEM.ERROR webhook payload — includes structured Plaid error."

    @type t :: %__MODULE__{
            webhook_type: String.t(),
            webhook_code: String.t(),
            item_id: String.t(),
            environment: String.t(),
            error: map()
          }

    defstruct [:webhook_type, :webhook_code, :item_id, :environment, :error]

    @spec from_map(map()) :: t()
    def from_map(map) do
      base = BaseEvent.base_fields(map)

      fields =
        Map.merge(base, %{
          error: map["error"] || %{}
        })

      struct!(__MODULE__, fields)
    end
  end

  # ── Auth ──────────────────────────────────────────────────────────────────────

  defmodule AuthEvent do
    require EventShapes

    EventShapes.base_event_with_account_id(
      "AUTH webhook payload (AUTOMATICALLY_VERIFIED, VERIFICATION_EXPIRED)."
    )
  end

  # ── Transfer ──────────────────────────────────────────────────────────────────

  defmodule TransferEvent do
    require EventShapes

    EventShapes.environment_only_event("TRANSFER.TRANSFER_EVENTS_UPDATE webhook payload.")
  end

  # ── Payment Initiation ────────────────────────────────────────────────────────

  defmodule PaymentStatusEvent do
    @moduledoc "PAYMENT_INITIATION.PAYMENT_STATUS_UPDATE webhook payload."

    @type t :: %__MODULE__{
            webhook_type: String.t(),
            webhook_code: String.t(),
            environment: String.t(),
            payment_id: String.t(),
            new_payment_status: String.t(),
            old_payment_status: String.t(),
            original_reference: String.t() | nil,
            original_start_date: String.t() | nil,
            adjusted_reference: String.t() | nil,
            adjusted_start_date: String.t() | nil,
            timestamp: String.t(),
            error: map() | nil
          }

    defstruct [
      :webhook_type,
      :webhook_code,
      :environment,
      :payment_id,
      :new_payment_status,
      :old_payment_status,
      :original_reference,
      :original_start_date,
      :adjusted_reference,
      :adjusted_start_date,
      :timestamp,
      :error
    ]

    @spec from_map(map()) :: t()
    def from_map(map) do
      # struct!/2 raises on keys the struct doesn't have — this event has
      # no :item_id, so it must be dropped from base_fields/1's result.
      base =
        map
        |> BaseEvent.base_fields()
        |> Map.delete(:item_id)

      fields =
        Map.merge(base, %{
          payment_id: map["payment_id"],
          new_payment_status: map["new_payment_status"],
          old_payment_status: map["old_payment_status"],
          original_reference: map["original_reference"],
          original_start_date: map["original_start_date"],
          adjusted_reference: map["adjusted_reference"],
          adjusted_start_date: map["adjusted_start_date"],
          timestamp: map["timestamp"],
          error: map["error"]
        })

      struct!(__MODULE__, fields)
    end
  end

  # ── Identity Verification ─────────────────────────────────────────────────────

  defmodule IdentityVerificationEvent do
    @moduledoc "IDENTITY_VERIFICATION webhook payload."

    @type t :: %__MODULE__{
            webhook_type: String.t(),
            webhook_code: String.t(),
            environment: String.t(),
            identity_verification_id: String.t()
          }

    defstruct [:webhook_type, :webhook_code, :environment, :identity_verification_id]

    @spec from_map(map()) :: t()
    def from_map(map) do
      base =
        map
        |> BaseEvent.base_fields()
        |> Map.delete(:item_id)

      fields =
        Map.merge(base, %{
          identity_verification_id: map["identity_verification_id"]
        })

      struct!(__MODULE__, fields)
    end
  end

  # ── Income ────────────────────────────────────────────────────────────────────

  defmodule IncomeEvent do
    @moduledoc "INCOME.INCOME_VERIFICATION webhook payload."

    @type t :: %__MODULE__{
            webhook_type: String.t(),
            webhook_code: String.t(),
            item_id: String.t(),
            environment: String.t(),
            user_id: String.t() | nil,
            verification_status: String.t() | nil
          }

    defstruct [
      :webhook_type,
      :webhook_code,
      :item_id,
      :environment,
      :user_id,
      :verification_status
    ]

    @spec from_map(map()) :: t()
    def from_map(map) do
      base = BaseEvent.base_fields(map)

      fields =
        Map.merge(base, %{
          user_id: map["user_id"],
          verification_status: map["verification_status"]
        })

      struct!(__MODULE__, fields)
    end
  end

  # ── Investments ───────────────────────────────────────────────────────────────

  defmodule InvestmentsEvent do
    @moduledoc "INVESTMENTS_TRANSACTIONS.DEFAULT_UPDATE webhook payload."

    @type t :: %__MODULE__{
            webhook_type: String.t(),
            webhook_code: String.t(),
            item_id: String.t(),
            environment: String.t(),
            new_investments_transactions: integer(),
            canceled_investments_transactions: integer()
          }

    defstruct [
      :webhook_type,
      :webhook_code,
      :item_id,
      :environment,
      new_investments_transactions: 0,
      canceled_investments_transactions: 0
    ]

    @spec from_map(map()) :: t()
    def from_map(map) do
      base = BaseEvent.base_fields(map)

      fields =
        Map.merge(base, %{
          new_investments_transactions: map["new_investments_transactions"] || 0,
          canceled_investments_transactions: map["canceled_investments_transactions"] || 0
        })

      struct!(__MODULE__, fields)
    end
  end

  # ── Liabilities ───────────────────────────────────────────────────────────────

  defmodule LiabilitiesEvent do
    @moduledoc "LIABILITIES.DEFAULT_UPDATE webhook payload."

    @type t :: %__MODULE__{
            webhook_type: String.t(),
            webhook_code: String.t(),
            item_id: String.t(),
            environment: String.t(),
            account_ids_with_new_liabilities_data: [String.t()],
            account_ids_with_updated_liabilities_data: map()
          }

    defstruct [
      :webhook_type,
      :webhook_code,
      :item_id,
      :environment,
      account_ids_with_new_liabilities_data: [],
      account_ids_with_updated_liabilities_data: %{}
    ]

    @spec from_map(map()) :: t()
    def from_map(map) do
      base = BaseEvent.base_fields(map)

      fields =
        Map.merge(base, %{
          account_ids_with_new_liabilities_data:
            map["account_ids_with_new_liabilities_data"] || [],
          account_ids_with_updated_liabilities_data:
            map["account_ids_with_updated_liabilities_data"] || %{}
        })

      struct!(__MODULE__, fields)
    end
  end

  # ── Assets ────────────────────────────────────────────────────────────────────

  defmodule AssetsEvent do
    @moduledoc "ASSETS webhook payload (PRODUCT_READY, ERROR)."

    @type t :: %__MODULE__{
            webhook_type: String.t(),
            webhook_code: String.t(),
            environment: String.t(),
            asset_report_id: String.t() | nil,
            error: map() | nil
          }

    defstruct [
      :webhook_type,
      :webhook_code,
      :environment,
      :asset_report_id,
      :error
    ]

    @spec from_map(map()) :: t()
    def from_map(map) do
      base =
        map
        |> BaseEvent.base_fields()
        |> Map.delete(:item_id)

      fields =
        Map.merge(base, %{
          asset_report_id: map["asset_report_id"],
          error: map["error"]
        })

      struct!(__MODULE__, fields)
    end
  end

  # ── Beacon ────────────────────────────────────────────────────────────────────

  defmodule BeaconEvent do
    @moduledoc "BEACON webhook payload."

    @type t :: %__MODULE__{
            webhook_type: String.t(),
            webhook_code: String.t(),
            environment: String.t(),
            beacon_user_id: String.t()
          }

    defstruct [:webhook_type, :webhook_code, :environment, :beacon_user_id]

    @spec from_map(map()) :: t()
    def from_map(map) do
      base =
        map
        |> BaseEvent.base_fields()
        |> Map.delete(:item_id)

      fields =
        Map.merge(base, %{
          beacon_user_id: map["beacon_user_id"]
        })

      struct!(__MODULE__, fields)
    end
  end

  # ── Signal ────────────────────────────────────────────────────────────────────

  defmodule SignalEvent do
    require EventShapes

    EventShapes.environment_only_event("SIGNAL.DEFAULT_UPDATE webhook payload.")
  end

  # ── Statements ────────────────────────────────────────────────────────────────

  defmodule StatementsEvent do
    require EventShapes

    EventShapes.base_event_with_account_id("STATEMENTS.READY webhook payload.")
  end
end
