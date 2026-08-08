defmodule PlaidEx.API.Transactions do
  @moduledoc """
  Plaid Transactions API.

  Supports both the modern cursor-based `/transactions/sync` endpoint
  and the legacy `/transactions/get` endpoint.

  For new integrations, always use `sync/2`.
  """

  use PlaidEx.API.Base

  alias PlaidEx.API.Enrich
  alias PlaidEx.Schemas.Transaction
  alias PlaidEx.Schemas.TransactionSyncPage

  @doc """
  Fetches transaction updates since the last cursor position.

  This is Plaid's preferred endpoint for ongoing transaction ingestion.
  Returns added, modified, and removed transaction arrays.

  **The cursor MUST be persisted after each successful call.**
  Use `PlaidEx.Sync.TransactionSync` to manage this automatically.
  """
  @spec sync(Config.t(), keyword()) ::
          {:ok, TransactionSyncPage.t()} | {:error, Error.t()}
  def sync(%Config{} = config, opts) do
    access_token = Keyword.fetch!(opts, :access_token)
    cursor = Keyword.get(opts, :cursor)
    count = Keyword.get(opts, :count, 500)
    options = Keyword.get(opts, :options, %{})

    base_body = %{"access_token" => access_token, "count" => count, "options" => options}
    body = if cursor, do: Map.put(base_body, "cursor", cursor), else: base_body

    case Client.post("/transactions/sync", body, config, opts) do
      {:ok, raw} -> {:ok, TransactionSyncPage.from_map(raw)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Legacy transaction retrieval by date range.

  Prefer `sync/2` for new integrations.
  """
  @spec get(Config.t(), keyword()) ::
          {:ok, %{transactions: [Transaction.t()], total_transactions: integer()}}
          | {:error, Error.t()}
  def get(%Config{} = config, opts) do
    access_token = Keyword.fetch!(opts, :access_token)
    start_date = Keyword.fetch!(opts, :start_date)
    end_date = Keyword.fetch!(opts, :end_date)
    count = Keyword.get(opts, :count, 500)
    offset = Keyword.get(opts, :offset, 0)

    body = %{
      "access_token" => access_token,
      "start_date" => start_date,
      "end_date" => end_date,
      "options" => %{"count" => count, "offset" => offset}
    }

    case Client.post("/transactions/get", body, config, opts) do
      {:ok, raw} ->
        {:ok,
         %{
           transactions: Enum.map(raw["transactions"] || [], &Transaction.from_map/1),
           accounts: raw["accounts"] || [],
           total_transactions: raw["total_transactions"] || 0,
           item: raw["item"]
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc "Returns recurring transaction streams (subscriptions, income, bills)."
  @spec get_recurring(Config.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_recurring(%Config{} = config, opts) do
    access_token = Keyword.fetch!(opts, :access_token)
    account_ids = Keyword.get(opts, :account_ids, [])

    Client.post(
      "/transactions/recurring/get",
      %{"access_token" => access_token, "account_ids" => account_ids},
      config,
      opts
    )
  end

  @doc "Enriches a list of non-Plaid transactions."
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  @spec enrich(Config.t(), [map()]) ::
          {:ok, %{enriched_transactions: [map()]}} | {:error, Error.t()}
  # credo:disable-for-next-line Credo.Check.Design.DuplicatedCode
  @spec enrich(Config.t(), [map()], keyword()) ::
          {:ok, %{enriched_transactions: [map()]}} | {:error, Error.t()}
  def enrich(%Config{} = config, transactions, opts \\ []) do
    Enrich.enrich(config, transactions, opts)
  end

  defsingle(
    :refresh,
    "/transactions/refresh",
    "access_token",
    "Refreshes transaction data for an item (triggers async data fetch)."
  )
end
