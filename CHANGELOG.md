# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.0.0] - 2026-08-08

### Added

**Core infrastructure**
- `PlaidEx.Config` — NimbleOptions-validated configuration with runtime injection support
- `PlaidEx.HTTP.Client` — Req + Finch HTTP client with full jitter backoff, idempotency, and OpenTelemetry spans
- `PlaidEx.HTTP.RateLimiter` — ETS token bucket rate limiter with per-tenant isolation
- `PlaidEx.Error` — Typed error struct with retry classification, reauthentication detection, and telemetry-safe serialization

**API coverage**
- `PlaidEx.API.Link` — Link token create/get/list
- `PlaidEx.API.Items` — Token exchange, item get/remove/webhook update, processor token creation
- `PlaidEx.API.Accounts` — Account get, balance get
- `PlaidEx.API.Transactions` — Sync (cursor-based), get (legacy), recurring, enrich, refresh
- `PlaidEx.API.Auth` — Auth get
- `PlaidEx.API.Identity` — Identity get, match
- `PlaidEx.API.Investments` — Holdings get, transactions get, refresh
- `PlaidEx.API.Liabilities` — Liabilities get
- `PlaidEx.API.Transfer` — Authorize, create, get, cancel, list, event list, event sync
- `PlaidEx.API.Signal` — Evaluate, decision report, return report, prepare
- `PlaidEx.API.Institutions` — Get by ID, list, search
- `PlaidEx.API.Assets` — Create, get, get PDF, remove, filter, create audit copy
- `PlaidEx.API.Income` — Create verification, get summary, get payroll
- `PlaidEx.API.Statements` — List, download, refresh
- `PlaidEx.API.Beacon` — Create/get/review user, create/list reports
- `PlaidEx.API.Monitor` — Individual and entity watchlist screening
- `PlaidEx.API.Processor` — Auth, identity, balance, Stripe bank account token
- `PlaidEx.API.Sandbox` — Public token, fire webhook, reset login, simulate transfers

**Reliability**
- `PlaidEx.Reliability.CircuitBreaker` — Per-environment GenServer circuit breaker with :closed/:open/:half_open states
- `PlaidEx.Reliability.CircuitBreakerSupervisor` — DynamicSupervisor managing circuit breakers
- `PlaidEx.Reliability.Bulkhead` — Bounded process pool isolation per product area

**Transaction sync**
- `PlaidEx.Sync.TransactionSync` — Durable cursor-based sync worker with OTP supervision
- `PlaidEx.Sync.SyncSupervisor` — DynamicSupervisor for per-item sync workers
- `PlaidEx.Sync.CursorStore` — ETS cursor store with pluggable backend behaviour
- `PlaidEx.Sync.BroadwayPipeline` — Broadway integration for high-throughput multi-item sync

**Webhooks**
- `PlaidEx.Webhooks.Plug` — Phoenix Plug with signature verification, deduplication, async dispatch
- `PlaidEx.Webhooks.Verifier` — HMAC-SHA256 and JWT webhook verification
- `PlaidEx.Webhooks.Dispatcher` — Typed event routing to handler callbacks
- `PlaidEx.Webhooks.Deduplicator` — ETS sliding window deduplication
- `PlaidEx.Webhooks.Handler` — Behaviour + `use` macro with default no-op implementations
- `PlaidEx.Webhooks.ObanWorker` — Oban-backed durable webhook processing
- `PlaidEx.Webhooks.Schemas` — Typed structs for all 20+ webhook event types

**Multi-tenant**
- `PlaidEx.Config.TenantRegistry` — ETS-backed runtime credential store with secret rotation
- `PlaidEx.MultiTenant.TenantSupervisor` — DynamicSupervisor for per-tenant process subtrees
- `PlaidEx.MultiTenant.Tenant` — Per-tenant GenServer with isolated rate limiting

**OAuth**
- `PlaidEx.OAuth.PKCE` — PKCE code_verifier/challenge generation (S256 method)
- `PlaidEx.OAuth.StateStore` — ETS OAuth state store with TTL and single-use consumption
- `PlaidEx.OAuth.Flow` — High-level OAuth flow orchestration

**Schemas**
- Typed structs for: Account, Transaction, TransactionSyncPage, Item, Institution, Transfer, LinkToken, AccessToken, InvestmentHolding, Security, IdentityData

**Observability**
- `PlaidEx.Telemetry.Handler` — Structured logging for all 14 telemetry events
- `PlaidEx.Telemetry.Metrics` — Telemetry.Metrics definitions (histograms, counters, sums)
- `PlaidEx.Telemetry.OpenTelemetry` — OpenTelemetry span wrappers

**Testing**
- `PlaidEx.Test.BypassHelpers` — Bypass stubs for all major endpoints with realistic fixtures
- `PlaidEx.Test.MockPlaidServer` — Full mock Plaid server for integration testing
- `PlaidEx.Test.MockPlaidServer.build_webhook/3` — Typed webhook payload builders
- `PlaidEx.Test.MockPlaidServer.build_signed_webhook/2` — HMAC-signed webhook builder

**CI/CD**
- GitHub Actions workflow with matrix testing (Elixir 1.17/1.18, OTP 27/28)
- Automatic Hex.pm publishing on git tag
- Dialyzer PLT caching
- ExCoveralls integration

### Changed
- N/A (initial release)

### Deprecated
- N/A (initial release)

### Removed
- N/A (initial release)

### Fixed
- N/A (initial release)

### Security
- Webhook secrets are never logged (scrubbed in telemetry metadata)
- Access tokens are masked in log output (only first 20 chars shown)
- Config.scrub/1 redacts secrets for safe logging

## Upgrade Guide

### From `plaid` (the other Elixir Plaid library)

```elixir
# Before (plaid library):
{:ok, %{"accounts" => accounts}} = Plaid.Accounts.get("access-...")

# After (plaid_ex):
{:ok, %{accounts: accounts}} = PlaidEx.API.Accounts.get(config, "access-...")
# accounts is now [%PlaidEx.Schemas.Account{}] — typed structs
```

Key differences:
1. **Typed structs** — responses are typed structs, not raw maps
2. **Explicit config** — pass a `PlaidEx.Config` struct (enables multi-tenant)
3. **Error structs** — errors are `PlaidEx.Error` structs with retry metadata
4. **Automatic sync** — use `PlaidEx.start_transaction_sync/2` instead of manual polling

[Unreleased]: https://github.com/iamkanishka/plaid_ex/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/iamkanishka/plaid_ex/releases/tag/v1.0.0
