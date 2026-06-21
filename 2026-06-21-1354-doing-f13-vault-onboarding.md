# F13 — In-app vault onboarding (cold-start credential persistence recovery)

Status: in-progress
Execution Mode: direct
Branch: fix/f13-vault-onboarding
Base: main @ 9764b1f (F1 + F2 + F3)
Artifacts: ./f13-vault-onboarding/

## Goal

After F1, a fresh agent's headless `ouro hatch` writes the bundle but the vault step
throws (it needs a TTY secret), so `classifyColdStart` returns `.needsVaultSetup` and the
form says "<name> was created, but its provider isn't connected yet — Workbench will help
you finish setup." **F13 IS that "help you finish setup."**

## The CRUX (locked by design investigation)

The provider credential the user typed is **gone and un-replayable** (ephemeral argv to a
finished `ouro hatch`; re-running hatch hard-errors "bundle already exists"; `ouro auth`
re-prompts AND needs the vault first). So F13 **cannot persist silently** — it re-collects
the credential by running the CLI's documented recovery chain in a **native Workbench
terminal (a real TTY)**:

```
ouro vault create --agent <name> --email <name>@ouro.bot && ouro auth --agent <name> --provider <p> && ouro provider refresh --agent <name>
```

The user enters the unlock secret (twice) + re-enters the provider credential in that
terminal. Then Workbench re-probes and, on `.working`, hands back to F1's `.ready` path.

**SAFETY INVARIANT (mirror F1):** NEVER `.ready` unless the re-probe positively returns
`.working`. Exit 0 alone is not ready (the chain can exit 0 with a wedged daemon).

## Scope (v1)

ONLY the `.needsVaultSetup` recovery path. NO Copilot-primary path, NO existing-agent
credential-refresh (separate follow-ups). Do NOT change `ouro` itself.

## Locked decisions (verified against source)

- Core seams live in new `Sources/OuroWorkbenchCore/VaultOnboarding.swift` — pure, 100%
  line+region via `scripts/check-coverage.sh`, **no allowlist entry**.
- `ColdStartOutcome` = `.ready | .needsVaultSetup | .failed(reason: ColdStartFailureReason)`
  (verified `ProviderConfigForm.swift:386`). `ColdStartFailureReason` = `.hatchLaunchError
  | .hatchNonZeroExit | .couldNotConfirm` (verified `:370`).
- `ProviderConnectionVerdict` = `working | vaultLocked | unauthorized | unreachable |
  indeterminate` (verified `ProviderCheckClassifier.swift:5`).
- `ShellArgumentEscaper.quote` leaves `[A-Za-z0-9-_./:=@%+]` unquoted, single-quotes
  otherwise (verified `:3`). `@` is safe → `ouroboros@ouro.bot` stays unquoted. Build the
  command line by quoting each ARGUMENT and joining with literal ` && ` between the three
  `ouro` invocations (never quote `&&`).
- App source-pin tests mirror `ColdStartHonestWiringTests` (private `appSource`/`repoRoot`/
  `sourceSlice` helpers per file). Verified that's the standing convention.
- `WorkbenchProvider.providerFlagValue` is the `--provider` value (verified `:20`).

## Units

### Unit 0 — Doc + artifacts scaffold ✅ (done)
What: Write this doing doc, create artifacts dir, confirm branch + base + identity.
Output: doing doc committed; `f13-vault-onboarding/` exists.
Acceptance: on `fix/f13-vault-onboarding` off `9764b1f`; identity `ari@mendelow.me`.

### Unit 1a — Core seam TESTS (red) ✅
What: New `Tests/OuroWorkbenchCoreTests/VaultOnboardingTests.swift` covering the FULL table:
- `shouldOffer`: `.needsVaultSetup`→true; `.ready`/`.failed(.hatchNonZeroExit)`/
  `.failed(.couldNotConfirm)`→false.
- `afterVaultTerminal`: `nil`→`.failed(.vaultCommandLaunchError)`; `1`→
  `.failed(.vaultCommandNonZeroExit)`; `130`→`.failed(.vaultCommandNonZeroExit)`;
  `0`+`.working`→`.ready`; `0`+`.vaultLocked`→`.failed(.stillNotConnected)`;
  `0`+`.unauthorized`→`.failed(.stillNotConnected)`; `0`+`.unreachable`→
  `.failed(.couldNotConfirm)`; `0`+`.indeterminate`→`.failed(.couldNotConfirm)`;
  `0`+`nil`→`.failed(.couldNotConfirm)`.
