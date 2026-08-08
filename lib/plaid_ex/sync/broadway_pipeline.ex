# This module wires together Broadway/GenStage pipeline stages with PlaidEx's
# own sync schemas and HTTP client as one cohesive pipeline definition.
# credo:disable-for-this-file Credo.Check.Refactor.ModuleDependencies
defmodule PlaidEx.Sync.BroadwayPipeline do
  @moduledoc """
  Broadway pipeline for high-throughput transaction synchronization.

  Use this instead of `TransactionSync` when you need:
  - Parallel processing of transactions from multiple items
  - Backpressure-aware ingestion
  - Batch processing with configurable batch sizes
  - Integration with Broadway's observability

  ## Architecture

  Messages flow:
  1. `SyncProducer` — GenStage producer fetching Plaid sync pages
  2. Broadway concurrency layer — parallel processing
  3. Your `handle_message/3` implementation — business logic

  ## Setup

      defmodule MyApp.TransactionPipeline do
        use PlaidEx.Sync.BroadwayPipeline

        @impl true
        def handle_transaction(%PlaidEx.Schemas.Transaction{} = tx, _context) do
          MyApp.Transactions.upsert(tx)
        end

        @impl true
        def handle_removed(transaction_id, _context) do
          MyApp.Transactions.delete(transaction_id)
        end
      end

  ## Starting

      {:ok, _pid} = MyApp.TransactionPipeline.start_link(
        access_tokens: ["access-sandbox-abc", "access-sandbox-xyz"],
        config: plaid_config(),
        concurrency: 10,
        batch_size: 100
      )

  ## Requirements

  Requires `:broadway` and `:gen_stage` in your deps.
  """

  defmacro __using__(_) do
    if Code.ensure_loaded?(Broadway) do
      quote do
        alias PlaidEx.Sync.BroadwayPipeline.Producer

        @behaviour PlaidEx.Sync.BroadwayPipeline

        use Broadway

        def start_link(opts) do
          access_tokens = Keyword.fetch!(opts, :access_tokens)
          config = Keyword.fetch!(opts, :config)
          concurrency = Keyword.get(opts, :concurrency, 5)
          batch_size = Keyword.get(opts, :batch_size, 50)
          batch_timeout = Keyword.get(opts, :batch_timeout_ms, 2_000)

          Broadway.start_link(__MODULE__,
            name: __MODULE__,
            producer: [
              module:
                {Producer,
                 %{
                   access_tokens: access_tokens,
                   config: config
                 }},
              concurrency: 1
            ],
            processors: [
              default: [concurrency: concurrency]
            ],
            batchers: [
              added: [
                concurrency: max(div(concurrency, 2), 1),
                batch_size: batch_size,
                batch_timeout: batch_timeout
              ],
              modified: [
                concurrency: max(div(concurrency, 2), 1),
                batch_size: batch_size,
                batch_timeout: batch_timeout
              ],
              removed: [
                concurrency: 2,
                batch_size: batch_size,
                batch_timeout: batch_timeout
              ]
            ]
          )
        end

        @impl Broadway
        def handle_message(_, %Broadway.Message{data: {:added, tx}} = message, ctx) do
          case __MODULE__.handle_transaction(tx, ctx) do
            :ok -> Broadway.Message.put_batcher(message, :added)
            {:error, reason} -> Broadway.Message.failed(message, reason)
          end
        end

        def handle_message(_, %Broadway.Message{data: {:modified, tx}} = message, ctx) do
          case __MODULE__.handle_transaction(tx, ctx) do
            :ok -> Broadway.Message.put_batcher(message, :modified)
            {:error, reason} -> Broadway.Message.failed(message, reason)
          end
        end

        def handle_message(_, %Broadway.Message{data: {:removed, id}} = message, ctx) do
          case __MODULE__.handle_removed(id, ctx) do
            :ok -> Broadway.Message.put_batcher(message, :removed)
            {:error, reason} -> Broadway.Message.failed(message, reason)
          end
        end

        @impl Broadway
        def handle_batch(:added, messages, _, _) do
          messages
        end

        def handle_batch(:modified, messages, _, _) do
          messages
        end

        def handle_batch(:removed, messages, _, _) do
          messages
        end

        @impl Broadway
        def handle_failed(messages, _) do
          require Logger

          Enum.each(messages, fn msg ->
            Logger.error("[PlaidEx.Broadway] Message failed: #{inspect(msg.status)}")
          end)

          messages
        end
      end
    else
      quote do
        @behaviour PlaidEx.Sync.BroadwayPipeline

        def start_link(_) do
          raise """
          PlaidEx.Sync.BroadwayPipeline requires :broadway.
          Add {:broadway, "~> 1.1"} to your deps.
          """
        end
      end
    end
  end

  @doc """
  Process a single added or modified transaction.
  Return `:ok` or `{:error, reason}`.
  """
  @callback handle_transaction(PlaidEx.Schemas.Transaction.t(), map()) ::
              :ok | {:error, term()}

  @doc """
  Process a removed transaction ID.
  Return `:ok` or `{:error, reason}`.
  """
  @callback handle_removed(String.t(), map()) :: :ok | {:error, term()}

  # ── GenStage Producer ────────────────────────────────────────────────────────
  #
  # Wrapped around the whole `defmodule`, not nested inside it — `use
  # GenStage` is a compile-time macro expansion and can't be guarded
  # from inside the module body itself.

  if Code.ensure_loaded?(GenStage) do
    defmodule Producer do
      @moduledoc false

      use GenStage

      alias PlaidEx.HTTP.Client
      alias PlaidEx.Schemas.TransactionSyncPage

      @spec start_link(map()) :: GenServer.on_start()
      def start_link(opts) do
        GenStage.start_link(__MODULE__, opts)
      end

      @spec init(%{access_tokens: [String.t()], config: PlaidEx.Config.t()}) ::
              {:producer, map()}
      def init(%{access_tokens: tokens, config: config}) do
        state = %{
          tokens: tokens,
          config: config,
          cursors: %{},
          pending: :queue.new()
        }

        {:producer, state}
      end

      @spec handle_demand(pos_integer(), map()) :: {:noreply, [term()], map()}
      def handle_demand(demand, state) when demand > 0 do
        {messages, new_state} = produce_messages(demand, state)
        {:noreply, messages, new_state}
      end

      defp produce_messages(demand, state) do
        Enum.reduce_while(state.tokens, {[], state}, fn token, {msgs, st} ->
          if length(msgs) >= demand do
            {:halt, {msgs, st}}
          else
            case fetch_and_emit(token, st) do
              {new_msgs, new_st} -> {:cont, {msgs ++ new_msgs, new_st}}
            end
          end
        end)
      end

      defp fetch_and_emit(token, state) do
        cursor = Map.get(state.cursors, token)

        base_body = %{"access_token" => token, "count" => 250}
        body = if cursor, do: Map.put(base_body, "cursor", cursor), else: base_body

        case Client.post("/transactions/sync", body, state.config) do
          {:ok, raw} ->
            page = TransactionSyncPage.from_map(raw)
            new_cursors = Map.put(state.cursors, token, page.next_cursor)

            messages =
              Enum.map(page.added, fn tx -> {:added, tx} end) ++
                Enum.map(page.modified, fn tx -> {:modified, tx} end) ++
                Enum.map(page.removed, fn id -> {:removed, id} end)

            broadway_messages =
              Enum.map(messages, fn data ->
                %Broadway.Message{
                  data: data,
                  acknowledger: Broadway.NoopAcknowledger.init()
                }
              end)

            {broadway_messages, %{state | cursors: new_cursors}}

          {:error, _} ->
            {[], state}
        end
      end
    end
  end
end
