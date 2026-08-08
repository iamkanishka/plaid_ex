defmodule PlaidEx.API.PaymentInitiation do
  @moduledoc """
  Plaid Payment Initiation API — bank-to-bank payments (UK/EU).
  """

  use PlaidEx.API.Base
  @doc "Creates a payment recipient."
  @spec create_recipient(Config.t(), map()) ::
          {:ok, %{recipient_id: String.t()}} | {:error, Error.t()}
  @spec create_recipient(Config.t(), map(), keyword()) ::
          {:ok, %{recipient_id: String.t()}} | {:error, Error.t()}
  def create_recipient(%Config{} = config, params, opts \\ []) do
    case Client.post("/payment_initiation/recipient/create", params, config, opts) do
      {:ok, raw} -> {:ok, %{recipient_id: raw["recipient_id"], request_id: raw["request_id"]}}
      {:error, _} = error -> error
    end
  end

  @doc "Retrieves a payment recipient."
  @spec get_recipient(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_recipient(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_recipient(%Config{} = config, recipient_id, opts \\ []) do
    Client.post(
      "/payment_initiation/recipient/get",
      %{"recipient_id" => recipient_id},
      config,
      opts
    )
  end

  @doc "Lists all payment recipients."
  @spec list_recipients(Config.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec list_recipients(Config.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_recipients(%Config{} = config, opts \\ []) do
    Client.post("/payment_initiation/recipient/list", %{}, config, opts)
  end

  @doc "Creates a payment."
  @spec create_payment(Config.t(), map()) ::
          {:ok, %{payment_id: String.t()}} | {:error, Error.t()}
  @spec create_payment(Config.t(), map(), keyword()) ::
          {:ok, %{payment_id: String.t()}} | {:error, Error.t()}
  def create_payment(%Config{} = config, params, opts \\ []) do
    idempotency_key = Keyword.get(opts, :idempotency_key)

    case Client.post(
           "/payment_initiation/payment/create",
           params,
           config,
           Keyword.merge(opts, idempotency_key: idempotency_key)
         ) do
      {:ok, raw} ->
        {:ok,
         %{payment_id: raw["payment_id"], status: raw["status"], request_id: raw["request_id"]}}

      {:error, _} = error ->
        error
    end
  end

  @doc "Retrieves a payment by ID."
  @spec get_payment(Config.t(), String.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec get_payment(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def get_payment(%Config{} = config, payment_id, opts \\ []) do
    Client.post("/payment_initiation/payment/get", %{"payment_id" => payment_id}, config, opts)
  end

  @doc "Lists all payments."
  @spec list_payments(Config.t()) :: {:ok, map()} | {:error, Error.t()}
  @spec list_payments(Config.t(), keyword()) :: {:ok, map()} | {:error, Error.t()}
  def list_payments(%Config{} = config, opts \\ []) do
    body =
      %{
        "count" => Keyword.get(opts, :count, 10),
        "cursor" => Keyword.get(opts, :cursor),
        "sort" => Keyword.get(opts, :sort)
      }
      |> Enum.reject(fn {_, v} -> is_nil(v) end)
      |> Map.new()

    Client.post("/payment_initiation/payment/list", body, config, opts)
  end

  @doc "Reverses a payment."
  @spec reverse_payment(Config.t(), String.t(), String.t()) ::
          {:ok, map()} | {:error, Error.t()}
  @spec reverse_payment(Config.t(), String.t(), String.t(), map()) ::
          {:ok, map()} | {:error, Error.t()}
  @spec reverse_payment(Config.t(), String.t(), String.t(), map(), keyword()) ::
          {:ok, map()} | {:error, Error.t()}
  def reverse_payment(%Config{} = config, payment_id, idempotency_key, params \\ %{}, opts \\ []) do
    body = Map.merge(params, %{"payment_id" => payment_id, "idempotency_key" => idempotency_key})
    Client.post("/payment_initiation/payment/reverse", body, config, opts)
  end
end
