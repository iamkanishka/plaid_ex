defmodule PlaidEx.API.Monitor do
  @moduledoc """
  Plaid Monitor API — watchlist screening and compliance.
  """

  use PlaidEx.API.Base
  @doc "Creates an Individual Screening."
  @spec create_individual_screening(Config.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  @spec create_individual_screening(Config.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_individual_screening(%Config{} = config, params, opts \\ []) do
    Client.post("/watchlist_screening/individual/create", params, config, opts)
  end

  @doc "Retrieves an Individual Screening."
  @spec get_individual_screening(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_individual_screening(Config.t(), String.t(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def get_individual_screening(%Config{} = config, watchlist_screening_id, opts \\ []) do
    Client.post(
      "/watchlist_screening/individual/get",
      %{"watchlist_screening_id" => watchlist_screening_id},
      config,
      opts
    )
  end

  @doc "Lists Individual Screenings."
  @spec list_individual_screenings(Config.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec list_individual_screenings(Config.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_individual_screenings(%Config{} = config, opts \\ []) do
    Client.post("/watchlist_screening/individual/list", %{}, config, opts)
  end

  @doc "Creates an Entity Screening."
  @spec create_entity_screening(Config.t(), map()) :: {:ok, map()} | {:error, Error.t()}
  @spec create_entity_screening(Config.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def create_entity_screening(%Config{} = config, params, opts \\ []) do
    Client.post("/watchlist_screening/entity/create", params, config, opts)
  end
end
