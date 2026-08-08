defmodule PlaidEx.HTTP.ClientBehaviour do
  @moduledoc """
  Behaviour for the HTTP client. Define a Mox mock against this for testing.

  ## Setup

      # test/support/mocks.ex
      Mox.defmock(PlaidEx.MockHTTPClient, for: PlaidEx.HTTP.ClientBehaviour)

      # test/config or setup:
      Application.put_env(:plaid_ex, :http_client, PlaidEx.MockHTTPClient)
  """

  @callback post(
              path :: String.t(),
              body :: map(),
              config :: PlaidEx.Config.t(),
              opts :: keyword()
            ) :: {:ok, map()} | {:error, PlaidEx.Error.t()}
end
