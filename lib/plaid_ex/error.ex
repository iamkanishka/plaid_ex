defmodule PlaidEx.Error do
  @moduledoc """
  Typed Plaid error struct with retry classification, suggested actions,
  and structured metadata for logging and observability.

  Every error that can come from Plaid is classified into:
  - An `error_type` matching Plaid's taxonomy
  - A `suggested_action` for your application code
  - A `retryable` flag for the HTTP client's retry logic

  ## Plaid error taxonomy

  Plaid categorises errors into these types (from their API reference):
  - `INVALID_REQUEST` — malformed request parameters
  - `INVALID_RESULT` — Plaid returned an unexpected result
  - `INVALID_INPUT` — semantically invalid input (e.g., wrong access token)
  - `INSTITUTION_ERROR` — institution outage, timeout, or maintenance
  - `RATE_LIMIT_EXCEEDED` — API rate limit hit
  - `API_ERROR` — Plaid internal error
  - `ITEM_ERROR` — item-level errors (login required, no accounts, etc.)
  - `ASSET_REPORT_ERROR` — asset report specific errors
  - `RECAPTCHA_ERROR` — CAPTCHA challenge required
  - `OAUTH_ERROR` — OAuth flow errors
  - `PAYMENT_ERROR` — payment initiation errors
  - `BANK_TRANSFER_ERROR` — bank transfer errors
  - `INCOME_VERIFICATION_ERROR` — income verification errors
  - `MICRODEPOSITS_ERROR` — micro-deposit verification errors

  ## Handling errors

      case PlaidEx.API.Transactions.sync(config, access_token: token) do
        {:ok, page} ->
          process(page)

        {:error, %PlaidEx.Error{code: "ITEM_LOGIN_REQUIRED"}} ->
          # Send user back through Link to reconnect
          redirect_to_link_update_mode(item_id)

        {:error, %PlaidEx.Error{retryable: true} = error} ->
          # Safe to retry after delay
          schedule_retry(error)

        {:error, %PlaidEx.Error{} = error} ->
          # Non-retryable — needs human attention
          alert_on_call(error)
      end
  """

  @type error_type ::
          :invalid_request
          | :invalid_result
          | :invalid_input
          | :institution_error
          | :rate_limit_exceeded
          | :api_error
          | :item_error
          | :asset_report_error
          | :recaptcha_error
          | :oauth_error
          | :payment_error
          | :bank_transfer_error
          | :income_verification_error
          | :microdeposits_error
          | :unknown

  @type suggested_action ::
          :retry
          | :retry_with_delay
          | :reauthenticate
          | :contact_support
          | :no_action
          | :update_item
          | :check_institution
          | :check_plaid_status

  @type t :: %__MODULE__{
          type: error_type(),
          code: String.t(),
          message: String.t(),
          display_message: String.t() | nil,
          request_id: String.t() | nil,
          causes: [map()],
          status: integer(),
          suggested_action: suggested_action(),
          retryable: boolean(),
          requires_reauthentication: boolean(),
          institution_id: String.t() | nil
        }

  @enforce_keys [:type, :code, :message, :status]
  defstruct [
    :type,
    :code,
    :message,
    :display_message,
    :request_id,
    :institution_id,
    causes: [],
    status: 0,
    suggested_action: :no_action,
    retryable: false,
    requires_reauthentication: false
  ]

  # ── Retryable error codes (safe to retry with backoff) ──────────────────────
  @retryable_codes ~w(
    RATE_LIMIT_EXCEEDED
    INTERNAL_SERVER_ERROR
    PLANNED_MAINTENANCE
    INSTITUTION_DOWN
    INSTITUTION_NOT_RESPONDING
    INSTITUTION_NO_LONGER_SUPPORTED
    PRODUCT_NOT_READY
    ASSET_REPORT_GENERATION_FAILED
    TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION
  )

  # ── Item errors requiring user re-authentication via Link ───────────────────
  @reauth_codes ~w(
    ITEM_LOGIN_REQUIRED
    INVALID_CREDENTIALS
    INVALID_MFA
    INVALID_SEND_METHOD
    USER_SETUP_REQUIRED
    MFA_NOT_SUPPORTED
    NO_ACCOUNTS
    ITEM_LOCKED
    ITEM_NOT_SUPPORTED
    INSUFFICIENT_CREDENTIALS
    USER_INPUT_TIMEOUT
    ITEM_PENDING_EXPIRATION
  )

  # ── Institution-level errors (inform user but not their fault) ───────────────
  @institution_codes ~w(
    INSTITUTION_DOWN
    INSTITUTION_NOT_RESPONDING
    INSTITUTION_NOT_AVAILABLE
    INSTITUTION_NO_LONGER_SUPPORTED
    INSTITUTION_PLANNED_MAINTENANCE
  )

  # ── Plaid-side errors (contact Plaid if persistent) ─────────────────────────
  @plaid_side_codes ~w(
    INTERNAL_SERVER_ERROR
    PLANNED_MAINTENANCE
    PRODUCT_NOT_READY
    ASSET_REPORT_GENERATION_FAILED
  )

  @doc """
  Constructs an `Error` from a Plaid HTTP response.
  """
  @spec from_plaid_response(integer(), map()) :: t()
  def from_plaid_response(status, %{"error_code" => code} = body) do
    type = parse_type(body["error_type"])
    retryable = code in @retryable_codes
    requires_reauth = code in @reauth_codes

    suggested_action =
      cond do
        code in @reauth_codes -> :reauthenticate
        code in @institution_codes -> :check_institution
        code in @plaid_side_codes -> :check_plaid_status
        code == "RATE_LIMIT_EXCEEDED" -> :retry_with_delay
        retryable -> :retry
        true -> :no_action
      end

    %__MODULE__{
      type: type,
      code: code,
      message: body["error_message"] || "Unknown Plaid error",
      display_message: body["display_message"],
      request_id: body["request_id"],
      causes: body["causes"] || [],
      status: status,
      suggested_action: suggested_action,
      retryable: retryable,
      requires_reauthentication: requires_reauth,
      institution_id: body["institution_id"]
    }
  end

  def from_plaid_response(status, body) when is_map(body) do
    %__MODULE__{
      type: :api_error,
      code: "UNEXPECTED_ERROR",
      message: "Unexpected Plaid response: #{inspect(body)}",
      status: status,
      retryable: status >= 500,
      suggested_action: if(status >= 500, do: :check_plaid_status, else: :contact_support)
    }
  end

  def from_plaid_response(status, _) do
    %__MODULE__{
      type: :api_error,
      code: "UNPARSEABLE_RESPONSE",
      message: "Could not parse Plaid error response",
      status: status,
      retryable: status >= 500
    }
  end

  @doc """
  Constructs an `Error` from an Elixir/network exception.
  """
  @spec from_exception(map()) :: t()
  def from_exception(%{reason: :timeout}) do
    %__MODULE__{
      type: :api_error,
      code: "REQUEST_TIMEOUT",
      message: "HTTP request to Plaid timed out",
      status: 0,
      retryable: true,
      suggested_action: :retry_with_delay
    }
  end

  def from_exception(%{reason: :econnrefused}) do
    %__MODULE__{
      type: :api_error,
      code: "CONNECTION_REFUSED",
      message: "Connection to Plaid refused — check network / firewall",
      status: 0,
      retryable: true,
      suggested_action: :retry_with_delay
    }
  end

  def from_exception(%{reason: :nxdomain}) do
    %__MODULE__{
      type: :api_error,
      code: "DNS_FAILURE",
      message: "DNS resolution failed for Plaid endpoint",
      status: 0,
      retryable: true,
      suggested_action: :retry_with_delay
    }
  end

  def from_exception(exception) do
    %__MODULE__{
      type: :api_error,
      code: "NETWORK_ERROR",
      message: "Network error: #{Exception.message(exception)}",
      status: 0,
      retryable: true,
      suggested_action: :retry
    }
  end

  @doc """
  Returns `true` if this error should trigger an automatic retry.
  """
  @spec retryable?(t()) :: boolean()
  def retryable?(%__MODULE__{retryable: r}), do: r

  @doc """
  Returns `true` if this error requires the user to re-authenticate via Link.
  """
  @spec requires_reauthentication?(t()) :: boolean()
  def requires_reauthentication?(%__MODULE__{requires_reauthentication: r}), do: r

  @doc """
  Returns `true` if this is an institution-side problem (not user or developer error).
  """
  @spec institution_error?(t()) :: boolean()
  def institution_error?(%__MODULE__{type: :institution_error}), do: true
  def institution_error?(_), do: false

  @doc """
  Returns a loggable map with sensitive fields removed.
  """
  @spec to_log_map(t()) :: map()
  def to_log_map(%__MODULE__{} = error) do
    %{
      error_type: error.type,
      error_code: error.code,
      error_message: error.message,
      plaid_request_id: error.request_id,
      status: error.status,
      retryable: error.retryable,
      suggested_action: error.suggested_action
    }
  end

  # ── Type parsing ────────────────────────────────────────────────────────────

  defp parse_type("INVALID_REQUEST"), do: :invalid_request
  defp parse_type("INVALID_RESULT"), do: :invalid_result
  defp parse_type("INVALID_INPUT"), do: :invalid_input
  defp parse_type("INSTITUTION_ERROR"), do: :institution_error
  defp parse_type("RATE_LIMIT_EXCEEDED"), do: :rate_limit_exceeded
  defp parse_type("API_ERROR"), do: :api_error
  defp parse_type("ITEM_ERROR"), do: :item_error
  defp parse_type("ASSET_REPORT_ERROR"), do: :asset_report_error
  defp parse_type("RECAPTCHA_ERROR"), do: :recaptcha_error
  defp parse_type("OAUTH_ERROR"), do: :oauth_error
  defp parse_type("PAYMENT_ERROR"), do: :payment_error
  defp parse_type("BANK_TRANSFER_ERROR"), do: :bank_transfer_error
  defp parse_type("INCOME_VERIFICATION_ERROR"), do: :income_verification_error
  defp parse_type("MICRODEPOSITS_ERROR"), do: :microdeposits_error
  defp parse_type(_), do: :unknown

  # ── Exception protocol ──────────────────────────────────────────────────────

  defimpl String.Chars, for: __MODULE__ do
    @spec to_string(PlaidEx.Error.t()) :: String.t()
    def to_string(%PlaidEx.Error{code: code, message: message, status: status}) do
      "PlaidEx.Error[#{code}] status=#{status} #{message}"
    end
  end

  defimpl Jason.Encoder, for: __MODULE__ do
    @spec encode(PlaidEx.Error.t(), Jason.Encode.opts()) :: iodata()
    def encode(error, opts) do
      log_map = PlaidEx.Error.to_log_map(error)
      Jason.Encode.map(log_map, opts)
    end
  end
end
