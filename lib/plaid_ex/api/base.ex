defmodule PlaidEx.API.Base do
  @moduledoc """
  Shared aliases for `PlaidEx.API.*` modules.

  Every API module talks to Plaid through the same three core types —
  `PlaidEx.Config`, `PlaidEx.Error`, and `PlaidEx.HTTP.Client` — which
  previously meant the same three `alias` lines were repeated
  identically across all 24 API modules. `use PlaidEx.API.Base`
  injects them once; modules that also need schema-specific aliases
  (e.g. `alias PlaidEx.Schemas.Account`) still declare those
  themselves, same as before.

  ## Usage

      defmodule PlaidEx.API.Accounts do
        use PlaidEx.API.Base

        alias PlaidEx.Schemas.Account

        # ... Config, Error, Client, and Account are all in scope
      end
  """

  alias PlaidEx.Config
  alias PlaidEx.Error
  alias PlaidEx.HTTP.Client

  defmacro __using__(_) do
    quote do
      alias PlaidEx.Config
      alias PlaidEx.Error
      alias PlaidEx.HTTP.Client
      import PlaidEx.API.Base, only: [defsingle: 4]
    end
  end

  @doc """
  Defines a `name/2` and `name/3` function whose entire body posts a
  single named parameter to `http_path` — the exact shape shared by
  `Liabilities.get/2,3`, `Identity.get/2,3`, `Wallet.get/2,3`,
  `User.get/2,3`, `IdentityVerification.get/2,3`, `Items.remove/2,3`,
  `Assets.remove/2,3`, and the `refresh/2,3` functions in
  `Transactions`, `Statements`, and `Investments`.

  Writing these out by hand meant the same `@doc`/`@spec`/`def` block
  was repeated near-verbatim across API modules; `defsingle/4` defines
  the function (with its typespecs and docstring) from a single line
  at the call site instead.

  ## Example

      defsingle :get, "/wallet/get", "wallet_id", "Retrieves a wallet by ID."
  """
  defmacro defsingle(name, http_path, param_name, doc) do
    quote do
      @doc unquote(doc)
      @spec unquote(name)(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
      @spec unquote(name)(Config.t(), String.t(), keyword()) ::
              {:ok, map()} | {:error, Error.t()}
      def unquote(name)(%Config{} = config, value, opts \\ []) do
        PlaidEx.API.Base.single_param_post(
          unquote(http_path),
          unquote(param_name),
          value,
          config,
          opts
        )
      end
    end
  end

  @doc """
  Shared implementation for the many API functions whose entire body is
  `Client.post(path, %{"some_key" => value}, config, opts)` — a single
  named parameter POSTed to an endpoint with no response transform.
  """
  @spec single_param_post(String.t(), String.t(), term(), Config.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def single_param_post(path, param_name, param_value, %Config{} = config, opts) do
    Client.post(path, %{param_name => param_value}, config, opts)
  end
end
