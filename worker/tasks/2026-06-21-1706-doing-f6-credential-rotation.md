# F6 — existing-agent credential rotation + remove-agent

**Status:** done
**Execution Mode:** direct
**Branch:** fix/f6-credential-rotation (no push/PR/merge)
**Artifacts:** ./2026-06-21-1706-doing-f6-credential-rotation/

## The defect
`submitProviderConfig` short-circuits for an EXISTING agent (`OuroWorkbenchApp.swift` —
`providerConfigAgentAlreadyExists` branch → `existingAgentRefreshUnavailableMessage`): rotating a
credential on an already-created agent always errors. There is also NO remove-agent path.

## Hard constraint
NO non-interactive `ouro` credential-set path exists. F6 must NOT pretend to set credentials
silently. Mirror F13: drive the interactive recovery chain in a native Workbench Terminal (a real
TTY), re-probe, gate `.ready` on a positive `.working` re-probe (F1 safety invariant). When the
chain can't proceed, show an honest read-only credential status.

## Reuse F13's seam (`VaultOnboarding.swift`)
Reuse `VaultOnboardingMachine.afterVaultTerminal` (flavor-agnostic fold + F1 invariant) and the
`VaultOnboardingFailure` enum for rotation. Do NOT duplicate that fold. The rotation differs only
in (a) the command (unlock chain, not create) and (b) the human copy flavor.

## Units

- ✅ Unit 1 — Rotation command seam.
  `VaultOnboardingCommand.rotateCredentialCommandLine(agentName:providerFlag:)` building
  `ouro vault unlock --agent <n> && ouro auth --agent <n> --provider <p> && ouro provider refresh --agent <n>`
  (no `--email`; vault already exists). Quoted via `ShellArgumentEscaper`; literal ` && `.
- ✅ Unit 2 — Rotation human copy. Flavor-aware `humanLine` (onboarding vs rotation) covering every
  state, seam-free.
- ✅ Unit 3 — Remove-agent seam (pure). `AgentRemoval` decision value (delete on-disk bundle — the
  only honest removal since the roster is a filesystem scan of `~/AgentBundles/*.ouro`) +
  confirmation copy that plainly states the bundle is deleted.
- ✅ Unit 4 — App wiring. Replace the existing-agent short-circuit with the rotation flow (reuse
  F13's Terminal-run + re-probe wiring). Add a remove-agent action gated behind a confirmation that
  uses the seam's copy, then performs the deletion + updates the roster/selection/boss.

## Behavioral risks (defend with tests)
- (a) rotation re-probe MUST reuse F1's `.working` invariant — never `.ready` on a clean exit alone.
- (b) remove-agent must actually update the roster + not leave a dangling selection / boss / detail
  reference (the F5-class implicit-observer bug).
- (c) existing-vs-new detection at the short-circuit must only fire rotation for existing agents.

## Completion Criteria
- [x] Rotation command seam + 100% Core coverage
- [x] Rotation human copy, every state, seam-free + 100% Core coverage
- [x] Remove-agent seam (decision + confirmation copy) + 100% Core coverage
- [x] App wiring: short-circuit replaced by rotation; remove-agent behind confirmation
- [x] Source-pin tests for App wiring
- [x] `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` green
- [x] `Scripts/check-coverage.sh` PASS, Core 100% line+region, no new allowlist entries
- [x] Strict build clean

## Progress log
- 2026-06-21 17:08 Unit 1 complete: `rotateCredentialCommandLine` (unlock chain, no --email), 4 tests.
- 2026-06-21 17:10 Unit 2 complete: `VaultOnboardingFlavor` + flavor-aware `humanLine`; rotation copy seam-free for every state; 2-arg overload defaults to onboarding. 8 rotation tests + F13 suite green.
- 2026-06-21 17:14 Unit 3 complete: `AgentRemoval` seam — `decide` (delete on-disk bundle, uniform across status) + seam-free confirmation copy (permanent deletion; boss heads-up). 7 tests. Core coverage PASS 100%.
- 2026-06-21 17:24 Unit 4 complete: App wiring. Replaced existing-agent short-circuit → `beginCredentialRotation` (unlock chain in native `.trusted` terminal, reuses F13 markers + `completeVaultOnboarding` → single `afterVaultTerminal` fold, `.rotation` flavor). Added `removeAgent` (delete `.ouro` bundle, clear dangling selection/boss, refresh roster) behind a `confirmationDialog` using `AgentRemoval.confirmationCopy`. Removed obsolete `existingAgentRefreshUnavailableMessage` + updated 2 stale doc comments. 14 wiring tests.
- 2026-06-21 17:30 All gates passed: Gate 1 implementation-coverage (every unit committed + matches), Gate 2 full suite (2067 tests, 0 failures, 1 pre-existing skip) + strict build clean, Gate 3 PR review (rotation uses unlock chain not create; single fold; existing-agent-only; remove clears dangling state), Gate 4 finalize. Coverage PASS 100% line+region, no new allowlist entries.

## Behavioral-risk resolutions (defended)
- (a) Re-probe invariant reused, not re-implemented: rotation captures the SAME `vaultOnboarding*` markers so `markTerminated` → `completeVaultOnboarding` → `afterVaultTerminal` is the SAME single fold. `testCompletionFoldIsNotDuplicatedForRotation` pins exactly ONE `afterVaultTerminal` call site; `.ready` only on a positive `.working` verdict (clean exit alone is never ready).
- (b) No dangling reference after remove: `removeAgent` clears `selectedAgentName` when it pointed at the deleted agent, clears the boss name (so refresh auto-resolution re-adopts), clears `bossDashboard`, and calls `refreshOuroAgents()` to re-scan the filesystem roster. Detail pane is additionally guarded by `ouroAgent(named:)`. Pinned by `testRemoveAgentRefreshesTheRosterAfterDeleting` + `testRemoveAgentClearsDanglingSelectionAndBoss`.
- (c) Existing-vs-new detection: rotation fires only on `providerConfigAgentAlreadyExists`; a new-agent name is validated as a non-collision upstream (sheet `submit()`), so it never reaches the rotation branch. `.coldStartHatch` (new-agent) path left intact — pinned by `testNewAgentPathStillColdStartHatches`.
