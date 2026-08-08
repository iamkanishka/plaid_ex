defmodule PlaidEx.Sync.SyncSupervisor do
  @moduledoc """
  DynamicSupervisor managing transaction sync workers.

  Each access token gets its own supervised `TransactionSync` worker.
  Workers are `:transient` — they restart on unexpected crashes but
  stop cleanly when asked.

  Workers are deduplicated by access token. Attempting to start a
  second worker for the same access token returns `{:error, :already_started}`.
  """

  use DynamicSupervisor
  require Logger

  alias PlaidEx.Sync.TransactionSync

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  def init(_) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 10, max_seconds: 60)
  end

  @doc """
  Starts a sync worker. Returns `{:error, :already_started}` if one
  exists for this access token.
  """
  @spec start_worker(String.t(), PlaidEx.Config.t(), keyword()) ::
          {:ok, pid()} | {:error, :already_started | term()}
  def start_worker(access_token, config, opts) do
    case Registry.lookup(PlaidEx.SyncRegistry, access_token) do
      [{_, _}] ->
        Logger.debug("[PlaidEx.SyncSupervisor] Worker already running for token (masked)")
        {:error, :already_started}

      [] ->
        child_spec = %{
          id: {TransactionSync, access_token},
          start: {TransactionSync, :start_link, [{access_token, config, opts}]},
          restart: :transient,
          shutdown: 5_000
        }

        DynamicSupervisor.start_child(__MODULE__, child_spec)
    end
  end

  @doc """
  Returns a list of all running sync workers with their status.
  """
  @spec list_workers() :: [map()]
  def list_workers do
    __MODULE__
    |> DynamicSupervisor.which_children()
    |> Enum.map(fn {_, pid, _, _} ->
      case Registry.keys(PlaidEx.SyncRegistry, pid) do
        [access_token] ->
          %{pid: pid, access_token: access_token}

        _ ->
          %{pid: pid, access_token: :unknown}
      end
    end)
  end

  @doc """
  Number of active sync workers.
  """
  @spec worker_count() :: non_neg_integer()
  def worker_count do
    %{active: count} = DynamicSupervisor.count_children(__MODULE__)
    count
  end
end
