# F13 — one-shot recovery terminal: termination model decision

## Question (from the prompt's "VERIFY EARLY")

Does the one-shot finish-setup terminal (running `ouro vault create && ouro auth &&
ouro provider refresh`) terminate NORMALLY, or route through the `detachedPersistentSession`
branch of `markTerminated`? If it's a persistent screen session, either launch it
non-persistent OR hook both branches.

## How I verified

Read the launch path end-to-end in source (not assumed):

1. `createCustomSession(draft, launchAfterCreate: true)` → `launch(entry)` →
   `start(entry, with: plan)` where `plan = WorkbenchCommandPlanner.launchPlan(for: entry)`.
2. `WorkbenchCommandPlanner.launchPlan` (`Sources/OuroWorkbenchCore/CommandPlanner.swift:216-236`)
   sets `persistentSessionName: PersistentTerminalSession.sessionName(for: entry.id)`
   **UNCONDITIONALLY** — every launched custom session gets a persistent screen-session name.
   There is no draft flag that opts out; `autoResume` does not affect this.
3. `TerminalLaunchInvocation(plan:)` (`CommandPlanner.swift:73-95`): when
   `persistentSessionName != nil` (always, per #2), the actual invocation is
   `screen … attachOrCreate <sessionName> -- <direct command>`. So the recovery chain runs
   **inside a `screen` wrapper**.
4. `markTerminated` (`OuroWorkbenchApp.swift`) computes:
   ```
   detachedPersistentSession = isCurrentSession && !manuallyTerminated
       && currentPlan?.persistentSessionName.map(persistentSessionIsListed) == true
   ```
   `persistentSessionIsListed` shells out to `screen -ls` and checks whether a session with
   that name is **still alive at terminate time**.

## Conclusion: it can route through EITHER branch

The routing is **not** a fixed property of the session — it depends on whether the `screen`
session is still alive when the local terminal client's process ends:

- **Happy path (chain completes):** the user enters the unlock secret + provider credential,
  all three `ouro` commands run, the wrapped command exits, the `screen` session ends →
  `persistentSessionIsListed` returns **false** → **normal branch** → the real exit code is
  decoded and recorded.
- **User closes the pane mid-run:** the local client ends while `screen` is still detached and
  the chain is still running → `persistentSessionIsListed` returns **true** → **detached-
  persistent branch** → status `.needsRecovery`, **no exit code recorded** (`exitCode = nil`).

## Decision: HOOK BOTH BRANCHES, gate `.ready` on the re-probe

I did NOT try to force the session non-persistent (there's no clean opt-out seam, and changing
the universal launch path would risk every other session's recovery behavior — out of scope and
riskier than hooking both branches). Instead, `markTerminated` recognizes the onboarding session
by `entryId == vaultOnboardingEntryID && runId == vaultOnboardingRunID` and calls
`completeVaultOnboarding(vaultExitCode:)` in BOTH branches:

- Normal branch: `completeVaultOnboarding(vaultExitCode: status.exitCode)` — the real decoded exit.
- Detached branch: `completeVaultOnboarding(vaultExitCode: 0)` — the chain DID launch and no
  non-zero failure was observed (the session is merely still detached), so the decision falls
  ENTIRELY to the re-probe. Passing `0` (not `nil`) is deliberate: `nil` would map to
  `.vaultCommandLaunchError` (wrong — it launched), while `0` defers to the re-probe, which can
  only return `.ready` on a real `.working` verdict.

**The re-probe is authoritative regardless of branch.** This honors the F1 safety invariant:
`VaultOnboardingMachine.afterVaultTerminal` never returns `.ready` unless
`runColdStartProviderCheck` positively returns `.working`. Even if exit-detection is fuzzy
(detached branch), `.ready` is gated on the probe — never on a bare exit.

## Residual risk (queued for operator drive-through)

- **Manual cancel OR signal-kill mid-recovery:** `status.exitCode` is `nil` in two cases — a
  manual stop (`markTerminated(…, rawStatus: nil)`, `manuallyTerminated = true`) AND a
  signal-killed process (`ProcessExitStatus.decodeExitCode` returns `nil` when the low 7 bits of
  the raw wait status are non-zero, i.e. terminated by signal). Either yields
  `completeVaultOnboarding(vaultExitCode: nil)` → `.vaultCommandLaunchError`. The human copy
  ("couldn't open the setup window… try again") is slightly off for a deliberate cancel /
  crash-after-launch, but the outcome is correct: a retryable failure with the finish-setup
  affordance still available. Acceptable for v1.
- The live end-to-end UX (click Finish setup → terminal opens → enter secret + credential →
  agent goes working) is **not drive-verifiable in this harness** — it needs a real TTY, a real
  `ouro` daemon, and human secret entry. Queue an operator drive-through.
