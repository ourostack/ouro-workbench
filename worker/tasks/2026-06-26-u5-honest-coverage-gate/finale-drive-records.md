# U5 finale — combined-PR driving records (the views the B-series missed)

Closing the per-file-100% gate on `WorkbenchViews.swift` surfaced category-(b) un-driven
ORDINARY arms the B1–B10 / B4-redo batches never reached (they live inside parents the
C-series didn't drive, and were `private` so no direct test could construct them). These
are DRIVEN here (promote private->internal + a direct test), NOT carved — padding the
allowlist with them would have been dishonest.

Each promotion is prod-byte-identical (pure presentation; same module). Subprocess-spawning
taps (repairAgent / trustAndRecover -> recover -> start()) use the #332 `launchTerminalSession`
no-op so no `screen` child orphans.

| view | promoted | regions driven | test |
|---|---|---|---|
| SessionAttentionBanner | yes | body + 3 `state`-switch arms + both `offersJumpToPrompt` arms + Jump action | SessionAttentionBannerTests |
| AgentActionsCard | yes | 4 bundle-action buttons (openConfig/revealBundle/createAnother/clone); "Run ouro check" CARVED — live-subprocess, already driven via AgentTitleStripInteractionTests | AgentCardActionsDriveTests |
| AgentLanesCard | yes | Edit-agent.json button | AgentCardActionsDriveTests |
| NeedsYouEntryRow | yes | Trust&resume arm + Start-fresh arm + onJump | NeedsYouEntryRowDriveTests |
| SessionStatusRowView | yes | row-select Button + `.done`/nil-exitCode + `.running`/nil-pid detailLine fallbacks | SessionStatusRowViewDriveTests |
| HarnessActionRow | yes | `if isBusy { ProgressView }` TRUE arm + action (+ negative control) | HarnessActionRowAndBossChoiceDriveTests |
| OnboardingBossChoiceRow | yes | boss-pick Button action (registerWorkbenchForBossChoice) | HarnessActionRowAndBossChoiceDriveTests |

## Carves that survived the audit (NOT driveable — kept in the allowlist)

- ProviderConfigSheet non-secret-field `else` arm (`:6207`) + `.onChange(of: provider)`:
  the `@State provider` has NO init seam and ViewInspector's `Picker.select` cannot reach
  the post-change render (per ProviderConfigSheetInteractionTests). @State-no-init-seam carve.
- HeaderView "Open Workspace…" -> `presentOpenWorkspacePanel()` is a modal `NSOpenPanel().runModal()`
  (modal-NSOpenPanel carve); "Stop All Running…" is `.disabled(activeSessions.isEmpty)` and
  enabling needs a live PTY (live-PTY carve; the disabled gate itself IS covered).
- OnboardingReadinessView "Optional checks" branch — structurally DEAD by the AN-006 invariant
  (`isReady <=> repairSteps.isEmpty`), asserted by `testE4_AN006_readyImpliesEmptyRepairSteps`.
- OuroAgentRowView removal-confirmation `Binding.set` — invoked only on dialog dismiss, no driver.
- MarkdownMessageView `inline()` `return Text(string)` — the `AttributedString(markdown:)`
  throw fallback; lenient inline parsing never throws → unreachable error path.
- The K1 dossier AppKit/scene shells (WorkbenchRootView Scene/.commands, WorkbenchMenuBarController
  NSMenu, LoginItemController SMAppService, SessionDetailView live-PTY, BossDashboardView showsAdvanced,
  AutonomyStatusButton/Popover, AboutSheet build-hash, WindowChromeConfigurator NSWindow) — see
  residual-baseline.md THE FORK.

## Second orphan-subprocess class (#332 audit found it; the original brief only flagged gh/diagnostics)

Recover/Launch/repairAgent taps drive a detached `Task { await start(entry:with:) } -> session.start()`
which forks a real `screen` via `LocalProcessTerminalView.startProcess`. Under an in-process
ViewInspector tap that child outlived the test -> CI signal-1 teardown crash. Seamed with an
injectable `launchTerminalSession` closure (default `{ $0.start() }`, prod byte-identical);
the 5 affected interaction tests inject a no-op.
