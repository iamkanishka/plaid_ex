defmodule PlaidEx.Reliability.Bulkhead do
  @moduledoc """
  Bulkhead isolation using bounded process pools.

  Prevents a spike in one area (e.g., investment sync for one tenant)
  from exhausting resources needed by another (e.g., auth for all tenants).

  ## Named bulkheads

  - `:transactions` — transaction sync workers
  - `:webhooks` — webhook processing
  - `:investments` — investment data ingestion
  - `:transfers` — transfer operations
  - `:general` — default for uncategorised requests

  ## Usage

      PlaidEx.Reliability.Bulkhead.run(:transactions, fn ->
        PlaidEx.API.Transactions.sync(config, access_token: token)
      end)

  Returns `{:ok, result}` or `{:error, :bulkhead_full}` if the pool
  is at capacity.
  """

  use GenServer

  @pools %{
    transactions: 50,
    webhooks: 100,
    investments: 20,
    transfers: 30,
    general: 200
  }

  defmodule PoolState do
    @moduledoc false
    defstruct [:name, :max, current: 0, queue: :queue.new()]
  end

  # ── Public API ──────────────────────────────────────────────────────────────

  @spec run(atom(), (-> term())) :: {:ok, term()} | {:error, :bulkhead_full}
  @spec run(atom(), (-> term()), keyword()) :: {:ok, term()} | {:error, :bulkhead_full}
  def run(pool_name, fun, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    server = via(pool_name)

    case GenServer.call(server, {:acquire, self()}, timeout) do
      :ok ->
        try do
          result = fun.()
          {:ok, result}
        after
          GenServer.cast(server, {:release, self()})
        end

      {:error, :full} ->
        {:error, :bulkhead_full}
    end
  rescue
    _ -> {:error, :bulkhead_full}
  end

  @spec status(atom()) :: map()
  def status(pool_name) do
    server = via(pool_name)
    GenServer.call(server, :status)
  rescue
    _ -> %{error: :not_started}
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  @spec start_link({atom(), pos_integer()}) :: GenServer.on_start()
  def start_link({name, max}) do
    GenServer.start_link(__MODULE__, {name, max}, name: via(name))
  end

  @doc "Returns child specs for all bulkhead pools, suitable for a Supervisor."
  @spec child_specs() :: [map()]
  def child_specs do
    Enum.map(@pools, fn {name, max} ->
      %{
        id: {__MODULE__, name},
        start: {__MODULE__, :start_link, [{name, max}]},
        restart: :permanent
      }
    end)
  end

  @impl GenServer
  def init({name, max}) do
    {:ok, %PoolState{name: name, max: max}}
  end

  @impl GenServer
  def handle_call({:acquire, _}, _, %PoolState{current: current, max: max} = state)
      when current >= max do
    {:reply, {:error, :full}, state}
  end

  def handle_call({:acquire, _}, _, state) do
    {:reply, :ok, %{state | current: state.current + 1}}
  end

  def handle_call(:status, _, state) do
    {:reply,
     %{
       name: state.name,
       max: state.max,
       current: state.current,
       available: state.max - state.current
     }, state}
  end

  @impl GenServer
  def handle_cast({:release, _}, state) do
    {:noreply, %{state | current: max(state.current - 1, 0)}}
  end

  defp via(name), do: {:via, Registry, {PlaidEx.BulkheadRegistry, name}}
end
