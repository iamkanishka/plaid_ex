defmodule PlaidEx.API.Income do
  @moduledoc """
  Plaid Income API — employment and income verification.
  """

  use PlaidEx.API.Base
  @doc "Creates an income verification for a user."
  @spec create_verification(Config.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  @spec create_verification(Config.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def create_verification(%Config{} = config, params, opts \\ []) do
    Client.post("/income/verification/create", params, config, opts)
  end

  @doc "Returns income verification summary."
  @spec get_summary(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_summary(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_summary(%Config{} = config, income_verification_id, opts \\ []) do
    Client.post(
      "/income/verification/summary/get",
      %{"income_verification_id" => income_verification_id},
      config,
      opts
    )
  end

  @doc "Returns payroll income data."
  @spec get_payroll(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_payroll(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_payroll(%Config{} = config, income_verification_id, opts \\ []) do
    Client.post(
      "/income/verification/payroll/get",
      %{"income_verification_id" => income_verification_id},
      config,
      opts
    )
  end
end
