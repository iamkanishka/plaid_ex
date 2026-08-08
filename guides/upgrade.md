# Upgrade Guide

## Versioning policy

PlaidEx follows [Semantic Versioning](https://semver.org):

- **Patch** (`0.1.x`) — bug fixes, no API changes
- **Minor** (`0.x.0`) — new features, backwards-compatible API additions
- **Major** (`x.0.0`) — breaking changes (rare, announced in advance)

Breaking changes include:
- Removing or renaming public functions
- Changing function signatures (adding required parameters)
- Changing struct field names
- Changing telemetry event names/shapes
- Dropping Elixir/OTP version support

Non-breaking changes include:
- Adding new optional parameters (keyword list opts)
- Adding new struct fields
- Adding new telemetry events
- Adding new API modules
- Adding new error codes to the classifier

## Migrating from other Plaid Elixir libraries

### From `plaid` (hex package by Tyler Young)

```elixir
# Before
{:ok, %{"accounts" => accounts}} = Plaid.Accounts.get("access-...")

# After
{:ok, %{accounts: accounts}} = PlaidEx.API.Accounts.get(config, "access-...")
# accounts is now [%PlaidEx.Schemas.Account{}] — typed structs
```

Key differences:

1. **Typed structs** — all responses are typed structs, not raw maps
2. **Explicit config** — pass a `PlaidEx.Config` struct to every API call
3. **Error structs** — errors are `%PlaidEx.Error{}` with retry metadata
4. **No global state** — config is passed explicitly, enabling multi-tenant
5. **OTP application** — starts its own supervision tree

Migration script:

```elixir
# 1. Replace in mix.exs:
# {:plaid, "~> 2.0"} → {:plaid_ex, "~> 0.1"}

# 2. Add config:
config :plaid_ex,
  client_id: System.fetch_env!("PLAID_CLIENT_ID"),
  secret: System.fetch_env!("PLAID_SECRET"),
  environment: :sandbox

# 3. Update API calls — pattern:
# Plaid.Product.action(params)
# → PlaidEx.API.Product.action(config, params)

# 4. Update error handling:
# {:error, %Plaid.Error{}} → {:error, %PlaidEx.Error{}}

# 5. If using transactions, migrate to sync:
# Plaid.Transactions.get(...) → PlaidEx.start_transaction_sync(...)
```

### Capability comparison

| Feature | `plaid` library | PlaidEx |
|---------|----------------|---------|
| API coverage | Partial | Complete |
| Typed schemas | No (raw maps) | Yes (typed structs) |
| Retry logic | Basic | Full jitter + classification |
| Circuit breakers | No | Per-environment GenServer |
| Transaction sync | Manual | Supervised workers |
| Webhooks | None | Full orchestration |
| Multi-tenant | No | Yes |
| Telemetry | None | 14 events |
| OpenTelemetry | None | Full spans |
| OAuth flows | Basic | Complete with PKCE |
| Testing helpers | None | Bypass + Mox + fixtures |

## Upgrading PlaidEx versions

### 0.1.x patch releases

Patch releases are safe to apply without code changes:

```elixir
# mix.exs
{:plaid_ex, "~> 0.1"}  # auto-upgrades within 0.1.x
```

### Minor version upgrades (0.x.0)

Minor releases add new features. Review the CHANGELOG for new capabilities.
Existing code will continue to work unchanged.

```bash
mix hex.outdated plaid_ex
mix deps.update plaid_ex
mix test
```

### Major version upgrades (x.0.0)

Major releases include breaking changes. A migration guide will be published
with each major release. Expect:
- Schema field renames documented in CHANGELOG
- Deprecated function removals (deprecated for at least one minor version first)
- Configuration option renames

## Plaid API version updates

PlaidEx pins to Plaid API version `2020-09-14`. When Plaid releases a new
API version and deprecates the current one:

1. We will release a new PlaidEx minor version with the updated API version
2. The old version will continue to work until Plaid sunsets it
3. Migration notes will be in the CHANGELOG

To check which Plaid API version PlaidEx is using:

```elixir
PlaidEx.Config.api_version()
# => "2020-09-14"
```

## Deprecation policy

When we deprecate a function:

1. We add `@deprecated` with migration instructions
2. The function remains for at least one minor release
3. It's removed in the next major release

Example deprecated function:

```elixir
@deprecated "Use PlaidEx.API.Transactions.sync/2 instead"
def get_transactions(access_token, opts), do: ...
```

You'll see Elixir compiler warnings when using deprecated functions.
Search your codebase for these warnings before each major upgrade.

## Changelog

See [CHANGELOG.md](../CHANGELOG.md) for the complete version history.

## Getting help

- GitHub Issues: https://github.com/iamkanishka/plaid_ex/issues
- HexDocs: https://hexdocs.pm/plaid_ex
- Plaid Docs: https://plaid.com/docs/
