# F7 — honest headless-clone outcome

**Status:** in-progress
**Execution Mode:** direct
**Branch:** fix/f7-clone-honest-failure (no push/PR/merge)
**Artifacts:** ./2026-06-21-1730-doing-f7-clone-honest-failure/
**Spec:** /tmp/f7-design-spec.md

## The three honest-failure gaps (headless clone path)
1. Exit-0 = success lie: a headless `ouro clone` that only prints manual next-steps exits 0 →
   agent unauthenticated + not running → false "Cloned X".
2. Missing `agent.json` still "succeeds": clone flow never consults the bundle.
3. 120s watchdog kill mis-mapped to "Check the Git remote" (wrong cause for a wedge).

## House pattern to mirror
`ProviderConfigForm.classifyColdStart` + `VaultOnboardingMachine.afterVaultTerminal`: readiness
ONLY on positive probe; else fail safe with a specific reason. SAFETY INVARIANT: exit-0 alone is
NEVER `.ready` — requires `agentJsonPresent && checkVerdict == .working`.

## Units

- ✅ Unit 1a — Core seam TESTS (red). `CloneOutcomeClassifierTests`: every classify arm,
  `.timedOut != .cloneNonZeroExit` regression guard, exit-0+no-agent.json→invalid even with
  `.working`, ready-only-on-positive-probe arms, `CloneRunResult` helpers, `humanFacingLine` (only
  `.cloneNonZeroExit` has "Git remote"; no leak), `auditReason`, `CloneBundleLocator.agentJsonPath`.
- ✅ Unit 1b — Core seam IMPL (green). `CloneOutcomeClassifier.swift`: `CloneRunResult`,
  `CloneFailureReason`, `CloneOutcome`, `classifyClone`, `CloneBundleLocator`. `.timedOut` matched
  on the ENUM CASE before any `code==0` test. 100% Core coverage.
- ✅ Unit 2a — Watchdog TESTS (red). `ProcessWatchdogTests`: sleeper→true+terminated; fast→false.
- ✅ Unit 2b — Watchdog IMPL (green). `waitUntilExitReportingTimeout(_:timeoutSeconds:) -> Bool`,
  NSLock-guarded did-fire flag, additive (keep void `waitUntilExit`). Both branches covered.
- ✅ Unit 3a — Provider init TEST (red). `WorkbenchProvider(providerFlagValue:)` round-trips all 5
  cases + nil for unknown (B-4 resolution).
- ✅ Unit 3b — Provider init IMPL (green) + 100% Core coverage.
- ✅ Unit 4 — App wiring. `CloneAgentRunner.runHeadless` → `CloneRunResult` (no throw); delete
  `CloneFailedError`; update its one test → `.exited`. `cloneAgentHeadless` folds run + agent.json
  + probe via `classifyClone`; inspect bundle/probe ONLY on `.exited(code:0)`; `refreshOuroAgents()`
  always; `succeeded:true` gated behind `.ready` ONLY; `.needsVaultUnlock` resolves provider from
  cloned record lane → `beginCredentialRotation` (reuse F6) → returns `.failed(reason:)` while the
  terminal runs; `.failed` → honest line. New `runCloneProviderCheck(agentName:lane:)`.
- ✅ Unit 5 — Source-pin `CloneHonestWiringTests` (copy helper from `ColdStartHonestWiringTests`).

## Behavioral risks (defend with tests — source-pin is blind)
- B-1: watchdog-kill exit code == real git-failure. Test the RUNNER's timeout path with a REAL
  sleeper, not just the classifier.
- B-3: readiness leak on clean-but-unauth clone (original bug). Test exit-0+present+each of
  `.vaultLocked`/`.unauthorized`/`.unreachable`/`.indeterminate`/nil is NOT `.ready`.
- B-4: `needsVaultUnlock` provider resolution — read from cloned `agent.json` outward lane; degrade
  to `.couldNotConfirm` copy if absent.
- B-5: `needsVaultUnlock` reuses F6's vault markers; set `vaultOnboardingFlavor` before launch.

## Completion Criteria
- [x] Core `CloneOutcomeClassifier` seam + 100% line+region coverage
- [x] `waitUntilExitReportingTimeout` additive + both branches 100% covered, no allowlist entry
- [x] `WorkbenchProvider(providerFlagValue:)` for B-4 + 100% Core coverage
- [x] App wiring: runner returns `CloneRunResult`; classify fold; succeeded gated behind `.ready`
- [x] `.needsVaultUnlock` reuses `beginCredentialRotation` (no new clone vault-create)
- [x] Source-pin `CloneHonestWiringTests`
- [ ] `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` green
- [ ] `Scripts/check-coverage.sh` PASS, Core 100% line+region, no new allowlist entries
- [ ] Strict build clean

## Progress log
- 2026-06-21 17:56 Doing doc + artifacts dir committed.
- 2026-06-21 17:59 Unit 1a/1b complete: `CloneOutcomeClassifier.swift` seam — `CloneRunResult` (exited/timedOut/launchFailed + exitCode/watchdogTimedOut), `CloneFailureReason`, `CloneOutcome` (auditReason + humanFacingLine), `classifyClone` (`.timedOut` matched on the case BEFORE any code==0 test), `CloneBundleLocator`. 24 tests, Core 100%.
- 2026-06-21 18:03 Unit 2a/2b complete: `waitUntilExitReportingTimeout(_:timeoutSeconds:) -> Bool` additive (kept void `waitUntilExit`); NSLock-guarded did-fire flag; both branches covered (real sleeper→true+terminated, fast→false). B-1 structural defense.
- 2026-06-21 18:04 Unit 3a/3b complete: `WorkbenchProvider(providerFlagValue:)` failable init round-trips all 5 cases + nil for unknown/absent (B-4 provider resolution from cloned agent.json lane). Coverage PASS 100%, no new allowlist entries.
- 2026-06-21 18:08 Unit 5 (source-pin red) complete: `CloneHonestWiringTests` — 10/11 red against unmodified App (only refreshOuroAgents pre-existed). Helper block copied from ColdStartHonestWiringTests.
- 2026-06-21 18:14 Unit 4 (App wiring green) complete: `CloneAgentRunner.runHeadless` → `CloneRunResult` (no throw), `CloneFailedError` deleted, runner tests → `.exited`/`.launchFailed`. `cloneAgentHeadless` folds run + agent.json (gap #2, only on `.exited(code:0)`) + `runCloneProviderCheck` probe via `classifyClone`; `refreshOuroAgents()` always; `succeeded:true` behind `.ready` ONLY; `.needsVaultUnlock` resolves provider from cloned outward lane (B-4) → `beginCredentialRotation` (F6 reuse, B-5 flavor) and returns `.failed(reason:humanFacingLine)` while the terminal runs, degrading to `.couldNotConfirm` copy if provider unresolved; `.failed` → per-cause copy (no "Git remote" for timed-out/missing). Strict build clean, 49 clone tests green.