- `finishSetupCommandLine`: `("ouroboros","anthropic",nil)`→exact string
  `ouro vault create --agent ouroboros --email ouroboros@ouro.bot && ouro auth --agent ouroboros --provider anthropic && ouro provider refresh --agent ouroboros`;
  explicit email used verbatim; shell-significant chars in the agent name quoted.
- `humanLine`: a line for every state; **seam-free** (asserts NO `ouro`/`vault`/`hatch`/`--`
  leak); names the agent.
Output: tests compile and FAIL (no `VaultOnboarding.swift` yet).
Acceptance: `swift test` shows VaultOnboarding tests failing to build/red.

### Unit 1b — Core seam IMPLEMENTATION (green) ✅
What: New `Sources/OuroWorkbenchCore/VaultOnboarding.swift` with `VaultOnboardingState`,
`VaultOnboardingFailure`, `VaultOnboardingMachine` (`shouldOffer`, `afterVaultTerminal`,
`humanLine`), `VaultOnboardingCommand.finishSetupCommandLine`. Minimal code to pass 1a.
Output: tests pass; `swift build` clean; no warnings.
Acceptance: `swift test` green; build clean.

### Unit 1c — Core coverage VERIFY ✅
What: `scripts/check-coverage.sh` → `VaultOnboarding.swift` 100% line+region, NO allowlist
entry. Add edge tests if any region uncovered.
Output: coverage gate passes naming VaultOnboarding.swift at 100%.
Acceptance: check-coverage.sh PASS; no allowlist line for VaultOnboarding.swift.

### Unit 2a — App stash-the-provider TESTS (red) ✅
What: Extend the App source-pin suite (new `VaultOnboardingWiringTests.swift`, mirror
`ColdStartHonestWiringTests`). Pin: the `.coldStartHatch` outcome switch has a DEDICATED
`.needsVaultSetup` arm (NOT shared with `.failed`) that sets `providerConfigNeedsVaultSetup
= true` and stashes the provider into `providerConfigColdStartProvider`. Pin the two new
`@Published` declarations exist.
Output: tests FAIL (wiring not present yet).
Acceptance: new wiring tests red.

### Unit 2b — App stash-the-provider IMPL (green) ✅
What: Add `@Published var providerConfigColdStartProvider: WorkbenchProvider?` and
`@Published var providerConfigNeedsVaultSetup = false`. SPLIT the shared
`case .needsVaultSetup, .failed:` so only `.needsVaultSetup` sets the flag + stashes the
provider. Keep F1's existing `.needsVaultSetup` human-line + readiness refresh behavior.
Output: tests green; `swift build` clean.
Acceptance: build clean; 2a green; existing F1 ColdStart wiring tests still green.

### Unit 3a — beginVaultOnboarding TESTS (red) ✅
What: Pin `beginVaultOnboarding()` exists; builds the chained command via
`VaultOnboardingCommand.finishSetupCommandLine`; opens a native terminal via
`createCustomSession(` with `launchAfterCreate: true`; uses a `.trusted` trust draft;
captures the new entry id + runId for exit matching. Pin the "Finish setup" affordance in
`ProviderConfigSheet` is shown only when `providerConfigNeedsVaultSetup` and calls
`beginVaultOnboarding()`.
Output: tests FAIL.
Acceptance: red.

### Unit 3b — beginVaultOnboarding IMPL (green) ⬜
What: Implement `beginVaultOnboarding()` + the "Finish setup" affordance. Build the draft
(name "Finish setup: <name>", command = chain, workingDirectory = home, trust `.trusted`),
call `createCustomSession(_:launchAfterCreate:true)`, stash the onboarding entry id + runId.
Output: tests green; build clean.
Acceptance: 3a green; build clean.

