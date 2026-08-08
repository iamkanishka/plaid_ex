defmodule PlaidEx.Telemetry.OpenTelemetry do
  @moduledoc """
  OpenTelemetry span wrappers for distributed tracing.

  Automatically propagates trace context across async operations
  (webhook dispatch, sync workers) using OpenTelemetry's context API.

  ## Setup

      # Add to deps:
      {:opentelemetry, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.7"},

      # In config.exs:
      config :opentelemetry,
        resource: [service: [name: "my-plaid-app"]],
        span_processor: :batch,
        traces_exporter: :otlp
  """

  # Safe to require unconditionally — expands to no-op macros when dep absent
  require OpenTelemetry.Tracer

  @doc """
  Wraps a function in an OpenTelemetry span.
  No-op if opentelemetry_api is not in deps.
  """
  @spec with_span(String.t(), map(), (-> result)) :: result when result: term()
  def with_span(name, attributes \\ %{}, fun) do
    if Code.ensure_loaded?(OpenTelemetry.Tracer) do
      OpenTelemetry.Tracer.with_span name, %{attributes: attributes} do
        fun.()
      end
    else
      fun.()
    end
  end

  @doc """
  Creates a span for a Plaid API call.
  """
  @spec api_span(String.t(), String.t(), PlaidEx.Config.t(), (-> result)) :: result
        when result: term()
  def api_span(product, endpoint, config, fun) do
    attrs = %{
      "plaid.product" => product,
      "plaid.endpoint" => endpoint,
      "plaid.environment" => to_string(config.environment),
      "plaid.region" => to_string(config.region),
      "plaid.tenant_id" => config.tenant_id || ""
    }

    if Code.ensure_loaded?(OpenTelemetry.Tracer) do
      OpenTelemetry.Tracer.with_span "plaid.\#{product}.\#{endpoint}", %{
        kind: :client,
        attributes: attrs
      } do
        fun.()
      end
    else
      fun.()
    end
  end

  @doc """
  Captures a Plaid error as an OpenTelemetry span event. No-op without opentelemetry_api.
  """
  @spec record_error(PlaidEx.Error.t()) :: :ok
  def record_error(%PlaidEx.Error{} = error) do
    if Code.ensure_loaded?(OpenTelemetry.Tracer) do
      OpenTelemetry.Tracer.set_status(:error, error.message)

      OpenTelemetry.Tracer.add_event("plaid.error", %{
        "plaid.error.code" => error.code,
        "plaid.error.type" => to_string(error.type),
        "plaid.error.status" => error.status,
        "plaid.request_id" => error.request_id || ""
      })
    end

    :ok
  end
end
