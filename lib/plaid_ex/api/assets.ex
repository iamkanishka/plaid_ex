defmodule PlaidEx.API.Assets do
  @moduledoc """
  Plaid Assets API — generate Asset Reports for income verification.
  """

  use PlaidEx.API.Base

  @doc "Creates an Asset Report asynchronously."
  @spec create(Config.t(), [String.t()], integer()) ::
          {:ok, %{asset_report_token: String.t()}} | {:error, Error.t()}
  @spec create(Config.t(), [String.t()], integer(), keyword()) ::
          {:ok, %{asset_report_token: String.t()}} | {:error, Error.t()}
  def create(%Config{} = config, access_tokens, days_requested, opts \\ []) do
    body = %{
      "access_tokens" => access_tokens,
      "days_requested" => days_requested,
      "options" => Keyword.get(opts, :options, %{})
    }

    case Client.post("/asset_report/create", body, config, opts) do
      {:ok, raw} ->
        {:ok,
         %{
           asset_report_token: raw["asset_report_token"],
           asset_report_id: raw["asset_report_id"],
           request_id: raw["request_id"]
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc "Retrieves a completed Asset Report."
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  @spec get(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  @spec get(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get(%Config{} = config, asset_report_token, opts \\ []) do
    body = %{
      "asset_report_token" => asset_report_token,
      "include_insights" => Keyword.get(opts, :include_insights, false)
    }

    Client.post("/asset_report/get", body, config, opts)
  end

  @doc "Retrieves an Asset Report in PDF format."
  @spec get_pdf(Config.t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  @spec get_pdf(Config.t(), String.t(), keyword()) :: {:ok, binary()} | {:error, Error.t()}
  def get_pdf(%Config{} = config, asset_report_token, opts \\ []) do
    request_opts = Keyword.put(opts, :response, :binary)

    case Client.post(
           "/asset_report/pdf/get",
           %{"asset_report_token" => asset_report_token},
           config,
           request_opts
         ) do
      {:ok, pdf} when is_binary(pdf) ->
        {:ok, pdf}

      {:ok, _} ->
        {:error,
         %Error{
           type: :api_error,
           code: "UNEXPECTED_RESPONSE_TYPE",
           message: "Expected a binary PDF response from /asset_report/pdf/get",
           status: 200
         }}

      {:error, _} = error ->
        error
    end
  end

  defsingle(:remove, "/asset_report/remove", "asset_report_token", "Removes an Asset Report.")

  @doc "Filters an Asset Report to include only specified account IDs."
  @spec filter(Config.t(), String.t(), [String.t()]) ::
          {:ok, %{asset_report_token: String.t()}} | {:error, Error.t()}
  @spec filter(Config.t(), String.t(), [String.t()], keyword()) ::
          {:ok, %{asset_report_token: String.t()}} | {:error, Error.t()}
  def filter(%Config{} = config, asset_report_token, account_ids_to_exclude, opts \\ []) do
    case Client.post(
           "/asset_report/filter",
           %{
             "asset_report_token" => asset_report_token,
             "account_ids_to_exclude" => account_ids_to_exclude
           },
           config,
           opts
         ) do
      {:ok, raw} -> {:ok, %{asset_report_token: raw["asset_report_token"]}}
      {:error, _} = error -> error
    end
  end

  @doc "Creates an Audit Copy of an Asset Report for sharing with a third party."
  @spec create_audit_copy(Config.t(), String.t(), String.t()) ::
          {:ok, %{audit_copy_token: String.t()}} | {:error, Error.t()}
  @spec create_audit_copy(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, %{audit_copy_token: String.t()}} | {:error, Error.t()}
  def create_audit_copy(%Config{} = config, asset_report_token, auditor_id, opts \\ []) do
    case Client.post(
           "/asset_report/audit_copy/create",
           %{"asset_report_token" => asset_report_token, "auditor_id" => auditor_id},
           config,
           opts
         ) do
      {:ok, raw} -> {:ok, %{audit_copy_token: raw["audit_copy_token"]}}
      {:error, _} = error -> error
    end
  end
end
