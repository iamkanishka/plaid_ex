defmodule PlaidEx.MixProject do
  use Mix.Project

  @version "1.0.0"
  @source_url "https://github.com/iamkanishka/plaid_ex"

  def project do
    [
      app: :plaid_ex,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      dialyzer: dialyzer(),
      test_coverage: [tool: ExCoveralls],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.github": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :crypto, :public_key],
      mod: {PlaidEx.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # ─── HTTP ───────────────────────────────────────────────────────────────
      {:req, "~> 0.5"},
      {:finch, "~> 0.19"},

      # ─── JSON ───────────────────────────────────────────────────────────────
      {:jason, "~> 1.4"},

      # ─── Validation / Options ───────────────────────────────────────────────
      {:nimble_options, "~> 1.1"},

      # ─── Observability ──────────────────────────────────────────────────────
      {:telemetry, "~> 1.2"},
      {:telemetry_metrics, "~> 1.0"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_semantic_conventions, "~> 1.0"},

      # ─── Caching (optional) ─────────────────────────────────────────────────
      {:nebulex, "~> 2.6", optional: true},
      {:cachex, "~> 3.6", optional: true},

      # ─── Background jobs (optional) ─────────────────────────────────────────
      {:oban, "~> 2.18", optional: true},

      # ─── Streaming (optional) ───────────────────────────────────────────────
      {:broadway, "~> 1.1", optional: true},
      {:gen_stage, "~> 1.2", optional: true},

      # ─── Phoenix (optional) ─────────────────────────────────────────────────
      {:plug, "~> 1.16", optional: true},

      # ─── Dev tooling ────────────────────────────────────────────────────────
      {:ex_doc, "~> 0.35", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test, runtime: false},

      # ─── Test infrastructure ─────────────────────────────────────────────────
      {:bypass, "~> 2.1", only: :test},
      {:mox, "~> 1.2", only: :test},
      {:stream_data, "~> 1.1", only: [:dev, :test]},

      # ─── Code generation ─────────────────────────────────────────────────────
      {:yaml_elixir, "~> 2.9", only: [:dev, :test]}
    ]
  end

  defp description do
    """
    Production-grade Plaid API client for Elixir/OTP. Full API coverage,
    typed schemas, resilient HTTP with circuit breakers, webhook orchestration,
    cursor-based transaction sync pipelines, multi-tenant support, and deep
    OpenTelemetry observability. Built for enterprise fintech systems.
    """
  end

  defp package do
    [
      name: "plaid_ex",
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md",
        "Plaid Docs" => "https://plaid.com/docs/",
        "Plaid API Reference" => "https://plaid.com/docs/api/"
      },
      files: ~w(lib config mix.exs README.md CHANGELOG.md LICENSE .formatter.exs)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      source_url: @source_url,
      extras: [
        "README.md",
        "CHANGELOG.md",
        "guides/getting_started.md",
        "guides/configuration.md",
        "guides/multi_tenant.md",
        "guides/webhooks.md",
        "guides/transaction_sync.md",
        "guides/oauth_flows.md",
        "guides/observability.md",
        "guides/testing.md",
        "guides/production.md",
        "guides/upgrade.md",
        "LICENSE"
      ],
      groups_for_extras: [
        Guides: ~r/guides\//
      ],
      groups_for_modules: [
        "Public API": [
          PlaidEx,
          PlaidEx.API.Link,
          PlaidEx.API.Items,
          PlaidEx.API.Accounts,
          PlaidEx.API.Transactions,
          PlaidEx.API.Auth,
          PlaidEx.API.Identity,
          PlaidEx.API.Balance,
          PlaidEx.API.Investments,
          PlaidEx.API.Liabilities,
          PlaidEx.API.Transfer,
          PlaidEx.API.Signal,
          PlaidEx.API.Beacon,
          PlaidEx.API.Enrich,
          PlaidEx.API.Income,
          PlaidEx.API.Assets,
          PlaidEx.API.Statements,
          PlaidEx.API.Institutions,
          PlaidEx.API.Monitor,
          PlaidEx.API.Processor,
          PlaidEx.API.Sandbox,
          PlaidEx.API.Wallet,
          PlaidEx.API.CreditReport,
          PlaidEx.API.User
        ],
        Webhooks: [
          PlaidEx.Webhooks.Plug,
          PlaidEx.Webhooks.Router,
          PlaidEx.Webhooks.Dispatcher,
          PlaidEx.Webhooks.Verifier,
          PlaidEx.Webhooks.Deduplicator
        ],
        "Sync Pipelines": [
          PlaidEx.Sync.TransactionSync,
          PlaidEx.Sync.SyncSupervisor,
          PlaidEx.Sync.CursorStore,
          PlaidEx.Sync.BroadwayPipeline
        ],
        "Multi-Tenant": [
          PlaidEx.MultiTenant.Tenant,
          PlaidEx.MultiTenant.TenantSupervisor,
          PlaidEx.MultiTenant.TenantRegistry
        ],
        OAuth: [
          PlaidEx.OAuth.Flow,
          PlaidEx.OAuth.PKCE,
          PlaidEx.OAuth.StateStore
        ],
        Reliability: [
          PlaidEx.Reliability.CircuitBreaker,
          PlaidEx.Reliability.CircuitBreakerSupervisor,
          PlaidEx.Reliability.Retry,
          PlaidEx.Reliability.Bulkhead
        ],
        Observability: [
          PlaidEx.Telemetry.Handler,
          PlaidEx.Telemetry.Metrics,
          PlaidEx.Telemetry.OpenTelemetry
        ],
        Schemas: ~r/PlaidEx\.Schemas/,
        Configuration: [PlaidEx.Config]
      ],
      before_closing_head_tag: &before_closing_head_tag/1
    ]
  end

  defp before_closing_head_tag(:html) do
    """
    <style>
      .sidebar-listItem a[href$="PlaidEx.html"] { font-weight: 600; }
    </style>
    """
  end

  defp before_closing_head_tag(_), do: ""

  defp aliases do
    [
      "plaid.gen": ["plaid.gen.client"],
      test: ["test --trace"],
      check: [
        "format --check-formatted",
        "credo --strict",
        "dialyzer --quiet"
      ],
      "check.all": [
        "format --check-formatted",
        "credo --strict",
        "dialyzer --quiet",
        "test"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/dialyzer.plt"},
      plt_add_apps: [:mix, :ex_unit, :crypto, :public_key],
      flags: [
        :unmatched_returns,
        :error_handling,
        :no_return,
        :underspecs
      ],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end
end
