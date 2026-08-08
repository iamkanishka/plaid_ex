defmodule PlaidEx.API.Link do
  @moduledoc """
  Plaid Link Token API.

  Link tokens are the entry point to every Plaid integration.
  They authorize a specific Link session with configured products,
  user identity, and customization.

  ## Link token lifecycle

  1. Your server calls `create_token/2` — server-side only, never client-side
  2. Pass the `link_token` to the Plaid Link SDK (iOS, Android, Web)
  3. User completes Link, your frontend receives a `public_token`
  4. Your server calls `PlaidEx.API.Items.exchange_public_token/3`
  5. Store the returned `access_token` — this is the permanent credential

  Link tokens expire after 4 hours. Do not persist them.
  """

  use PlaidEx.API.Base

  alias PlaidEx.Schemas.LinkToken

  @doc """
  Creates a Link token.

  ## Required params

      user: %{client_user_id: "your-user-id"},
      client_name: "Your App Name",
      products: ["transactions"],
      country_codes: ["US"],
      language: "en"
  """
  @spec create_token(Config.t(), keyword() | map()) ::
          {:ok, LinkToken.t()} | {:error, Error.t()}
  @spec create_token(Config.t(), keyword() | map(), keyword()) ::
          {:ok, LinkToken.t()} | {:error, Error.t()}
  def create_token(%Config{} = config, params, opts \\ []) do
    body = normalize_params(params)

    case Client.post("/link/token/create", body, config, opts) do
      {:ok, raw} -> {:ok, LinkToken.from_map(raw)}
      {:error, _} = error -> error
    end
  end

  @doc "Retrieves metadata about an existing link token."
  @spec get_token(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_token(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_token(%Config{} = config, link_token, opts \\ []) do
    Client.post("/link/token/get", %{"link_token" => link_token}, config, opts)
  end

  @doc "Lists all Link sessions for debugging (sandbox only)."
  @spec list_sessions(Config.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec list_sessions(Config.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_sessions(%Config{} = config, opts \\ []) do
    Client.post("/link/sessions/list", %{}, config, opts)
  end

  defp normalize_params(params) when is_map(params), do: params

  defp normalize_params(params) when is_list(params) do
    Map.new(params, fn {k, v} -> {to_string(k), v} end)
  end
end
