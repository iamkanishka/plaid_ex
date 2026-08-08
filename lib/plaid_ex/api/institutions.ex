defmodule PlaidEx.API.Institutions do
  @moduledoc """
  Plaid Institutions API — search and retrieve institution metadata.
  """

  use PlaidEx.API.Base

  alias PlaidEx.Schemas.Institution

  @doc "Retrieves a single institution by ID."
  @spec get(Config.t(), String.t()) :: {:ok, Institution.t()} | {:error, Error.t()}
  @spec get(Config.t(), String.t(), [String.t()]) :: {:ok, Institution.t()} | {:error, Error.t()}
  @spec get(Config.t(), String.t(), [String.t()], keyword()) ::
          {:ok, Institution.t()} | {:error, Error.t()}
  def get(%Config{} = config, institution_id, country_codes \\ ["US"], opts \\ []) do
    case Client.post(
           "/institutions/get_by_id",
           %{
             "institution_id" => institution_id,
             "country_codes" => country_codes,
             "options" => Keyword.get(opts, :options, %{include_optional_metadata: true})
           },
           config,
           opts
         ) do
      {:ok, raw} -> {:ok, Institution.from_map(raw["institution"])}
      {:error, _} = error -> error
    end
  end

  @doc "Lists institutions with pagination."
  @spec list(Config.t()) ::
          {:ok, %{institutions: [Institution.t()], total: integer()}} | {:error, Error.t()}
  @spec list(Config.t(), keyword()) ::
          {:ok, %{institutions: [Institution.t()], total: integer()}} | {:error, Error.t()}
  def list(%Config{} = config, opts \\ []) do
    body = %{
      "count" => Keyword.get(opts, :count, 500),
      "offset" => Keyword.get(opts, :offset, 0),
      "country_codes" => Keyword.get(opts, :country_codes, ["US"]),
      "options" => Keyword.get(opts, :options, %{})
    }

    case Client.post("/institutions/get", body, config, opts) do
      {:ok, raw} ->
        {:ok,
         %{
           institutions: Enum.map(raw["institutions"] || [], &Institution.from_map/1),
           total: raw["total"] || 0
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc "Searches institutions by name or routing number."
  @spec search(Config.t(), String.t()) ::
          {:ok, %{institutions: [Institution.t()]}} | {:error, Error.t()}
  @spec search(Config.t(), String.t(), keyword()) ::
          {:ok, %{institutions: [Institution.t()]}} | {:error, Error.t()}
  def search(%Config{} = config, query, opts \\ []) do
    body = %{
      "query" => query,
      "products" => Keyword.get(opts, :products, []),
      "country_codes" => Keyword.get(opts, :country_codes, ["US"]),
      "options" => Keyword.get(opts, :options, %{})
    }

    case Client.post("/institutions/search", body, config, opts) do
      {:ok, raw} ->
        {:ok, %{institutions: Enum.map(raw["institutions"] || [], &Institution.from_map/1)}}

      {:error, _} = error ->
        error
    end
  end
end
