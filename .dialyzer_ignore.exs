# Dialyzer ignore patterns for PlaidEx.
#
# Entries here address false positives that can't be scoped with a
# function-level `@dialyzer {:nowarn_function, ...}` attribute at the
# source (module-level or narrower attributes should always be preferred
# over an entry here — see PlaidEx.HTTP.Client for an example of the
# preferred, scoped approach).
#
# 1. `Req.post/1` return type — Dialyzer cannot fully trace through
#    Req's internal dispatch to determine `{:ok, Req.Response.t()}` is
#    always the reachable success type. This is suppressed at the source
#    via `@dialyzer {:nowarn_function, [post: 4, execute: 1]}` in
#    `PlaidEx.HTTP.Client` — the one module that calls `Req.post/1`
#    directly. All other modules call `Client.post/4`, which now carries
#    an accurate `@spec`, so the warning should not need to cascade
#    further. No blanket pattern for this is kept here; if a genuine
#    "no local return" surfaces elsewhere, add a scoped
#    `{:nowarn_function, {module, function, arity}}` tuple for that
#    specific site rather than reintroducing a broad match.
#
# 2. Optional dependencies (Broadway, GenStage, Oban, OpenTelemetry,
#    Nebulex, Cachex) introduce conditionally-compiled code paths
#    (`if Code.ensure_loaded?(Dep) do ... end`) that Dialyzer analyzes
#    against whichever combination of optional deps happens to be
#    present in the PLT. Because the set of warnings this produces
#    depends on that combination, these stay as scoped regexes rather
#    than per-function tuples.
#
# 3. `NimbleOptions` — runtime option-schema validation; types aren't
#    statically traceable through it.
#
# 4. `PlaidEx.Sync.TransactionSync.State` — internal GenServer state
#    struct whose shape is refined at runtime during the sync
#    lifecycle; kept as a scoped, module-specific pattern.
#
# Format: list of {warning_type, {module, function, arity}} tuples,
# or ~r/regex/ patterns matched against the warning string. Prefer the
# tuple form (or an in-source `@dialyzer` attribute) whenever the exact
# module/function/arity is known — it's far less likely to accidentally
# swallow an unrelated, genuine warning than a bare string/regex match.

[
  # ── Optional dependencies ────────────────────────────────────────────────────
  ~r/opentelemetry/i,
  ~r/OpenTelemetry/,
  ~r/Broadway/,
  ~r/GenStage/,
  ~r/Oban/,
  ~r/Nebulex/,
  ~r/Cachex/,

  # ── NimbleOptions ────────────────────────────────────────────────────────────
  # Runtime validation — types not statically traceable
  ~r/NimbleOptions/,

  # ── Broadway macro-generated code ────────────────────────────────────────────
  ~r/BroadwayPipeline\.Producer/,

  # ── Sync State struct ────────────────────────────────────────────────────────
  ~r/PlaidEx\.Sync\.TransactionSync\.State/
]
