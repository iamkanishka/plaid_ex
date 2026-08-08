defmodule PlaidEx.OAuth.PKCETest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias PlaidEx.OAuth.PKCE

  describe "generate/0" do
    test "returns a PKCE struct with all required fields" do
      pkce = PKCE.generate()

      assert %PKCE{} = pkce
      assert is_binary(pkce.code_verifier)
      assert is_binary(pkce.code_challenge)
      assert pkce.challenge_method == "S256"
    end

    test "code_verifier is base64url encoded (no padding)" do
      pkce = PKCE.generate()
      # Should match base64url pattern (no + / or =)
      assert String.match?(pkce.code_verifier, ~r/^[A-Za-z0-9_-]+$/)
    end

    test "code_challenge is base64url encoded SHA-256 of verifier" do
      pkce = PKCE.generate()

      hash = :crypto.hash(:sha256, pkce.code_verifier)
      expected_challenge = Base.url_encode64(hash, padding: false)

      assert pkce.code_challenge == expected_challenge
    end

    test "each call generates a unique verifier" do
      verifiers = for _ <- 1..10, do: PKCE.generate().code_verifier
      assert Enum.uniq(verifiers) == verifiers
    end

    test "verifier is at least 43 characters (RFC 7636 minimum)" do
      pkce = PKCE.generate()
      # 32 bytes base64url = ~43 characters
      assert byte_size(pkce.code_verifier) >= 43
    end

    property "challenge method is always S256" do
      check all(_ <- constant(nil)) do
        pkce = PKCE.generate()
        assert pkce.challenge_method == "S256"
      end
    end
  end
end

defmodule PlaidEx.OAuth.StateStoreTest do
  use ExUnit.Case, async: false

  alias PlaidEx.OAuth.StateStore

  describe "put/1 and consume/1" do
    test "stores and retrieves metadata" do
      metadata = %{user_id: "user-123", tenant_id: "acme"}
      state = StateStore.put(metadata)

      assert is_binary(state)
      # should be a substantial token
      assert byte_size(state) > 20

      {:ok, retrieved} = StateStore.consume(state)
      assert retrieved.user_id == "user-123"
      assert retrieved.tenant_id == "acme"
    end

    test "each put generates a unique state token" do
      states = for _ <- 1..10, do: StateStore.put(%{})
      assert Enum.uniq(states) == states
    end

    test "state is single-use (consumed on retrieval)" do
      state = StateStore.put(%{test: true})

      {:ok, _} = StateStore.consume(state)

      # Second consumption should fail
      assert {:error, :not_found} = StateStore.consume(state)
    end

    test "returns not_found for unknown state" do
      assert {:error, :not_found} = StateStore.consume("nonexistent-state-token")
    end

    test "state is URL-safe (base64url)" do
      state = StateStore.put(%{})
      assert String.match?(state, ~r/^[A-Za-z0-9_=-]+$/)
    end
  end

  describe "peek/1" do
    test "retrieves without consuming" do
      state = StateStore.put(%{user_id: "peek-user"})

      {:ok, data1} = StateStore.peek(state)
      {:ok, data2} = StateStore.peek(state)

      assert data1.user_id == "peek-user"
      assert data2.user_id == "peek-user"

      # Should still be consumable
      {:ok, _} = StateStore.consume(state)
    end

    test "returns not_found for unknown state" do
      assert {:error, :not_found} = StateStore.peek("unknown-state")
    end
  end

  describe "concurrent access" do
    test "handles concurrent puts and consumes safely" do
      # Generate many states concurrently
      states =
        1..50
        |> Enum.map(fn i -> Task.async(fn -> StateStore.put(%{seq: i}) end) end)
        |> Task.await_many(5_000)

      # Consume all concurrently
      results =
        states
        |> Enum.map(fn state -> Task.async(fn -> StateStore.consume(state) end) end)
        |> Task.await_many(5_000)

      # All should succeed
      assert Enum.all?(results, fn r -> match?({:ok, _}, r) end)

      # All should have unique seq values
      seqs = Enum.map(results, fn {:ok, m} -> m[:seq] end)
      assert Enum.sort(seqs) == Enum.to_list(1..50)
    end
  end
end
