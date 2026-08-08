defmodule PlaidEx.API.Transfer do
  @moduledoc """
  Plaid Transfer API — ACH and RTP transfer orchestration.
  """

  use PlaidEx.API.Base

  alias PlaidEx.Schemas.Transfer

  @doc "Creates a transfer authorization (eligibility check)."
  @spec authorize(Config.t(), map()) ::
          {:ok, %{authorization: map(), request_id: String.t() | nil}} | {:error, Error.t()}
  @spec authorize(Config.t(), map(), keyword()) ::
          {:ok, %{authorization: map(), request_id: String.t() | nil}} | {:error, Error.t()}
  def authorize(%Config{} = config, params, opts \\ []) do
    case Client.post("/transfer/authorization/create", params, config, opts) do
      {:ok, raw} -> {:ok, %{authorization: raw["authorization"], request_id: raw["request_id"]}}
      {:error, _} = error -> error
    end
  end

  @doc "Creates a transfer using an authorization ID."
  @spec create(Config.t(), map()) :: {:ok, Transfer.t()} | {:error, Error.t()}
  @spec create(Config.t(), map(), keyword()) :: {:ok, Transfer.t()} | {:error, Error.t()}
  def create(%Config{} = config, params, opts \\ []) do
    fetch_transfer("/transfer/create", params, config, opts)
  end

  @doc "Retrieves a transfer by ID."
  @spec get(Config.t(), String.t()) :: {:ok, Transfer.t()} | {:error, Error.t()}
  @spec get(Config.t(), String.t(), keyword()) :: {:ok, Transfer.t()} | {:error, Error.t()}
  def get(%Config{} = config, transfer_id, opts \\ []) do
    fetch_transfer("/transfer/get", %{"transfer_id" => transfer_id}, config, opts)
  end

  defp fetch_transfer(path, body, config, opts) do
    case Client.post(path, body, config, opts) do
      {:ok, raw} -> {:ok, Transfer.from_map(raw["transfer"])}
      {:error, _} = error -> error
    end
  end

  @doc "Cancels a transfer (only possible in `pending` status)."
  @spec cancel(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec cancel(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def cancel(%Config{} = config, transfer_id, opts \\ []) do
    Client.post("/transfer/cancel", %{"transfer_id" => transfer_id}, config, opts)
  end

  @doc "Lists transfer events."
  @spec get_events(Config.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_events(Config.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_events(%Config{} = config, opts \\ []) do
    body =
      %{
        "start_date" => Keyword.get(opts, :start_date),
        "end_date" => Keyword.get(opts, :end_date),
        "transfer_id" => Keyword.get(opts, :transfer_id),
        "account_id" => Keyword.get(opts, :account_id),
        "event_types" => Keyword.get(opts, :event_types),
        "count" => Keyword.get(opts, :count, 25),
        "offset" => Keyword.get(opts, :offset, 0)
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    Client.post("/transfer/event/list", body, config, opts)
  end

  @doc "Syncs transfer events using cursor-based pagination."
  @spec sync_events(Config.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec sync_events(Config.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def sync_events(%Config{} = config, opts \\ []) do
    body = %{
      "after_id" => Keyword.get(opts, :after_id, 0),
      "count" => Keyword.get(opts, :count, 25)
    }

    Client.post("/transfer/event/sync", body, config, opts)
  end

  @doc "Lists transfers."
  @spec list(Config.t()) :: {:ok, %{transfers: [Transfer.t()]}} | {:error, Error.t()}
  @spec list(Config.t(), keyword()) :: {:ok, %{transfers: [Transfer.t()]}} | {:error, Error.t()}
  def list(%Config{} = config, opts \\ []) do
    body = %{
      "start_date" => Keyword.get(opts, :start_date),
      "end_date" => Keyword.get(opts, :end_date),
      "count" => Keyword.get(opts, :count, 25),
      "offset" => Keyword.get(opts, :offset, 0)
    }

    case Client.post("/transfer/list", body, config, opts) do
      {:ok, raw} -> {:ok, %{transfers: Enum.map(raw["transfers"] || [], &Transfer.from_map/1)}}
      {:error, _} = error -> error
    end
  end
end
