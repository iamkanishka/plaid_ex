defmodule PlaidEx.Support.EtsGenServer do
  @moduledoc """
  Shared boilerplate for GenServers that own a single named, public ETS
  table (`:set`, `:public`, `:named_table`, with read/write concurrency).

  Several PlaidEx components follow this exact shape — an ETS-backed
  GenServer that creates its table on `init/1` and hands out the table
  name for direct concurrent reads: `PlaidEx.OAuth.StateStore`,
  `PlaidEx.Webhooks.Deduplicator`, `PlaidEx.Config.TenantRegistry`,
  `PlaidEx.HTTP.RateLimiter`, and `PlaidEx.Sync.CursorStore.EtsBackend`.
  This module extracts the repeated `start_link/1` and `init/1` so each
  of those modules only needs to declare its own table name and any
  post-creation setup.

  ## Usage

      defmodule MyStore do
        use PlaidEx.Support.EtsGenServer, table: :my_table

        # Optional — override to customize initial state or run setup
        # (e.g. scheduling periodic work) right after the table is created:
        defp init_state(table) do
          schedule_cleanup()
          %{table: table}
        end
      end

  The table name is passed as a `use` option (rather than read from a
  pre-set `@table` module attribute) so the module directive order
  stays `use` → module attributes, matching normal style conventions.
  """

  defmacro __using__(opts) do
    table = Keyword.fetch!(opts, :table)

    quote do
      use GenServer

      @table unquote(table)

      @spec start_link(keyword()) :: GenServer.on_start()
      def start_link(opts \\ []) do
        GenServer.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @impl GenServer
      @spec init(keyword()) :: {:ok, map()}
      def init(_) do
        table =
          :ets.new(@table, [
            :set,
            :public,
            :named_table,
            read_concurrency: true,
            write_concurrency: true
          ])

        {:ok, init_state(table)}
      end

      @spec init_state(:ets.table()) :: %{table: :ets.table()}
      defp init_state(table), do: %{table: table}

      defoverridable init_state: 1
    end
  end
end
