if Code.ensure_loaded?(Oban) do
  defmodule PlaidEx.Webhooks.ObanWorker do
    @moduledoc """
    Oban worker for durable webhook processing.

    When Oban is available, webhooks are enqueued as jobs instead of
    being dispatched via `Task.Supervisor`. This provides:

    - **Durability** — jobs survive application restarts
    - **Retry logic** — configurable retry with exponential backoff
    - **Dead-letter queue** — failed jobs are retained for inspection
    - **Visibility** — jobs visible in Oban Web
    - **Concurrency control** — queue-level concurrency limits

    ## Setup

        # In your Oban config:
        config :my_app, Oban,
          queues: [plaid_webhooks: 10],
          plugins: [Oban.Plugins.Pruner]

    This module is only compiled when Oban is available as a
    dependency — `Code.ensure_loaded?/1` is checked here, wrapping the
    entire module definition, because `use Oban.Worker` is a
    compile-time macro expansion and cannot be guarded from inside the
    module body.
    """

    use Oban.Worker,
      queue: :plaid_webhooks,
      max_attempts: 10,
      unique: [period: 60, fields: [:args]]

    require Logger

    alias PlaidEx.Config.TenantRegistry
    alias PlaidEx.Webhooks.Dispatcher

    @impl Oban.Worker
    def perform(%Oban.Job{args: %{"raw_event" => event, "tenant_id" => tenant_id}}) do
      config = resolve_config(tenant_id)
      handler = Application.get_env(:plaid_ex, :webhook_handler)

      if handler do
        Dispatcher.dispatch(event, handler, config)
      else
        Logger.warning("[PlaidEx.ObanWorker] No :webhook_handler configured in :plaid_ex")
        :ok
      end
    end

    defp resolve_config(nil), do: PlaidEx.Config.load!()

    defp resolve_config(tenant_id) do
      case TenantRegistry.get(tenant_id) do
        {:ok, config} -> config
        :not_found -> PlaidEx.Config.load!()
      end
    end
  end
end
