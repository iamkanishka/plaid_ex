defmodule PlaidEx.OAuth.StateStore do
  @moduledoc """
  ETS-backed store for OAuth state parameters.

  Stores OAuth state → PKCE verifier mappings with TTL.
  State is consumed (deleted) on retrieval to prevent replay.

  ## Security properties

  - State is a cryptographically random 32-byte token
  - Each state can only be consumed once (deleted on read)
  - States expire after 10 minutes (configurable)
  - The store is per-node — for multi-node deployments, use a
    shared cache (Redis) backed by a custom implementation
  """

  use PlaidEx.Support.EtsGenServer, table: :plaid_ex_oauth_state

  # 10 minutes
  @default_ttl_seconds 600
  @cleanup_interval_ms :timer.minutes(2)

  # ── Public API ──────────────────────────────────────────────────────────────

  @doc """
  Stores an OAuth state with optional PKCE verifier.
  Returns the state token.

  ## Example

      pkce = PlaidEx.OAuth.PKCE.generate()
      state = PlaidEx.OAuth.StateStore.put(%{
        pkce: pkce,
        tenant_id: "acme_corp",
        redirect_uri: "https://myapp.com/oauth/callback"
      })
  """
  @spec put(map()) :: String.t()
  def put(metadata \\ %{}) do
    random_bytes = :crypto.strong_rand_bytes(32)
    state = Base.url_encode64(random_bytes, padding: false)
    ttl = Application.get_env(:plaid_ex, :oauth_state_ttl_seconds, @default_ttl_seconds)
    expires_at = System.system_time(:second) + ttl

    :ets.insert(@table, {state, metadata, expires_at})
    state
  end

  @doc """
  Retrieves and consumes an OAuth state.

  Returns `{:ok, metadata}` and deletes the state (one-time use).
  Returns `{:error, :not_found}` if expired or never existed.
  """
  @spec consume(String.t()) :: {:ok, map()} | {:error, :not_found | :expired}
  def consume(state) when is_binary(state) do
    case :ets.lookup(@table, state) do
      [{^state, metadata, expires_at}] ->
        :ets.delete(@table, state)

        if System.system_time(:second) <= expires_at do
          {:ok, metadata}
        else
          {:error, :expired}
        end

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Peeks at a state without consuming it.
  Useful for multi-step flows where the state is needed across redirects.
  """
  @spec peek(String.t()) :: {:ok, map()} | {:error, :not_found | :expired}
  def peek(state) when is_binary(state) do
    case :ets.lookup(@table, state) do
      [{^state, metadata, expires_at}] ->
        if System.system_time(:second) <= expires_at do
          {:ok, metadata}
        else
          :ets.delete(@table, state)
          {:error, :expired}
        end

      [] ->
        {:error, :not_found}
    end
  end

  # ── GenServer ───────────────────────────────────────────────────────────────

  defp init_state(table) do
    schedule_cleanup()
    %{table: table}
  end

  @impl GenServer
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    :ets.select_delete(@table, [{{:_, :_, :"$1"}, [{:<, :"$1", now}], [true]}])
    schedule_cleanup()
    {:noreply, state}
  end

  defp schedule_cleanup, do: Process.send_after(self(), :cleanup, @cleanup_interval_ms)
end
