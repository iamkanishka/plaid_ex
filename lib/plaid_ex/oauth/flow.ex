# This module owns the full OAuth/Link token exchange lifecycle (PKCE, state
# store, API calls, schemas) as one cohesive flow.
# credo:disable-for-this-file Credo.Check.Refactor.ModuleDependencies
defmodule PlaidEx.OAuth.Flow do
  @moduledoc """
  High-level OAuth flow orchestration for Plaid Link.

  Manages the complete OAuth flow for institutions that require
  out-of-app authorization (e.g., Chase, Wells Fargo, Capital One).

  ## Flow overview

  ### Desktop / web flow:
  1. `initiate/2` — creates Link token with PKCE, stores state
  2. User completes Link, is redirected to your `oauth_redirect_uri`
  3. `complete/2` — validates state, exchanges public token

  ## Example

      {:ok, %{link_token: token, oauth_state: state}} =
        PlaidEx.OAuth.Flow.initiate(config,
          user_id: "user-123",
          products: ["transactions"],
          redirect_uri: "https://myapp.com/oauth/callback"
        )
  """

  alias PlaidEx.API.Items
  alias PlaidEx.API.Link
  alias PlaidEx.Config
  alias PlaidEx.Error
  alias PlaidEx.OAuth.PKCE
  alias PlaidEx.OAuth.StateStore
  alias PlaidEx.Schemas.AccessToken
  alias PlaidEx.Schemas.LinkToken

  @type initiate_opts :: [
          user_id: String.t(),
          products: [String.t()],
          country_codes: [String.t()],
          redirect_uri: String.t(),
          language: String.t(),
          tenant_id: String.t() | nil,
          additional_consented_products: [String.t()]
        ]

  @type initiate_result :: %{
          link_token: String.t(),
          expiration: String.t(),
          oauth_state: String.t(),
          pkce: PKCE.t()
        }

  @doc """
  Initiates an OAuth Link flow.

  Creates a Link token with PKCE challenge and stores OAuth state.
  """
  @spec initiate(Config.t(), initiate_opts()) ::
          {:ok, initiate_result()} | {:error, Error.t()}
  def initiate(%Config{} = config, opts) do
    user_id = Keyword.fetch!(opts, :user_id)
    products = Keyword.get(opts, :products, ["transactions"])
    country_codes = Keyword.get(opts, :country_codes, ["US"])
    redirect_uri = Keyword.fetch!(opts, :redirect_uri)
    language = Keyword.get(opts, :language, "en")
    tenant_id = Keyword.get(opts, :tenant_id, config.tenant_id)

    pkce = PKCE.generate()

    oauth_state =
      StateStore.put(%{
        user_id: user_id,
        tenant_id: tenant_id,
        pkce: pkce,
        redirect_uri: redirect_uri,
        initiated_at: DateTime.utc_now()
      })

    link_params = %{
      "user" => %{"client_user_id" => user_id},
      "client_name" => Application.get_env(:plaid_ex, :app_name, "Your App"),
      "products" => products,
      "country_codes" => country_codes,
      "language" => language,
      "redirect_uri" => redirect_uri,
      "optional_products" => Keyword.get(opts, :additional_consented_products, [])
    }

    case Link.create_token(config, link_params, tenant_id: tenant_id) do
      {:ok, %LinkToken{} = link_token} ->
        {:ok,
         %{
           link_token: link_token.link_token,
           expiration: link_token.expiration,
           oauth_state: oauth_state,
           pkce: pkce
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Completes an OAuth flow after the user is redirected back.

  Validates state, retrieves PKCE verifier, and exchanges the
  public token for an access token.
  """
  @spec complete(Config.t(), keyword()) ::
          {:ok, %{access_token: String.t(), item_id: String.t()}}
          | {:error, Error.t()}
  def complete(%Config{} = config, opts) do
    oauth_state_id = Keyword.fetch!(opts, :oauth_state_id)
    public_token = Keyword.fetch!(opts, :public_token)

    case StateStore.consume(oauth_state_id) do
      {:ok, state_data} ->
        tenant_id = state_data[:tenant_id]

        case Items.exchange_public_token(config, public_token, tenant_id: tenant_id) do
          {:ok, %AccessToken{} = token} ->
            {:ok, %{access_token: token.access_token, item_id: token.item_id}}

          {:error, _} = error ->
            error
        end

      {:error, :not_found} ->
        {:error,
         %Error{
           type: :oauth_error,
           code: "INVALID_OAUTH_STATE",
           message: "OAuth state not found or already consumed",
           status: 400
         }}

      {:error, :expired} ->
        {:error,
         %Error{
           type: :oauth_error,
           code: "EXPIRED_OAUTH_STATE",
           message: "OAuth state expired — user took too long to authorize",
           status: 400
         }}
    end
  end
end
