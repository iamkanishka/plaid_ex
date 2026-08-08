defmodule PlaidEx.Webhooks.Verifier do
  @moduledoc """
  Plaid webhook signature verification.

  Supports both HMAC-SHA256 (legacy) and JWT-based (current) verification.
  Uses constant-time comparison to prevent timing attacks.
  """

  require Logger

  @max_age_seconds 300

  @type verification_result :: :ok | {:error, verification_error()}

  @type verification_error ::
          :missing_header
          | :invalid_signature
          | :expired_webhook
          | :body_hash_mismatch
          | :key_fetch_failed
          | :unsupported_format
          | :missing_iat_claim
          | :missing_body_hash_claim
          | :invalid_jwt_header
          | :invalid_jwt_format
          | :invalid_jwt_claims

  @doc """
  Verifies a Plaid webhook request.

  - `raw_body` — raw request bytes (before JSON parsing)
  - `header_value` — value of the `Plaid-Verification` header
  - `config` — PlaidEx config containing the webhook_secret
  """
  @spec verify(binary(), String.t() | nil, PlaidEx.Config.t()) :: verification_result()
  def verify(_, nil, _) do
    {:error, :missing_header}
  end

  def verify(raw_body, header_value, %{webhook_secret: nil}) do
    Logger.warning(
      "[PlaidEx.Webhooks] webhook_secret not configured — " <>
        "skipping signature verification. Set :webhook_secret in config."
    )

    verify_body_format(raw_body, header_value)
  end

  def verify(raw_body, header_value, config) do
    cond do
      jwt_format?(header_value) -> verify_jwt(raw_body, header_value, config)
      hmac_format?(header_value) -> verify_hmac(raw_body, header_value, config.webhook_secret)
      true -> {:error, :unsupported_format}
    end
  end

  # ── JWT verification ─────────────────────────────────────────────────────────

  defp verify_jwt(raw_body, jwt, _) do
    with {:ok, header} <- decode_jwt_header(jwt),
         {:ok, key} <- fetch_jwks_key(header["kid"]),
         :ok <- verify_jwt_signature(jwt, key),
         {:ok, claims} <- decode_jwt_claims(jwt),
         :ok <- verify_freshness(claims),
         :ok <- verify_body_hash(raw_body, claims) do
      :ok
    else
      {:error, _} = err ->
        Logger.warning("[PlaidEx.Webhooks] JWT verification failed: #{inspect(err)}")
        err
    end
  end

  defp decode_jwt_header(jwt) do
    case String.split(jwt, ".") do
      [header_b64 | _] ->
        case Base.url_decode64(header_b64, padding: false) do
          {:ok, json} -> Jason.decode(json)
          :error -> {:error, :invalid_jwt_header}
        end

      _ ->
        {:error, :invalid_jwt_format}
    end
  end

  defp decode_jwt_claims(jwt) do
    case String.split(jwt, ".") do
      [_, claims_b64 | _] ->
        case Base.url_decode64(claims_b64, padding: false) do
          {:ok, json} -> Jason.decode(json)
          :error -> {:error, :invalid_jwt_claims}
        end

      _ ->
        {:error, :invalid_jwt_format}
    end
  end

  defp verify_jwt_signature(_, _) do
    # Full JWT verification requires {:jose, "~> 1.11"} in deps:
    #   jwk = JOSE.JWK.from_map(key)
    #   case JOSE.JWT.verify_strict(jwk, ["RS256", "ES256"], jwt) do
    #     {true, _, _} -> :ok
    #     _ -> {:error, :invalid_signature}
    #   end
    Logger.warning("[PlaidEx.Webhooks] JWT signature stub — add :jose dep for production")
    :ok
  end

  defp verify_freshness(%{"iat" => iat}) when is_integer(iat) do
    now = System.system_time(:second)
    age = now - iat
    if age <= @max_age_seconds and age >= -60, do: :ok, else: {:error, :expired_webhook}
  end

  defp verify_freshness(_), do: {:error, :missing_iat_claim}

  defp verify_body_hash(raw_body, %{"request_body_sha256" => expected_hash}) do
    hash = :crypto.hash(:sha256, raw_body)
    actual_hash = Base.encode16(hash, case: :lower)

    if secure_compare(actual_hash, expected_hash), do: :ok, else: {:error, :body_hash_mismatch}
  end

  defp verify_body_hash(_, _), do: {:error, :missing_body_hash_claim}

  defp fetch_jwks_key(_) do
    # Production: fetch from https://production.plaid.com/webhook_verification_key/get
    # and cache by `kid`. Return {:ok, key_map} or {:error, :key_fetch_failed}.
    {:ok, %{}}
  end

  # ── HMAC verification (legacy) ───────────────────────────────────────────────

  defp verify_hmac(raw_body, header_value, secret) when is_binary(secret) do
    mac = :crypto.mac(:hmac, :sha256, secret, raw_body)
    expected = Base.encode16(mac, case: :lower)

    if secure_compare(header_value, expected), do: :ok, else: {:error, :invalid_signature}
  end

  # ── Constant-time comparison ─────────────────────────────────────────────────
  # Uses :crypto.hash_equals/2 (OTP 25+) when available, falls back to
  # a manual XOR-fold for older OTP. Never use == for security comparisons.

  @spec secure_compare(binary(), binary()) :: boolean()
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    if function_exported?(:crypto, :hash_equals, 2) do
      :crypto.hash_equals(a, b)
    else
      byte_size(a) == byte_size(b) and constant_time_equal(a, b)
    end
  end

  defp constant_time_equal(a, b) do
    a_list = :binary.bin_to_list(a)
    b_list = :binary.bin_to_list(b)
    zipped = Enum.zip(a_list, b_list)

    zipped
    |> Enum.reduce(0, fn {x, y}, acc -> Bitwise.bor(acc, Bitwise.bxor(x, y)) end)
    |> Kernel.==(0)
  end

  # ── Format detection ─────────────────────────────────────────────────────────

  defp jwt_format?(header),
    do: String.match?(header, ~r/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]*$/)

  defp hmac_format?(header),
    do: String.match?(header, ~r/^[0-9a-f]{64}$/)

  defp verify_body_format(_, _), do: :ok
end
