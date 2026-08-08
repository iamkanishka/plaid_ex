defmodule PlaidEx.OAuth.PKCE do
  @moduledoc """
  PKCE (Proof Key for Code Exchange) implementation for OAuth 2.0.

  Plaid's OAuth institutions (e.g., Chase, Wells Fargo) use PKCE to
  protect the authorization code flow. This module generates the
  `code_verifier` and `code_challenge` pair.

  ## Flow

  1. Generate verifier + challenge: PlaidEx.OAuth.PKCE.generate/0
  2. Store the verifier (server-side): PlaidEx.OAuth.StateStore.put/2
  3. Pass the challenge to Link token creation
  4. After OAuth redirect, retrieve verifier and pass to token exchange

  ## Security

  - `code_verifier`: cryptographically random 32-byte string, base64url encoded
  - `code_challenge`: SHA-256 hash of verifier, base64url encoded
  - Challenge method: `S256` (required by Plaid)
  """

  @type t :: %__MODULE__{
          code_verifier: String.t(),
          code_challenge: String.t(),
          challenge_method: String.t()
        }

  defstruct [:code_verifier, :code_challenge, challenge_method: "S256"]

  @doc """
  Generates a new PKCE verifier/challenge pair.

  ## Example

      pkce = PlaidEx.OAuth.PKCE.generate()
      # Store pkce.code_verifier server-side, keyed by state
      # Pass pkce.code_challenge to link token creation
  """
  @spec generate() :: t()
  def generate do
    verifier_bytes = :crypto.strong_rand_bytes(32)
    verifier = Base.url_encode64(verifier_bytes, padding: false)

    hash = :crypto.hash(:sha256, verifier)
    challenge = Base.url_encode64(hash, padding: false)

    %__MODULE__{
      code_verifier: verifier,
      code_challenge: challenge,
      challenge_method: "S256"
    }
  end
end
