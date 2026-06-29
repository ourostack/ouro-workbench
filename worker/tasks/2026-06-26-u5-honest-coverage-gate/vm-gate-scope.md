# VM-GATE campaign — STEP 1 scoping measurement

**Goal:** extend the honest per-file-100% line+region coverage gate to
`Sources/OuroWorkbenchAppViews/WorkbenchViewModel.swift` (10,969 lines — the ungated other half
of the U5 split), driven to its irreducible floor like WorkbenchViews.swift was (379→227).

## CI-measured residual (the honest scope — not a guess)

Wired the VM file into `COVERAGE_DIRS` (no allowlist), pushed (PR #356, scope-only), read the
Coverage job (run 28344709476):

> **`WorkbenchViewModel.swift` — 44.0% line / 40.7% region — `5892 lines / 1696 regions` uncovered.**

(For comparison, WorkbenchViews.swift started at 1729 lines / 379 regions. The VM is ~4.5× the
region residual — a large, but overwhelmingly DRIVABLE, file.)

## Clustered breakdown (4612 fully-uncovered source lines attributed to 308 decls)

By per-decl category (machinery SIGNAL in the decl body vs pure logic):

| category | decls | uncov lines | disposition |
|---|---|---|---|
| **logic** (state transitions, action handlers, dispatch, parsing, formatting, orchestration) | 258 | **3321** | DRIVABLE — direct calls / function-extraction / init-seams |
| **machinery-touching** (a function that contains a subprocess/NSApp/live-PTY line) | 55 | 1242 | MOSTLY DRIVABLE — the LOGIC drives via a closure-injection seam; only the literal syscall line carves |
| **async-loop** (`.task` / `while !Task.isCancelled` / `Task.sleep`) | 5 | 49 | mostly genuine-carve (no ViewInspector/.task driver) |

**By-LINE content classification of all uncovered lines:**
- **GENUINE-machinery syscall lines** (literal `Process()`/`.run()`/`.waitUntilExit()`/`Pipe()`/
  `FileHandle`, `NSApp.terminate`/`NSWorkspace.open`/`NSPasteboard`, `TerminalSessionController.start()`/
  `TerminalPane`, `Task.detached`/`Task.sleep`/`asyncAfter`, `kill`/`signal`): **~107 lines.**
- **LOGIC/other lines** (state, parsing, dispatch, formatting, braces): **~4505 lines.**

So the genuine-carve machinery is a SMALL minority (~107 lines / a handful of regions); the
overwhelming bulk is drivable business logic — exactly the WorkbenchViews shape, at larger scale.

## Top DRIVABLE clusters (the per-PR drive targets)

```
315  L7600  applyBossAction         — boss-action validate/dedup/authorize/dispatch (pure)
147  L5870  performCommand          — command-palette dispatch (mostly pure; a few seam points)
 94  L8031  submitProviderConfig    — provider-config form apply (logic + a hatch-argv seam)
 71  L8314  completeVaultOnboarding — vault onboarding state transition (logic)
 59  L4604  installReleaseUpdate    — release-update orchestration (logic + stager seam)
 57  L5479  runOnboardingProviderCheck — provider-check orchestration (logic + process seam)
 54  L8684  completeFirstRunBootstrap  — first-run bootstrap completion (logic)
 52  L8169  beginVaultOnboarding    — vault onboarding kickoff (logic)
 43  L4895  submitBugReport         — bug-report assembly (logic + diagnostics/keyWindow seams)
 40  L4794  collectSupportDiagnostics — diagnostics runner orchestration (logic + runner seam)
 38  L9587  applyAttentionSignal    — attention-state transition (pure)
 37  L3812  runBossWatchTick        — boss-watch tick logic (logic; the loop is the carve)
… (258 logic decls total)
```

## Genuine-carve machinery (the floor — same classes as WorkbenchViews)

- live-PTY `TerminalSessionController.start()` / `TerminalPane` NSViewRepresentable (the D3 class)
- literal subprocess syscalls: `Process().run()` / `.waitUntilExit()` / `Pipe()` / `FileHandle`
  reads (provider-check, login-shell-PATH, screen-ls, support-diagnostics) — driven UP TO the
  syscall via the existing closure seams; only the literal line carves
- `NSApp.terminate(nil)` (prepareForTermination), `NSWorkspace.shared.open`, `NSPasteboard`
- `.task` infinite poll loops (`runBossWatchLoop` `while !Task.isCancelled` + `Task.sleep`)
- llvm-synthesized autoclosure/resume-epilogue artifacts (the flaky-region protocol class)

## Existing injection seams already in the VM (proven drive-points for the machinery functions)

```
makeSupportDiagnosticsRunner (L674)   launchTerminalSession (L687)
chooseWorkspaceOpenURL (L696)         chooseWorkspaceSaveURL (L704)
fileGitHubIssue (L648)
```
These prove the closure-injection pattern is already established in this file; the drive extends
it (e.g. a provider-check-result seam, a screen-lister seam) where needed.

## Plan (STEP 2 — per-cluster PRs, after coordinator sees this scope)

Sequence by cluster, biggest-drivable-first: boss-action dispatch (applyBossAction +
applyExternalActionRequests + the action handlers) → command dispatch (performCommand) →
onboarding/vault/provider-config flows → release-update/bug-report/diagnostics (seam the I/O) →
attention/notification/parsing helpers → the remaining tail. Each PR: invoked + effect-asserted +
mutation-verified; allowlist set to CI-measured exact minimum (probe-then-set + count-1); scope-pure;
VERSION bump; merge on CI-green. Carve ONLY the ~107 genuine-machinery lines + async-loops +
llvm-synth artifacts — NO padding.
