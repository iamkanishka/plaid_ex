defmodule PlaidEx.API.Statements do
  @moduledoc """
  Plaid Statements API — retrieve bank statements.
  """

  use PlaidEx.API.Base

  @doc "Lists available statements for an Item."
  @spec list(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec list(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list(%Config{} = config, access_token, opts \\ []) do
    Client.post("/statements/list", %{"access_token" => access_token}, config, opts)
  end

  @doc "Downloads a statement PDF."
  @spec download(Config.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, Error.t()}
  @spec download(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, binary()} | {:error, Error.t()}
  def download(%Config{} = config, access_token, statement_id, opts \\ []) do
    request_opts = Keyword.put(opts, :response, :binary)

    case Client.post(
           "/statements/download",
           %{"access_token" => access_token, "statement_id" => statement_id},
           config,
           request_opts
         ) do
      {:ok, pdf} when is_binary(pdf) ->
        {:ok, pdf}

      {:ok, _} ->
        {:error,
         %Error{
           type: :api_error,
           code: "UNEXPECTED_RESPONSE_TYPE",
           message: "Expected a binary PDF response from /statements/download",
           status: 200
         }}

      {:error, _} = error ->
        error
    end
  end

  defsingle(
    :refresh,
    "/statements/refresh",
    "access_token",
    "Refreshes statements data for an Item."
  )
end
