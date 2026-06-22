# Doing: FRE-delight review follow-ups U38–U42

- **Branch:** `feat/fre-delight` (stay — do NOT push/package)
- **Source:** `docs/fre-ux-backlog.md` entries U38–U42 (review + live-hunt follow-ups)
- **Execution Mode:** direct
- **Artifacts:** `./docs/fre-delight-u38-u42/`
- **Status:** done

## Constraints

- Strict TDD per unit: failing test first (red), minimal code (green), commit.
- Build all first-party products (`OuroWorkbench`, `OuroWorkbenchMCP`, `OuroWorkbenchScenarioVerifier`) + `swift test` + `Scripts/check-coverage.sh` green before each commit closes.
- 100% line+region coverage on every `Sources/OuroWorkbenchCore/` file (coverage gate). New Core code must be fully covered.
- Commit per unit. NO Co-Authored-By, NO AI attribution. Match `git log` voice (descriptive present-tense subject, unit id in parens; no conventional-commit prefix for feature commits).
- Pre-existing `SwiftTermFuzz` strict-concurrency error in the dep is unrelated; ignore. First-party products + `swift test` build clean.

## Baseline (verified before start)

- `swift build` App/MCP/ScenarioVerifier: green.
- `swift test`: 1708 pass, 1 skipped, 0 fail.

## Units

### U38 ✅ Recovery trust-fix gate keys off a typed blocker, not planner prose
- **Problem:** `recoveryTrustFixAvailable(for:)` (App ~13265) gates the inline "Trust & resume" fix on `recoveryPlan(for:)?.reason == "entry is not trusted"` — exact prose match. If the planner reason is reworded the fix silently vanishes; nothing catches it.
- **Fix:** Add a typed blocker enum (`RecoveryBlocker`) to `RecoveryPlan` (Core). The planner tags the untrusted manual-recovery plan with `.untrusted`. App gate keys off the typed signal, not the prose.
- **Core test (red→green):** `RecoveryPlannerTests` — untrusted-trusted-needs-recovery entry yields a plan whose `blocker == .untrusted`; a manual-recovery plan from a different cause (e.g. lacks-session-id) does NOT carry `.untrusted`. A test that fails if the typed signal is dropped.
- **App wiring:** `recoveryTrustFixAvailable` keys off `recoveryPlan(for:)?.blocker == .untrusted` (still guarded by `manualRecoveryNeeded` + `trust != .trusted`).
- **Acceptance:** typed enum on the plan; planner sets it; App reads it; test fails if the typed signal is lost. Build+test+coverage green.

### U39 ✅ RecoveryDrill count routes through the shared digest
- **Problem:** `RecoveryDrill.run` (Core ~74) computes its own `actionableCount` (`.autoResume||.respawn||.manualActionNeeded`), diverging from the single `RecoveryDigest` every other surface uses.
- **Fix:** Add a pure `RecoveryDigest.needsActionCount` (actionable minus pure reattach = auto-recoverable + needs-you) and route the drill's count + `oneLineStatus` through `RecoveryDigest`. Same number as the boss-watch gate (U42) will use → one derivation.
- **Core test (red→green):** `RecoveryDigestTests` — `needsActionCount`/`hasNeedsAction` excludes `.reattach`, counts auto-resume/respawn/manual. `RecoveryDrillTests` — drill `oneLineStatus`/count for a mixed set (incl. a reattach) equals the digest's `needsActionCount`, not an independently-recomputed number.
- **Acceptance:** drill count == digest-derived needs-action count; no independent recompute. Build+test+coverage green.

### U40 ✅ Post-launch lastSummary reads as a plain sentence, not a plan reason
- **Problem:** `markStarted` (App ~17603) sets `lastSummary = TerminalCommandPlan.reason` — technical strings ("respawn X from persisted workbench context", "prepare X command for manual review") leak into operator status + boss prompt.
- **Fix:** Give `TerminalCommandPlan` a typed `kind` (`TerminalCommandPlanKind`) set at every construction site; add a pure `TerminalCommandPlanPhrasebook` mapping kind → plain operator sentence (precedent: `RecoveryReasonPhrasebook`). `markStarted` uses the plain sentence for `lastSummary`; raw `reason` stays for logs/disclosure.
- **Core test (red→green):** `TerminalCommandPlanPhrasebookTests` — total over all plan-kind cases, no jargon leak (banned: "respawn", "persisted", "manual review", "checkpoint recovery prompt", "native session metadata", "latest-session fallback"). Planner sets `kind` on every produced plan (assert in `CommandPlannerTests`).
- **App wiring:** `markStarted` → `entry.lastSummary = phrasebook.operatorSentence(for: plan.kind)`.
- **Acceptance:** typed kind on plan, pure mapping covering all cases, no jargon, raw reason preserved. Build+test+coverage green.

