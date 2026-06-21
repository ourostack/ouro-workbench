# Doing: F3 — Boss autonomy kill-switch bypass (P0 SECURITY/TRUST)

Execution Mode: direct
Branch: fix/f3-autonomy-chokepoint
Artifacts: ./f3-autonomy-chokepoint/
Status: done

## The bug
`BossWorkbenchActionAuthorizer.authorize(_:for:livePrompt:)` gates only archived/trust/safety-floor.
It NEVER consults the auto-advance kill-switch (`bossAutoAdvanceEnabled`) or per-friend trust. The
actions/MCP `sendInput` channel reaches `authorize` but never `evaluateAutoAdvanceGate`, so the boss
can inject keystrokes even when the operator turned the kill-switch OFF or the friend is untrusted.

## Fix
Fold a pure injection gate INTO the authorizer (single chokepoint). Thread an OPTIONAL
`autoAdvanceContext` (default nil → fail-closed for sendInput) through `authorize` so every channel
inherits it. App wires real context at the apply call site. MCP-enqueue passes no context → nil →
fail-closed deny for sendInput at enqueue (app-apply is authoritative).

## Units

### Unit 0a (test): Core seam — `evaluateBossInjectionGate` + `BossAutoAdvanceContext` + `injectsLiveInput`
- ✅ Wrote failing tests (BossInjectionGateTests, 7 tests) — red on missing types
- Acceptance: gate returns .allow for non-injecting kinds (nil ctx); fail-closed denies for sendInput

### Unit 0b (impl): Core seam types + function
- ✅ Added `BossAutoAdvanceContext`, `injectsLiveInput`, `BossInjectionGate`, `evaluateBossInjectionGate`
- Acceptance: 0a tests green (7/7); Core builds clean

### Unit 1a (test): authorizer integration — T1..T9
- ✅ Added T1 (CANARY), T2..T7, T9 to BossWorkbenchActionAuthorizerTests (red — missing param)
- Acceptance: T1 RED before impl; all green after — CONFIRMED via surgical canary (gate removed → T1 red → restored → green)

### Unit 1b (impl): thread `autoAdvanceContext` through `authorize`/`gate`/`resolvedEntry`; apply gate
- ✅ Optional param (default nil) on all 3 front doors; gate invoked after safety floor
- ✅ 3 legacy ALLOW-path tests updated to supply clearing context (reviewer-confirmed verdict (a); intents preserved)
- Acceptance: 49/49 green (42 authorizer + 7 gate); Core builds clean

### Unit 2a (test): app source-pin wiring
- ✅ BossInjectionGateWiringTests source-pins applyBossAction builds context + passes it (red before wiring)
- Acceptance: RED before wiring — confirmed

### Unit 2b (impl): wire context at app apply call site
- ✅ Built machineOwner/effectiveFriend/context, passed to authorize as autoAdvanceContext
- Acceptance: 2a green; full package build clean (App recompiled, no warnings)

### Unit 3 (verify): R4 + coverage + strict build
- ✅ R4: confirmed no operator manual sendInput routes through applyBossAction — see finding below
- ✅ `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` green: 1940 tests, 1 skipped, 0 failures, 0 warnings
- ✅ `Scripts/check-coverage.sh` PASS; BossWorkbenchActionAuthorizer.swift 51/51 regions, 125/125 lines = 100%; NO allowlist entry added (only 3 pre-existing unrelated exclusions)
- ✅ T1 bypass closed: surgical canary (gate removed → T1 RED → restored → GREEN)

### R4 finding
`applyBossAction` has exactly TWO callers, both carrying agent/external provenance:
- `applyBossActions(from:)` :15525 → source `boss:<agentName>` (boss-watch channel)
- `applyExternalActionRequests` :15770 → source `external:<request.source>` (MCP-enqueued)
The operator's OWN manual input goes through `sendInput(_:to:appendNewline:)` :15996, which
writes straight to `session.sendInput` and NEVER touches `applyBossAction` or the authorizer.
Its only two callers are (a) the auto-advance decisions path (already gated by
`evaluateAutoAdvanceGate`) and (b) `applyBossAction`'s `.sendInput` case AFTER the authorize
gate passed, plus genuine terminal-view UI. So NO operator-initiated path is subject to the F3
gate. The gate is correctly scoped to boss/external injection only — no operator input is
silently gated. No exemption needed.

## Completion Criteria
- [x] T1 (bypass) provably closed (surgical canary: gate removed → RED → restored → GREEN)
- [x] All T1..T9 pass; legacy tests updated only to new contract (3 ALLOW-path tests, reviewer-confirmed)
- [x] Core seam 100% line+region (BossWorkbenchActionAuthorizer.swift 51/51 regions, 125/125 lines); no allowlist addition
- [x] strict-concurrency build clean, warnings-as-errors (1940 tests, 0 failures, 0 warnings)
- [x] R4 finding reported (no operator path through applyBossAction; no exemption needed)

## Progress Log

- 2026-06-21 12:54 Unit 0a/0b complete: BossInjectionGate core seam (types + pure gate), 7 gate tests green, Core builds clean. Commits f4e6fc9 (test), 5104f96 (impl).
- 2026-06-21 13:01 Unit 1a/1b complete: F3 gate folded into authorize() after safety floor; threaded autoAdvanceContext (default nil, fail-closed) through authorize/resolvedEntry/gate. T1 canary proven: gate removed → T1 RED ("bypass: kill-switch-off sendInput must be DENIED") → restored → GREEN. 49/49 tests green. 3 legacy ALLOW-path tests updated to clearing context (reviewer-confirmed (a)). Commits de180e2 (test), ee04f59 (impl).
- 2026-06-21 13:04 Unit 2a/2b complete: source-pin wiring test (red→green); applyBossAction now builds BossAutoAdvanceContext(bossAutoAdvanceEnabled, effectiveFriend) and passes it to authorize. Full package build clean (App recompiled, 0 warnings). Commits 25079fe (test), 5b05090 (impl).
- 2026-06-21 13:09 ALL UNITS COMPLETE. Gates passed: implementation coverage ✅ (9 commits, all units committed + matching descriptions) | strict test suite ✅ (1940 tests, 0 failures, 0 warnings, warnings-as-errors + strict-concurrency=complete) | coverage ✅ (authorizer 100% line+region, no allowlist add) | PR review ✅ (matches spec: single chokepoint, additive to safety floor, fail-closed nil, MCP enqueue untouched) | strict build ✅. T1 bypass PROVABLY CLOSED. R4 clean. Status: done.
