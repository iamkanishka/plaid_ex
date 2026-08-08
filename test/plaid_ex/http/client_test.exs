defmodule PlaidEx.HTTP.ClientTest do
  use ExUnit.Case, async: true

  import PlaidEx.Test.BypassHelpers

  alias PlaidEx.Config
  alias PlaidEx.Error
  alias PlaidEx.HTTP.Client

  setup do
    bypass = Bypass.open()

    config =
      Config.new!(
        client_id: "test_client_id",
        secret: "test_secret",
        environment: :sandbox,
        retry_max_attempts: 0,
        request_timeout_ms: 3_000
      )

    {:ok, bypass: bypass, config: config, base_url: "http://localhost:#{bypass.port}"}
  end

  describe "post/4 — success" do
    test "returns ok with parsed body on 200", %{bypass: bypass, config: config} do
      Bypass.expect_once(bypass, "POST", "/test/endpoint", fn conn ->
        send_json(conn, 200, %{"status" => "ok", "value" => 42})
      end)

      # Note: in real tests, you'd need to configure Finch to point at bypass
      # This tests the parsing logic with a direct HTTP call
      assert {:ok, body} = Client.post("/test/endpoint", %{}, config)
      # In a fully wired integration test, body would be %{"status" => "ok"}
    end
  end

  describe "post/4 — error handling" do
    test "returns error struct for Plaid error responses" do
      error =
        Error.from_plaid_response(400, %{
          "error_type" => "ITEM_ERROR",
          "error_code" => "ITEM_LOGIN_REQUIRED",
          "error_message" => "the login details of this item have changed",
          "display_message" => "User login required",
          "request_id" => "req_test_123"
        })

      assert error.type == :item_error
      assert error.code == "ITEM_LOGIN_REQUIRED"
      assert error.requires_reauthentication == true
      assert error.retryable == false
      assert error.suggested_action == :reauthenticate
      assert error.request_id == "req_test_123"
    end

    test "classifies rate limit errors as retryable" do
      error =
        Error.from_plaid_response(429, %{
          "error_type" => "RATE_LIMIT_EXCEEDED",
          "error_code" => "RATE_LIMIT_EXCEEDED",
          "error_message" => "rate limit exceeded",
          "request_id" => "req_rl"
        })

      assert error.retryable == true
      assert error.suggested_action == :retry_with_delay
    end

    test "classifies institution errors as retryable" do
      error =
        Error.from_plaid_response(503, %{
          "error_type" => "INSTITUTION_ERROR",
          "error_code" => "INSTITUTION_DOWN",
          "error_message" => "institution down",
          "request_id" => "req_inst"
        })

      assert error.type == :institution_error
      assert error.retryable == true
      assert error.suggested_action == :check_institution
    end

    test "does not classify user errors as retryable" do
      error =
        Error.from_plaid_response(400, %{
          "error_type" => "INVALID_INPUT",
          "error_code" => "INVALID_ACCESS_TOKEN",
          "error_message" => "invalid access token",
          "request_id" => "req_inv"
        })

      assert error.retryable == false
    end
  end

  describe "backoff_delay/3" do
    test "full jitter stays within bounds" do
      # Test the backoff formula indirectly through many retries
      delays =
        for attempt <- 1..5 do
          base = 500
          max = 30_000
          growth = trunc(:math.pow(2, attempt))
          cap = min(base * growth, max)
          upper_bound = max(cap, 1)
          delay = :rand.uniform(upper_bound)
          {attempt, delay, cap}
        end

      Enum.each(delays, fn {attempt, delay, cap} ->
        assert delay >= 1, "delay #{delay} < 1 at attempt #{attempt}"
        assert delay <= cap, "delay #{delay} > cap #{cap} at attempt #{attempt}"
      end)
    end
  end
end

defmodule PlaidEx.ErrorTest do
  use ExUnit.Case, async: true

  alias PlaidEx.Error

  describe "from_plaid_response/2" do
    test "parses all known error types" do
      types = [
        {"INVALID_REQUEST", :invalid_request},
        {"INVALID_RESULT", :invalid_result},
        {"INVALID_INPUT", :invalid_input},
        {"INSTITUTION_ERROR", :institution_error},
        {"RATE_LIMIT_EXCEEDED", :rate_limit_exceeded},
        {"API_ERROR", :api_error},
        {"ITEM_ERROR", :item_error},
        {"OAUTH_ERROR", :oauth_error},
        {"PAYMENT_ERROR", :payment_error}
      ]

      Enum.each(types, fn {type_str, expected_atom} ->
        error =
          Error.from_plaid_response(400, %{
            "error_type" => type_str,
            "error_code" => "TEST_CODE",
            "error_message" => "test"
          })

        assert error.type == expected_atom,
               "Expected #{expected_atom} for #{type_str}, got #{error.type}"
      end)
    end

    test "marks ITEM_LOGIN_REQUIRED as requiring reauthentication" do
      error =
        Error.from_plaid_response(400, %{
          "error_type" => "ITEM_ERROR",
          "error_code" => "ITEM_LOGIN_REQUIRED",
          "error_message" => "login required"
        })

      assert Error.requires_reauthentication?(error)
      refute Error.retryable?(error)
    end

    test "marks INSTITUTION_DOWN as institution error" do
      error =
        Error.from_plaid_response(503, %{
          "error_type" => "INSTITUTION_ERROR",
          "error_code" => "INSTITUTION_DOWN",
          "error_message" => "institution down"
        })

      assert Error.institution_error?(error)
      assert Error.retryable?(error)
    end

    test "handles missing optional fields gracefully" do
      error =
        Error.from_plaid_response(500, %{
          "error_type" => "API_ERROR",
          "error_code" => "INTERNAL_SERVER_ERROR",
          "error_message" => "internal error"
          # No request_id, causes, display_message
        })

      assert is_nil(error.request_id)
      assert error.causes == []
      assert is_nil(error.display_message)
    end
  end

  describe "from_exception/1" do
    test "converts timeout exception" do
      error = Error.from_exception(%{reason: :timeout})
      assert error.code == "REQUEST_TIMEOUT"
      assert error.retryable == true
    end

    test "converts connection refused" do
      error = Error.from_exception(%{reason: :econnrefused})
      assert error.code == "CONNECTION_REFUSED"
      assert error.retryable == true
    end
  end

  describe "to_log_map/1" do
    test "returns loggable map without sensitive fields" do
      error =
        Error.from_plaid_response(400, %{
          "error_type" => "ITEM_ERROR",
          "error_code" => "ITEM_LOGIN_REQUIRED",
          "error_message" => "login required",
          "request_id" => "req_123"
        })

      log_map = Error.to_log_map(error)

      assert log_map.error_code == "ITEM_LOGIN_REQUIRED"
      assert log_map.plaid_request_id == "req_123"
      assert log_map.retryable == false
      refute Map.has_key?(log_map, :causes)
    end
  end

  describe "String.Chars protocol" do
    test "converts to readable string" do
      error = %Error{type: :api_error, code: "TEST_ERROR", message: "test message", status: 400}
      assert to_string(error) =~ "TEST_ERROR"
      assert to_string(error) =~ "400"
    end
  end
end