### Unit 4a — completeVaultOnboarding TESTS (red) ✅
What: Pin `markTerminated(entryId:runId:rawStatus:)` calls `completeVaultOnboarding(`
when the terminated entry/runId match the onboarding session, decoding via
`ProcessExitStatus(rawWaitStatus:).exitCode`. Pin `completeVaultOnboarding(vaultExitCode:)`
re-probes via `runColdStartProviderCheck(` when exit==0, folds via
`VaultOnboardingMachine.afterVaultTerminal(`, gates `.ready` on the machine result, reuses
F1's `.ready` side-effects (`runFirstRunBootstrap()`, `succeeded: true` log,
`isProviderConfigPresented = false`), and on `.failed` keeps `providerConfigNeedsVaultSetup`
true (retry) + surfaces `humanLine` + refreshes readiness.
Output: tests FAIL.
Acceptance: red.

### Unit 4b — completeVaultOnboarding IMPL (green) + termination-model decision ⬜
What: Implement exit detection in `markTerminated` (decide + DOCUMENT the one-shot-terminal
termination model: normal vs `detachedPersistentSession` — launch non-persistent or hook
both branches; re-probe is authoritative regardless). Implement
`completeVaultOnboarding(vaultExitCode:)` per 4a. Refresh inventory/readiness; optionally
archive the one-shot terminal on success.
Output: tests green; full `swift test` green; `swift build` clean; no warnings.
Acceptance: 4a green; whole suite green; build clean; termination decision recorded in
artifacts.

### Unit 5 — Full verify + gates ⬜
What: Full `swift test` (strict), `scripts/check-coverage.sh` (VaultOnboarding 100%, no
allowlist), strict build clean. Implementation-coverage gate (every unit's code committed),
PR-review gate vs locked decisions. Sync Completion Criteria.
Output: all gates pass; doc Status=done.
Acceptance: see Completion Criteria.

## Completion Criteria

- [ ] `Sources/OuroWorkbenchCore/VaultOnboarding.swift` exists with the four public seams.
- [ ] `VaultOnboarding.swift` is 100% line+region via `scripts/check-coverage.sh`, NO
      allowlist entry.
- [ ] `afterVaultTerminal` never returns `.ready` except for `0`+`.working` (safety invariant).
- [ ] `finishSetupCommandLine` emits the exact documented chain; email defaults to
      `<name>@ouro.bot`; explicit email used verbatim; args shell-quoted via
      `ShellArgumentEscaper`.
- [ ] `humanLine` is seam-free (no `ouro`/`vault`/`hatch`/`--` leak) for every state.
- [ ] App: `.needsVaultSetup` arm split from `.failed`; sets `providerConfigNeedsVaultSetup`
      + stashes `providerConfigColdStartProvider`.
- [ ] App: "Finish setup" affordance shown only when `providerConfigNeedsVaultSetup`; calls
      `beginVaultOnboarding()`.
- [ ] App: `beginVaultOnboarding()` builds the chain via `VaultOnboardingCommand` and opens
      a native `.trusted` terminal via `createCustomSession(_:launchAfterCreate:true)`.
- [ ] App: `markTerminated` detects the onboarding session's exit and calls
      `completeVaultOnboarding(vaultExitCode:)`; one-shot-terminal termination model decided
      + documented.
- [ ] App: `completeVaultOnboarding` re-probes via `runColdStartProviderCheck`, folds via
      `afterVaultTerminal`, gates `.ready` on the machine, reuses F1's `.ready` side-effects,
      keeps "Finish setup" for retry on `.failed`.
- [ ] Full `swift test` green (strict); strict `swift build` clean; no warnings.
- [ ] Only F13 files committed (`git add <paths>`, never `-A`); untracked leftovers ignored.

## Progress Log

- 2026-06-21 13:55 Unit 0 complete: doing doc + artifacts dir on fix/f13-vault-onboarding off 9764b1f; identity ari@mendelow.me.
- 2026-06-21 13:57 Unit 1a complete: VaultOnboardingTests.swift (12 tests) written; red confirmed (missing VaultOnboarding symbols).
- 2026-06-21 14:00 Unit 1b complete: VaultOnboarding.swift implemented; 12 tests green; full suite 1975 green; build clean. Test note: the seam-free `humanLine` check strips the agent name before scanning (the canonical name "ouroboros" contains substring "ouro"); the check still catches real CLI/vault vocabulary leaks. This is a test-quality fix (false-positive substring collision), not an implementation accommodation — the copy is genuinely seam-free.
