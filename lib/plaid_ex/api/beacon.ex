defmodule PlaidEx.API.Beacon do
  @moduledoc """
  Plaid Beacon API — fraud and risk intelligence network.
  """

  use PlaidEx.API.Base
  @doc "Creates a Beacon User."
  @spec create_user(Config.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  @spec create_user(Config.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def create_user(%Config{} = config, params, opts \\ []) do
    Client.post("/beacon/user/create", params, config, opts)
  end

  @doc "Retrieves a Beacon User."
  @spec get_user(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_user(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_user(%Config{} = config, beacon_user_id, opts \\ []) do
    Client.post("/beacon/user/get", %{"beacon_user_id" => beacon_user_id}, config, opts)
  end

  @doc "Reviews a Beacon User (approve / reject)."
  @spec review_user(Config.t(), String.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec review_user(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def review_user(%Config{} = config, beacon_user_id, status, opts \\ []) do
    Client.post(
      "/beacon/user/review",
      %{"beacon_user_id" => beacon_user_id, "status" => status},
      config,
      opts
    )
  end

  @doc "Creates a Beacon Report (fraud report)."
  @spec create_report(Config.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  @spec create_report(Config.t(), map(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def create_report(%Config{} = config, params, opts \\ []) do
    Client.post("/beacon/report/create", params, config, opts)
  end

  @doc "Lists all Beacon Reports for a user."
  @spec list_reports(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec list_reports(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_reports(%Config{} = config, beacon_user_id, opts \\ []) do
    Client.post("/beacon/report/list", %{"beacon_user_id" => beacon_user_id}, config, opts)
  end
end
