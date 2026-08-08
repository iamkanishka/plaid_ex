defmodule PlaidEx.Support.DynamicSupervisorBase do
  @moduledoc """
  Shared boilerplate for `:one_for_one` `DynamicSupervisor`s that need no
  custom `init/1` options. Used by `PlaidEx.MultiTenant.TenantSupervisor`
  and `PlaidEx.Reliability.CircuitBreakerSupervisor`, which are otherwise
  identical aside from their child-management functions.

  ## Usage

      defmodule MySupervisor do
        use PlaidEx.Support.DynamicSupervisorBase
      end
  """

  defmacro __using__(_) do
    quote do
      use DynamicSupervisor

      @spec start_link(keyword()) :: Supervisor.on_start()
      def start_link(opts) do
        DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
      end

      @impl DynamicSupervisor
      @spec init(keyword()) :: {:ok, DynamicSupervisor.sup_flags()}
      def init(_) do
        DynamicSupervisor.init(strategy: :one_for_one)
      end
    end
  end
end
