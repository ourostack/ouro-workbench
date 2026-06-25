# SU0 review gate (anneal P5 — ≥2 adversarial reviewers; first product-source change)

Two fresh, no-inherited-context adversarial reviewers ran against commit `9d18e16`
(the SU0 init-param clock seam). Build-lock discipline: one BUILD reviewer (ran
the strict suite + a source negative-control), one STATIC-only reviewer.

## Reviewer 1 — STATIC-only → VERDICT: SAFE (zero findings)
Verified all three sites are semantically identical to prod when `now == nil`:
- pill body `:3795`: `now ?? context.date` → `context.date` (was `context.date`).
- inbox body `:2173`: `content(now: now ?? context.date)` → `context.date`.
- a11y label `:3731`: `now ?? Date()` → `Date()` — AND the `coarseDescription`
  shim's own default `now: Date = Date()` (`:3810`) is UNCHANGED by the commit,
  so this is the same single live `Date()` read as before.
TimelineView(.periodic) retained at `:2172` + `:3794`; the `:3731` computed-String
label is reachable ONLY by the init-param (no `@Environment` on `TerminalAgentRow`,
and a computed `String` property can't read an env value); all prod call sites
(`:441`, `:3016`) take the `nil` default and compile unchanged. No determinism leak.

## Reviewer 2 — BUILD → VERDICT: SAFE for prod behavior; 1 HIGH test-quality defect
**Prod behavior unchanged — verified by a source negative-control:** the reviewer
replaced both `?? context.date`/`?? Date()` fallbacks with a fixed date and
confirmed (then reverted byte-identically) that the committed fallbacks genuinely
point at the live clock — the live app keeps ticking. Periodic drivers retained at
both sites; strict build clean (0 warn, 9/9 tests pass); `Sendable` value-type
property — no concurrency issue; no call-site breakage.

**HIGH (RESOLVED):** the original "load-bearing" tests
(`testSeamIsLoadBearing_injectedDiffersFromLiveDefault`,
`testProductionDefault_usesLiveClock_pill/_accessibilityLabel`) were NOT actually
load-bearing. The reviewer PROVED it: mutating the prod default to a fixed PAST
sentinel (`now ?? Date(timeIntervalSince1970: 1_700_000_000)`, 2023) — the most
natural prod-default-is-live regression — left ALL 9 tests passing. Root cause:
the fixtures started the row at `Date()` (~now), so a past sentinel gives
`now(2023) − start(2026) < 0`, clamped by `WorkbenchElapsedFormatter`'s `max(0,…)`
to `"0s"` — indistinguishable from a live just-started row. The assertions only
excluded a far-FUTURE default, not a hardcoded PAST one.

### Fix applied (this commit)
Strengthened all three tests to start the row ~2h IN THE PAST and assert the LIVE
default renders `"2h"` (and explicitly NOT `"0s"`) — a value a past-fixed-date
sentinel default CANNOT produce (it clamps to `"0s"`). **Proof the fence is now
load-bearing:** re-applied the reviewer's exact past-sentinel mutation to all three
prod-default sites → the three tests now FAIL (5 assertion failures); reverted the
mutation byte-identically → all 9 pass. The product source is byte-for-byte the
committed `9d18e16` source; only the test file changed.

## Disposition
Zero surviving CRITICAL/HIGH. Both reviewers SAFE on production behavior; the one
HIGH (test-quality) is fixed and proven. SU0 review gate PASSED.
