# Doing: F12a — degraded-mode honesty (gaps 1, 2, 3, 5)

- Branch: `fix/f12a-degraded-mode-honesty` (off F8b-merged main `680d8a7`)
- Execution Mode: direct
- Planning: `/tmp/f12-design-spec.md` (PR A = F12a = gaps 1, 2, 3, 5)
- Artifacts: `./f12a-degraded-mode-honesty/`
- Status: in progress
- Constraints: strict TDD (red→green per gap); commit on branch; NO push/PR/merge.
  No Co-Authored-By, no attribution. `git add` only files I change (ignore
  `SerpentGuide.ouro/`, `*-doing-*.md` leftovers). Pin App wiring BY SYMBOL.

## Gaps (each its own Core seam + thin source-pinned App wiring)

### Gap 1 — `save()` fail → `action_result` lies "unknown"  ✅ (9276459)
- Core: extend `WorkbenchActionResultClassifier.readback` with `isApplied: Bool`;
  new state `.appliedUnconfirmed` ("Applied; detailed outcome unavailable (state
  save failed).", succeeded:true). Precedence: stillQueued → .queued; logEntry →
  .applied/.failed; isApplied → .appliedUnconfirmed; else .unknown.
- App (MCP): `actionResult(arguments:)` adds `isApplied =
  queue.appliedRequestIds().contains(uuid)`, threads through readback; update
  tool description.
- Tests: `WorkbenchActionResultTests` (new arms); `MCPActionResultWiringTests`
  (source-pin appliedRequestIds() threaded into readback).
- Risk: `.appliedUnconfirmed` DISTINCT, never plain `.applied`; ledger read in
  MCP wiring not hardcoded.

### Gap 2 — missing `screen` → "exited 127" dead-end  ⬜
- Core: new `TerminalExitDiagnosis.swift` — `screenWrappedExit(exitCode:Int32?,
  screenHealth:ExecutableHealthStatus) -> String?` (phrasebook idiom). 4 arms:
  non-127→nil; 127+.missing→reinstall; 127+.notExecutable→reinstall; 127+.available
  →PATH hint. REUSE `ExecutableHealthChecker`.
- App: `launchPreflightProblem` — when `plan.persistentSessionName != nil`,
  `health(for: PersistentTerminalSession.executable)`; missing/notExecutable →
  screen-specific problem BEFORE spawn. `markTerminated` 127 backstop renders
  `TerminalExitDiagnosis` instead of "exited with code 127".
- GATE strictly on `plan.persistentSessionName != nil` (cold-start/provider probes
  spawn ouro/gh DIRECTLY — don't misattribute their 127).
- Tests: `TerminalExitDiagnosisTests` (4 arms); `ScreenPreflightWiringTests`.
- NOTE (flag, don't fix): SwiftTerm `LocalProcess.swift:399-406` `#if false` dead
  re-decode path — if SwiftTerm upgrades, revisit ProcessExitStatus.

### Gap 3 — boss prose overwritten + un-triaged waiting  ⬜
- 3a Core: add `proseLog: [BossProseEntry] = []` to `WorkspaceState` (additive
  Codable, NO schemaVersion bump); `BossProseEntry {id,occurredAt,source,
  text(.prefix(4000))}`; `recordProse` newest-first cap(50).
- 3a App: check-in SUCCESS path (after `bossCheckInAnswer = answer`) recordProse +
  save when non-empty/non-error.
- 3b Core: new `WaitingSessionReconciler.untriagedWaitingEntryIds(entries:openInbox:)
  -> [UUID]` (.waitingOnHuman whose id not in Set(openInbox.compactMap(\.entryId))).
- 3b App: after recordBossDecisions + on startup (after load), synthesize an
  escalate `BossInboxDecision` per id via `recordDecisionIfNew` + save.
- Tests: `WorkspaceStateProseLogTests`, `WaitingSessionReconcilerTests`,
  `BossProseHistoryWiringTests`, `WaitingReconcileWiringTests`.
- Risk: new save() calls respect `isLoadingState`/`isResettingToFirstRun`
  suppressions (already gated in save()); route 3b through `recordDecisionIfNew`
  (dedup, no inbox flooding); cap prose text + log at 50.

### Gap 5 — respawn bare positional → Copilot dead-ends  ⬜
- Core: `TerminalCommandPlan` gains `enum CheckpointPromptDelivery {positional;
  sendAfterLaunch(String)}` + `checkpointPromptDelivery`. Pure
  `CheckpointPromptDeliveryResolver.delivery(for: TerminalAgentKind?)` (Copilot→
  sendAfterLaunch, NOT appended; generic→positional; non-checkpointPrompt→nil…).
  `recoveryPlan(.respawn)` keys delivery off resolver.
- App: `TerminalSessionController` — AFTER the session reaches INTERACTIVE
  (first-output post-start signal), if `.sendAfterLaunch(text)` send via sendInput.
- Tests: `CheckpointPromptDeliveryResolverTests`; update `CommandPlannerTests`
  (Copilot assertion MOVES from arguments.last to checkpointPromptDelivery);
  `CheckpointPromptDeliveryWiringTests`.
- Risk: gate sendAfterLaunch on interactivity (not onStarted); don't regress the
  generic-TUI positional path.

## Verify before reporting
- `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` green
- `Scripts/check-coverage.sh` PASS, Core 100% line+region, NO new allowlist
- Strict build clean

## Progress log
- 2026-06-22 01:35 fresh start; spec + all seams read; doing doc written
- 2026-06-22 01:43 Gap 1 complete (9276459): Core readback + isApplied/.appliedUnconfirmed
  (RED→GREEN), MCP wiring threads queue.appliedRequestIds(), tool desc updated;
  strict build clean; 11 Core arms + 3 source-pins green.
