defmodule PlaidEx.API.IdentityVerification do
  @moduledoc """
  Plaid Identity Verification (IDV) API — KYC/AML identity verification.
  """

  use PlaidEx.API.Base

  @doc "Creates an Identity Verification session."
  @spec create(Config.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  @spec create(Config.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def create(%Config{} = config, params, opts \\ []) do
    Client.post("/identity_verification/create", params, config, opts)
  end

  defsingle(
    :get,
    "/identity_verification/get",
    "identity_verification_id",
    "Retrieves an Identity Verification session."
  )

  @doc "Lists Identity Verification sessions for a user."
  @spec list(Config.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec list(Config.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list(%Config{} = config, opts \\ []) do
    body =
      %{
        "template_id" => Keyword.get(opts, :template_id),
        "client_user_id" => Keyword.get(opts, :client_user_id),
        "cursor" => Keyword.get(opts, :cursor)
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    Client.post("/identity_verification/list", body, config, opts)
  end

  @doc "Retries an Identity Verification session."
  @spec retry(Config.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  @spec retry(Config.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def retry(%Config{} = config, params, opts \\ []) do
    Client.post("/identity_verification/retry", params, config, opts)
  end
end