### U41 ✅ Readiness actuators stop rewriting the session status line
- **Problem:** `trustUntrustedAutonomyAgentTerminals` / `enableAutoResumeForAutonomyAgentTerminals` (App ~13358/13378) set `entry.lastSummary = "X trust set to trusted"` as a side-effect of a settings toggle — operator-visible + feeds boss prompt.
- **Fix:** Drop the `lastSummary` assignment from both actuators (the `recordActionLog` confirmation already lives in the right place — the action log, not the session status line). State change (trust/auto-resume) still happens.
- **Test (source-pin, App not coverage-gated):** add a Core-level guard where feasible; otherwise source-pin: assert via `RecoveryReadinessActuator` pure seam OR grep-pin that the actuators don't write `lastSummary`. Prefer extracting the mutation into a pure Core helper testable without the app, only if low-risk; else source-pin + manual reasoning. The trust/auto-resume flips remain.
- **Acceptance:** actuators no longer touch `lastSummary`; trust/auto-resume still flip; action-log confirmation retained. Build+test green.

### U42 ✅ Boss-watch wakes only on needs-action recovery (one derivation with U39)
- **Problem:** `bossWatchTick`'s `hasActionableState` (App ~12796) gates on raw `summary.needsRecovery.isEmpty`. Route it through the shared `RecoveryDigest` so all surfaces share one derivation; a pure-reconnect (reattach-only) workspace must not wake the boss.
- **Fix:** gate on `summary.recoveryDigest.hasNeedsAction` (the U39 property: auto-recoverable + needs-you, excluding pure reattach), consistent with the drill and the rest.
- **Test (red→green):** `RecoveryDigestTests` already covers `hasNeedsAction` from U39 (reattach-only → false; a real needs-action → true). Add an explicit predicate test pinning: reattach-only digest → `hasNeedsAction == false`; mixed-with-real-needs-action → true. App wiring switched to `recoveryDigest.hasNeedsAction`.
- **Acceptance:** gate predicate is the shared digest's needs-action signal; reattach-only not actionable; real needs-action actionable. Build+test+coverage green.

## Completion Criteria

- [x] U38 typed blocker on RecoveryPlan; planner sets it; App gates on it; test fails if dropped
- [x] U39 drill count == RecoveryDigest needs-action count (no independent recompute)
- [x] U40 TerminalCommandPlan typed kind + pure phrasebook; markStarted uses plain sentence; no jargon; raw reason preserved
- [x] U41 readiness actuators no longer rewrite lastSummary; state change retained
- [x] U42 boss-watch gate routes through shared digest needs-action signal
- [x] All 4 first-party products build clean
- [x] `swift test` green
- [x] `Scripts/check-coverage.sh` green (100% Core)
- [x] One commit per unit, voice matches `git log`, no AI attribution

## Progress log

- 2026-06-21 01:13 U38 complete (382ed21): added `RecoveryBlocker` enum + `blocker` field to `RecoveryPlan`; planner tags the untrusted manual-recovery plan `.untrusted`; App `recoveryTrustFixAvailable` keys off `blocker == .untrusted` not the prose. 3 new planner tests pin the typed signal (untrusted→.untrusted; missing-session-id→nil; recoverable→nil). 1711 tests pass, coverage gate PASS.
- 2026-06-21 01:14 U39 complete (9095453): added pure `RecoveryDigest.needsActionCount`/`hasNeedsAction`/`needsActionPlans` (auto-recoverable + needs-you, excludes lossless reattach); `RecoveryDrill` now routes its one-line count through it instead of recomputing. 5 new tests (3 digest needs-action, 1 drill-routes-through-digest, reuses existing). Coverage gate PASS.
- 2026-06-21 01:16 U40 complete (593a4c6): added typed `TerminalCommandPlanKind` (launch/reattach/resume/respawn/manualReview) + `kind` field on `TerminalCommandPlan` (set at every construction site); new pure `TerminalCommandPlanPhrasebook` maps kind→plain sentence (precedent RecoveryReasonPhrasebook). `markStarted` now sets `lastSummary` from the phrasebook; raw `reason` preserved (existing reason asserts unchanged). 7 new tests (5 phrasebook incl. total/no-jargon, 4 planner kind-pins). Coverage gate PASS.
- 2026-06-21 01:19 U41 complete (aac20f3): dropped the `entry.lastSummary = "...trust set to trusted"/"...auto-resume enabled"` side-effect from both readiness actuators; trust/auto-resume flips + `recordActionLog` confirmation remain. New `ReadinessActuatorStatusWiringTests` source-pins both actuators (App not coverage-gated, same pattern as BossForwardStatusWiringTests): state change kept, no `lastSummary` write, action log kept. Red→green confirmed. Coverage gate PASS.
