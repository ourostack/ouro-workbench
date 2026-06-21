# Doing: F3 — Boss autonomy kill-switch bypass (P0 SECURITY/TRUST)

Execution Mode: direct
Branch: fix/f3-autonomy-chokepoint
Artifacts: ./f3-autonomy-chokepoint/

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
- ⬜ Add T1 (CANARY, red on HEAD), T2, T3, T4, T5, T6, T7, T9 to BossWorkbenchActionAuthorizerTests
- Acceptance: T1 RED before impl; all green after

### Unit 1b (impl): thread `autoAdvanceContext` through `authorize`/`gate`/`resolvedEntry`; apply gate
- ⬜ Add optional param (default nil) to the three front doors; invoke gate after safety floor
- Acceptance: 1a tests green; legacy tests unchanged; build clean

### Unit 2a (test): app source-pin wiring
- ⬜ Source-pin test asserting `applyBossAction` builds `BossAutoAdvanceContext` from
  `bossAutoAdvanceEnabled` + `effectiveFriend` and passes it to `authorize`
- Acceptance: RED before wiring

### Unit 2b (impl): wire context at app apply call site (:16628)
- ⬜ Build machineOwner/effectiveFriend/context, pass to authorize
- Acceptance: 2a green; build clean

### Unit 3 (verify): R4 + coverage + strict build
- ⬜ Confirm no operator manual sendInput routes through applyBossAction (R4)
- ⬜ `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` green
- ⬜ `Scripts/check-coverage.sh` PASS, new Core seam 100%, no allowlist entry
- ⬜ Confirm T1 closes the bypass (stash → red → unstash → green)

## Completion Criteria
- [ ] T1 (bypass) provably closed
- [ ] All T1..T9 pass; legacy tests unchanged
- [ ] Core seam 100% line+region; no allowlist addition
- [ ] strict-concurrency build clean, warnings-as-errors
- [ ] R4 finding reported

## Progress Log

- 2026-06-21 12:54 Unit 0a/0b complete: BossInjectionGate core seam (types + pure gate), 7 gate tests green, Core builds clean. Commits f4e6fc9 (test), 5104f96 (impl).
