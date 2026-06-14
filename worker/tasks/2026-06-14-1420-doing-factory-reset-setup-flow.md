# Doing: Factory Reset Setup Flow

**Status**: ready
**Execution Mode**: direct
**Created**: 2026-06-14 14:42
**Planning**: ./2026-06-14-1420-planning-factory-reset-setup-flow.md
**Artifacts**: ./2026-06-14-1420-doing-factory-reset-setup-flow/

## Execution Mode

- **pending**: Awaiting user approval before each unit starts (non-autopilot interactive mode only; autopilot must convert this to `spawn` or `direct` unless a hard exception is present)
- **spawn**: Spawn sub-agent for each unit (parallel/autonomous)
- **direct**: Execute units sequentially in current session (default)

## Objective

Restore the simple Workbench product story: a native terminal multiplexer whose Ouro boss agent can read, write, resume, and coordinate every terminal session.

The immediate blocker is the post-factory-reset first-run experience: Workbench currently relaunches into a confusing built-in shell-only workspace with unclear terminal-control chrome instead of getting the user set up with an Ouro agent, letting that agent warmly inspect local coding-agent history, proposing imports, and guiding external sessions into Workbench.

## Upstream Work Items

- A-001
- A-002
- A-003
- A-004
- A-005
- A-006
- A-007

## Completion Criteria

- [ ] After `Reset to Factory Defaults`, the next launch presents the setup/import flow even when the selected boss/harness readiness would otherwise be `.ready`.
- [ ] First-run setup first resolves the Ouro agent: select an existing functioning agent or hatch/configure a new one. No terminal import/chrome complexity blocks that step.
- [ ] Once the boss agent is functioning, setup switches to a conversational welcome/import flow rather than a static wizard-only experience.
- [ ] A fresh/post-reset workspace does not show an undeletable `Local Shell` as the only apparent thing to do before setup/import.
- [ ] If a fallback local shell is still present somewhere, it has a clear, tested removal/archive path or is intentionally hidden/deferred until after setup/import.
- [ ] The selected-session header no longer exposes the full low-level control strip as primary chrome in normal use. Advanced controls remain reachable when needed, with clear labels/tooltips.
- [ ] Running sessions show stop as the only primary action. Restart/relaunch moves into `Session Controls`. Launch/resume/recover stays visible for inactive or recoverable sessions.
- [ ] Primary sidebar/setup copy uses `Workspaces`, not `Groups`; `This Mac` appears only as machine scope; selected boss appears as compact boss status, not a permanent `Agents` peer; `Recovery` is hidden unless actionable.
- [ ] There is a clear path for the boss/import flow to surface likely sessions, ambiguous sessions, proposed organization, and duplicate-outside-Workbench guidance.
- [ ] The recent-session scanner returns candidates from representative Codex archived JSONL/manual-recovery files and representative Claude task records, with evidence paths and resume commands.
- [ ] Existing scanner tests for Claude project history, live cmux/Claude panels, Codex SQLite/index, shell history, and grouping still pass.
- [ ] Factory reset tests prove the explicit setup marker is set/cleared correctly and cannot be immediately overwritten by quit-time save.
- [ ] 100% test coverage on all new code
- [ ] All tests pass
- [ ] No warnings

## Code Coverage Requirements

**MANDATORY: 100% coverage on all new code.**
- No `[ExcludeFromCodeCoverage]` or equivalent on new code
- All branches covered (if/else, switch, try/catch)
- All error paths tested
- Edge cases: null, empty, boundary values

## TDD Requirements

**Strict TDD - no exceptions:**
1. **Tests first**: Write failing tests BEFORE any implementation
2. **Verify failure**: Run tests, confirm they FAIL (red)
3. **Minimal implementation**: Write just enough code to pass
4. **Verify pass**: Run tests, confirm they PASS (green)
5. **Refactor**: Clean up, keep tests green
6. **No skipping**: Never write implementation without failing test first

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

**CRITICAL: Every unit header MUST start with status emoji (⬜ for new units).**

### ✅ Unit 0: Setup/Research
**What**: Re-read `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`, `Sources/OuroWorkbenchCore/WorkbenchFactoryReset.swift`, `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift`, `Sources/OuroWorkbenchCore/Onboarding.swift`, and the existing reset/bootstrap/onboarding tests. Record current git status and source-of-truth skill availability in artifacts.
**Output**: `2026-06-14-1420-doing-factory-reset-setup-flow/unit-0-research.md`
**Acceptance**: Artifact records branch, status, exact target files, test files, and the decision that implementation can proceed without human input.

### ✅ Unit 1a: Reset Setup Intent - Tests
**What**: Write failing tests for a core setup intent marker, setup-mode bootstrap, and testable launch diagnostics. Target `Tests/OuroWorkbenchCoreTests/WorkbenchFactoryResetTests.swift`, `Tests/OuroWorkbenchCoreTests/WorkbenchBootstrapperTests.swift`, and a new `Tests/OuroWorkbenchCoreTests/WorkbenchLaunchDiagnosticsTests.swift`.
**Output**: Failing tests prove a setup intent marker file named `force-first-run-setup` can be requested under Workbench app support, survives a factory defaults wipe when written after the wipe, can be consumed/cleared, and bootstrapping with `includeLocalShell: false` creates no local shell while using a non-`This Mac` workspace name. Add a failing `WorkbenchFactoryResetTests/testFactoryResetRequestsFirstRunSetupAfterWipe` that seeds a state file and stale marker, calls a core reset helper, and expects the state file removed/backed up, preferences cleared, and a fresh `force-first-run-setup` marker present after the wipe. Diagnostic tests define `WorkbenchLaunchDiagnostics.parse(_:)` expectations for `--app-support-root PATH`, `--auto-launch-resumable-for-e2e`, `--factory-reset-for-e2e`, absent flags, missing required path, and unknown passthrough args before any app diagnostic implementation exists.
**Acceptance**: Focused test command fails for the new expectations before implementation.

### ✅ Unit 1b: Reset Setup Intent - Implementation
**What**: Add the minimal core helper and app wiring so reset/fresh first-run loads setup-mode bootstrap, suppresses default shell auto-launch, forces onboarding on next launch, and consumes the explicit reset marker after presentation. Factor a core reset helper in `WorkbenchFactoryReset` that performs `wipeData` and writes the setup marker after the wipe; update `WorkbenchViewModel.resetToFirstRun()` to call that helper. Add test-covered launch diagnostic parsing in `Sources/OuroWorkbenchCore/WorkbenchLaunchDiagnostics.swift`, then wire app diagnostic arguments `--app-support-root PATH`, `--auto-launch-resumable-for-e2e`, and `--factory-reset-for-e2e` in `Sources/OuroWorkbenchApp/main.swift` and `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` so live E2E can force `WorkbenchPaths`, exercise the real reset data path, and control auto-launch behavior without relying on `HOME` or the real defaults domain.
**Output**: Code changes in `Sources/OuroWorkbenchCore/WorkbenchFactoryReset.swift`, `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift`, `Sources/OuroWorkbenchCore/WorkbenchPaths.swift`, `Sources/OuroWorkbenchCore/WorkbenchLaunchDiagnostics.swift`, `Sources/OuroWorkbenchApp/main.swift`, and `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`.
**Acceptance**: Unit 1a tests pass; `swift build` succeeds without warnings.

### ✅ Unit 1c: Reset Setup Intent - Coverage & Refactor
**What**: Run `swift test --filter WorkbenchFactoryResetTests`, `swift test --filter WorkbenchBootstrapperTests`, `swift test --filter WorkbenchLaunchDiagnosticsTests`, and `swift build`. Make no code changes unless one of those commands fails or a new setup-intent/launch-diagnostic branch is uncovered by the tests.
**Output**: Test/build output saved to `2026-06-14-1420-doing-factory-reset-setup-flow/unit-1-reset-setup.log`.
**Acceptance**: New setup-intent and launch-diagnostic code has branch coverage for request, consume, absent marker, setup bootstrap, ordinary bootstrap, wipe-then-marker reset ordering, app-support override, auto-launch override, factory-reset diagnostic action, missing diagnostic arguments, and unknown arg passthrough.

### ✅ Unit 2a: Recent Session Scanner Stores - Tests
**What**: Write failing tests in `Tests/OuroWorkbenchCoreTests/OnboardingTests.swift` for Codex archived JSONL, Codex manual-recovery JSONL, Claude task JSON records, SQLite-plus-session-index union behavior, scanner edge cases, and diagnostic parse coverage.
**Output**: Fixture tests using temporary `.codex/archived_sessions`, `.codex/manual-recovery-*`, `.codex/session_index.jsonl`, `.codex/state_5.sqlite`, and `.claude/tasks`. Add exact scanner tests named `testRecentSessionScannerReadsCodexArchivedJsonl`, `testRecentSessionScannerReadsCodexManualRecoveryJsonl`, `testRecentSessionScannerReadsClaudeTaskJson`, `testRecentSessionScannerUnionsCodexSqliteAndSessionIndex`, `testRecentSessionScannerIgnoresStaleCodexArchive`, `testRecentSessionScannerSkipsMalformedCodexArchiveLines`, `testRecentSessionScannerDropsCodexArchiveWithoutSessionId`, `testRecentSessionScannerKeepsCodexArchiveWithoutWorkingDirectoryAsRecoverable`, `testRecentSessionScannerPrefersHigherConfidenceDuplicate`, and `testRecentSessionScannerFallsBackToSessionIndexWhenSqliteMissingOrUnexecutable`. Add `WorkbenchLaunchDiagnosticsTests` coverage for `--dump-recent-sessions-json` and optional `--scan-home-root PATH`.
**Acceptance**: Focused onboarding/diagnostic tests fail before scanner implementation because candidates and diagnostic actions are missing. Expected edge results are: stale file outside lookback absent, malformed line skipped, missing session id dropped, missing working directory retained only as a recoverable low-confidence candidate, duplicate id picks the higher-confidence candidate, and missing/unusable sqlite still reads `session_index.jsonl`.

### ✅ Unit 2b: Recent Session Scanner Stores - Implementation
**What**: Extend `RecentSessionScanner.scan()` and helper methods in `Sources/OuroWorkbenchCore/Onboarding.swift` to include deterministic adapters for the new Codex and Claude stores while preserving existing scanner behavior. Extend `WorkbenchLaunchDiagnostics` with a read-only diagnostic action for `--dump-recent-sessions-json [--scan-home-root PATH]`, and wire that action in `Sources/OuroWorkbenchApp/main.swift` so it prints encoded `RecentSessionCandidate` records and exits before mounting SwiftUI.
**Output**: Scanner returns evidence-backed `RecentSessionCandidate` values with source, kind, title, working directory, recency, resume command, summary, evidence path, confidence, and repository-root grouping. The diagnostic command `swift run OuroWorkbench --dump-recent-sessions-json` emits JSON without mutating Workbench or harness state.
**Acceptance**: Unit 2a tests pass; existing onboarding scanner/proposal tests pass.

### ✅ Unit 2c: Recent Session Scanner Stores - Coverage & Refactor
**What**: Run exact focused coverage commands for the scanner happy paths and edge cases:

```bash
swift test --filter OnboardingTests/testRecentSessionScannerReadsCodexArchivedJsonl
swift test --filter OnboardingTests/testRecentSessionScannerReadsCodexManualRecoveryJsonl
swift test --filter OnboardingTests/testRecentSessionScannerReadsClaudeTaskJson
swift test --filter OnboardingTests/testRecentSessionScannerUnionsCodexSqliteAndSessionIndex
swift test --filter OnboardingTests/testRecentSessionScannerIgnoresStaleCodexArchive
swift test --filter OnboardingTests/testRecentSessionScannerSkipsMalformedCodexArchiveLines
swift test --filter OnboardingTests/testRecentSessionScannerDropsCodexArchiveWithoutSessionId
swift test --filter OnboardingTests/testRecentSessionScannerKeepsCodexArchiveWithoutWorkingDirectoryAsRecoverable
swift test --filter OnboardingTests/testRecentSessionScannerPrefersHigherConfidenceDuplicate
swift test --filter OnboardingTests/testRecentSessionScannerFallsBackToSessionIndexWhenSqliteMissingOrUnexecutable
swift test --filter WorkbenchLaunchDiagnosticsTests
swift test --filter OnboardingTests
```
**Output**: Test output saved to artifacts.
**Acceptance**: New scanner code has coverage for happy path, stale path, malformed/partial path, and dedupe/union behavior.

### ✅ Unit 3a: Sidebar Workspace Policy - Tests
**What**: Add failing tests for a pure sidebar/setup surface policy and the sidebar fixture diagnostic. Target a new `Tests/OuroWorkbenchCoreTests/WorkbenchSurfacePolicyTests.swift` covering workspace noun copy, setup-mode project name, boss section label/status, hidden healthy recovery, shown actionable recovery, and `WorkbenchLaunchDiagnostics` fixture action parsing for `--write-e2e-state sidebar-session-controls PATH`.
**Output**: Failing tests specify exact expected values: section title `Workspaces`, setup workspace name `Unsorted Sessions`, no `This Mac` workspace name, compact boss status labels, recovery visibility only when recoverable count is greater than zero, diagnostic action case `.writeE2EState(.sidebarSessionControls, path)`, and parse error for missing fixture path.
**Acceptance**: Focused policy tests fail before implementation because `WorkbenchSurfacePolicy` does not exist or returns old `Groups`/always-recovery behavior.

### ✅ Unit 3b: Sidebar Workspace Policy - Implementation
**What**: Add `Sources/OuroWorkbenchCore/WorkbenchSurfacePolicy.swift` and wire `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` sidebar/setup labels through it. Replace primary `Groups` text with `Workspaces`, use `Unsorted Sessions` for setup-mode bootstrap, replace permanent `Agents` section title with compact `Boss`, and hide the sidebar `Recovery` section when `model.recoverableEntries.isEmpty`. Extend the test-covered diagnostic helper with a hidden flag `--write-e2e-state sidebar-session-controls PATH` in `Sources/OuroWorkbenchApp/main.swift` that writes a deterministic Workbench state for Unit 6e and exits before mounting SwiftUI.
**Output**: Core policy plus app sidebar copy/visibility changes. The diagnostic command `swift run OuroWorkbench --write-e2e-state sidebar-session-controls /tmp/workspace-state.json` writes a state containing one workspace named `Fixture Workspace` and one trusted auto-resume terminal agent named `Fixture Running Session`.
**Acceptance**: Unit 3a tests pass; `swift build` succeeds; `rg -n 'Section\\(\"Groups\"\\)|New Group|Move to Group|Delete Terminal Group|Groups with terminals' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` returns no primary user-facing sidebar/header strings.

### ✅ Unit 3c: Sidebar Workspace Policy - Coverage & Refactor
**What**: Run `swift test --filter WorkbenchSurfacePolicyTests` and `swift build`. Keep any refactor limited to `WorkbenchSurfacePolicy` naming and call sites already changed in Unit 3b.
**Output**: Test/build output saved to `2026-06-14-1420-doing-factory-reset-setup-flow/unit-3-sidebar-policy.log`.
**Acceptance**: Policy branches for setup mode, normal mode, healthy recovery, and actionable recovery are covered and green.

### ✅ Unit 4a: Running Session Controls Policy - Tests
**What**: Add failing tests for a pure running-session chrome policy in `Tests/OuroWorkbenchCoreTests/WorkbenchSurfacePolicyTests.swift`. Cover visible primary actions for running, stopped, archived, and recoverable sessions.
**Output**: Tests require running sessions to expose only `stop` as a primary action and to expose `focus`, `redraw`, `restart`, `controlC`, `escape`, and `eof` only as advanced session controls.
**Acceptance**: Tests fail before implementation because the policy does not exist or still treats low-level controls/restart as primary.

### ✅ Unit 4b: Running Session Controls Policy - Implementation
**What**: Extend `Sources/OuroWorkbenchCore/WorkbenchSurfacePolicy.swift` for session chrome actions and update `RunningSessionHeaderControls` in `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` so the header shows a visible Stop button plus a labeled `Session Controls` menu containing Focus, Redraw, Restart, Ctrl-C, Esc, EOF, Copy Launch Command, and Open Working Directory.
**Output**: Header UI no longer shows the screenshot's row of unlabeled low-level icons; advanced actions remain reachable with labels/tooltips.
**Acceptance**: Unit 4a tests pass; `swift build` succeeds; `rg -n 'RunningSessionHeaderControls|Session Controls|Ctrl-C|EOF|Restart' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` shows the actions under the menu implementation, not as separate primary image buttons.

### ✅ Unit 4c: Running Session Controls Policy - Coverage & Refactor
**What**: Run `swift test --filter WorkbenchSurfacePolicyTests` and `swift build`. Keep refactor scoped to the policy enum/action naming and `RunningSessionHeaderControls`.
**Output**: Test/build output saved to `2026-06-14-1420-doing-factory-reset-setup-flow/unit-4-session-controls.log`.
**Acceptance**: Running/stopped/archived/recoverable action policies are covered and green.

### ⬜ Unit 5a: Boss-Led Onboarding Copy - Tests
**What**: Add failing tests for a pure onboarding narrative helper. Target `Tests/OuroWorkbenchCoreTests/OnboardingTests.swift` or a new `Tests/OuroWorkbenchCoreTests/OnboardingNarrativeTests.swift`.
**Output**: Tests require exact copy from `WorkbenchOnboardingNarrative`: `bossReadyWelcome == "I can see this Mac now."`, `scanIntro == "I will look for local coding-agent sessions across Workbench, Claude, Codex, Copilot, cmux, and shell history."`, `unclearImport == "I will ask before importing anything unclear."`, `ambiguousCandidates(count: 2) == "I found 2 unclear sessions. I will ask before importing them."`, `duplicateCleanup == "After I resume these in Workbench, I will help you close matching sessions still running outside Workbench so work does not fork."`, and `proposalSummary(groupCount: 3, selectedCount: 5) == "I found 5 likely sessions across 3 workspaces."`
**Acceptance**: Tests fail before implementation because `WorkbenchOnboardingNarrative` does not exist or old copy omits boss-led import/cleanup language.

### ⬜ Unit 5b: Boss-Led Onboarding Copy - Implementation
**What**: Add `Sources/OuroWorkbenchCore/WorkbenchOnboardingNarrative.swift` and use it in `OnboardingWelcomePage`, `OnboardingBootstrapView`, `OnboardingGroupProposalView`, `OnboardingSessionPreviewSheet`, and import summary/banner copy in `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`.
**Output**: Onboarding copy uses the exact strings tested in Unit 5a and says the boss can see this Mac, will scan local coding-agent sessions, will ask before unclear imports, and will guide cleanup of duplicates after Workbench resumes approved sessions.
**Acceptance**: Unit 5a tests pass; `swift build` succeeds; `rg -n 'Nothing is imported until you review the proposal|Ready to arrange|Bring your work in' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` returns no old static-wizard copy.

### ⬜ Unit 5c: Boss-Led Onboarding Flow Policy - Tests
**What**: Add failing tests for pure onboarding flow decisions in `Tests/OuroWorkbenchCoreTests/OnboardingNarrativeTests.swift`: wizard phase before boss readiness, boss-led import phase after readiness, proposal visual support when candidates exist, ambiguity prompt when low-confidence candidates exist, and duplicate cleanup guidance after import.
**Output**: Tests define `WorkbenchOnboardingPhase` exact cases `.bossSetupWizard`, `.bossReadyWelcome`, `.scanProposal`, `.arrangeApprovedImports`, and `.duplicateCleanup`; `WorkbenchOnboardingFlowInput` fields `bossIsReady`, `hasProposal`, `selectedTerminalCount`, `ambiguousCandidateCount`, and `importSummaryHasImports`; and primary CTA titles `Connect Boss`, `Scan With Boss`, `Arrange Selected`, and `Review Duplicates`. Expected flow: not-ready -> `.bossSetupWizard`/`Connect Boss`; ready without proposal -> `.bossReadyWelcome`/`Scan With Boss`; ready with proposal and zero selected -> `.scanProposal`/`Scan With Boss`; selected imports -> `.arrangeApprovedImports`/`Arrange Selected`; ambiguous candidates attach `WorkbenchOnboardingNarrative.ambiguousCandidates(count:)`; imported summary -> `.duplicateCleanup`/`Review Duplicates`.
**Acceptance**: Tests fail before implementation because flow policy does not exist or old readiness/import states do not distinguish boss-led phases.

### ⬜ Unit 5d: Boss-Led Onboarding Flow Policy - Implementation
**What**: Add `WorkbenchOnboardingFlowPolicy` in `Sources/OuroWorkbenchCore/WorkbenchOnboardingNarrative.swift` and wire `WorkbenchOnboardingSheet.advance`, `primaryActionTitle`, `OnboardingBootstrapView`, and `handleOnboardingInstruction` through it where those functions choose setup/import/arrange behavior.
**Output**: Traditional wizard remains limited to boss setup/readiness; after readiness, the boss-led import phase drives scan/proposal/arrange and duplicate cleanup messaging using the exact phase cases and CTA strings tested in Unit 5c.
**Acceptance**: Unit 5c tests pass; `swift build` succeeds; `rg -n 'WorkbenchOnboardingFlowPolicy|WorkbenchOnboardingNarrative' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift Sources/OuroWorkbenchCore/WorkbenchOnboardingNarrative.swift` shows both app wiring and core policy/narrative definitions.

### ⬜ Unit 5e: Boss-Led Onboarding - Coverage & Refactor
**What**: Run onboarding narrative/flow tests, existing `OnboardingTests`, and `swift build`. Refactor only helper names or call-site duplication created in Units 5b/5d.
**Output**: Test/build output saved to `2026-06-14-1420-doing-factory-reset-setup-flow/unit-5-onboarding.log`.
**Acceptance**: Narrative and flow helpers have branch coverage for not-ready, ready-no-proposal, proposal-with-selected, proposal-with-low-confidence, and imported/cleanup states.

### ⬜ Unit 6a: Automated Suite Verification
**What**: Run `swift test` and `swift build`.
**Output**: Save output to `2026-06-14-1420-doing-factory-reset-setup-flow/full-swift-test.log` and `2026-06-14-1420-doing-factory-reset-setup-flow/swift-build.log`.
**Acceptance**: Both commands exit 0, logs contain no warnings, and failures are fixed before continuing.

### ⬜ Unit 6b: Scenario Verifier
**What**: Run `swift run OuroWorkbenchScenarioVerifier --out worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow/scenario-verifier --no-samples`.
**Output**: Save command output to `2026-06-14-1420-doing-factory-reset-setup-flow/scenario-verifier.log` and generated verifier files under `2026-06-14-1420-doing-factory-reset-setup-flow/scenario-verifier/`.
**Acceptance**: Command exits 0 and the log records zero scenario failures.

### ⬜ Unit 6c: Package Install Version Proof
**What**: Run these exact commands from repo root:

```bash
ART="worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow"
scripts/package-app.sh > "$ART/package-install.log" 2>&1
scripts/install-app.sh --install-dir "$HOME/Applications" >> "$ART/package-install.log" 2>&1
APP="$HOME/Applications/Ouro Workbench.app"
scripts/verify-app-bundle.sh "$APP" >> "$ART/package-install.log" 2>&1
{
  printf 'source-version=%s\n' "$(tr -d '[:space:]' < VERSION)"
  printf 'source-build=%s\n' "$(git rev-list --count HEAD)"
  printf 'installed-version=%s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  printf 'installed-build=%s\n' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
} > "$ART/installed-app-version.txt"
```

**Output**: Save package/install output to `2026-06-14-1420-doing-factory-reset-setup-flow/package-install.log` and installed version proof to `2026-06-14-1420-doing-factory-reset-setup-flow/installed-app-version.txt`.
**Acceptance**: Installed app version/build match the current source artifact, not the stale `0.1.125` / `201` evidence build.

### ⬜ Unit 6d: Live Reset Setup E2E
**What**: Create and run `worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow/validate-reset-setup.sh`. The script must run these exact validation steps with an isolated app support root:

```bash
set -euo pipefail
ART="worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow"
APP="$HOME/Applications/Ouro Workbench.app"
TEST_SUPPORT="$PWD/$ART/live-reset-support"
rm -rf "$TEST_SUPPORT"
mkdir -p "$TEST_SUPPORT"
printf '{"projects":[{"name":"This Mac"}],"processEntries":[{"name":"Local Shell"}]}\n' > "$TEST_SUPPORT/workspace-state.json"
printf 'stale-before-reset\n' > "$TEST_SUPPORT/force-first-run-setup"
"$APP/Contents/MacOS/OuroWorkbench" --app-support-root "$TEST_SUPPORT" --factory-reset-for-e2e > "$ART/e2e-reset-command.log" 2>&1
test -e "$TEST_SUPPORT/force-first-run-setup"
! grep -F 'stale-before-reset' "$TEST_SUPPORT/force-first-run-setup"
ls "$TEST_SUPPORT"/workspace-state.*.bak.json > "$ART/e2e-reset-backups.txt"
"$APP/Contents/MacOS/OuroWorkbench" --app-support-root "$TEST_SUPPORT" > "$ART/e2e-reset-app.log" 2>&1 &
PID=$!
trap 'kill "$PID" >/dev/null 2>&1 || true; wait "$PID" >/dev/null 2>&1 || true' EXIT
sleep 6
screencapture -x "$ART/e2e-reset-setup.png"
STATE="$TEST_SUPPORT/workspace-state.json"
test -f "$STATE"
plutil -p "$STATE" > "$ART/e2e-reset-state.txt"
! grep -F 'Local Shell' "$STATE"
! test -e "$TEST_SUPPORT/force-first-run-setup"
test -s "$ART/e2e-reset-setup.png"
{
  printf 'PASS reset_setup\n'
  printf 'state_path=%s\n' "$STATE"
  printf 'screenshot=%s\n' "$ART/e2e-reset-setup.png"
  printf 'assertion=marker consumed\n'
  printf 'assertion=no Local Shell in setup workspace\n'
  printf 'assertion=onboarding/setup screenshot captured from launched app\n'
} > "$ART/e2e-reset-setup.md"
grep -F 'PASS reset_setup' "$ART/e2e-reset-setup.md"
kill "$PID" >/dev/null 2>&1 || true
wait "$PID" >/dev/null 2>&1 || true
trap - EXIT
```

**Output**: Save notes and screenshots to `2026-06-14-1420-doing-factory-reset-setup-flow/e2e-reset-setup.md`.
**Acceptance**: Artifact has `PASS`; the validation first runs the reset data path through `--factory-reset-for-e2e`, proves the stale marker was replaced after the wipe and a state backup exists, next launch presents onboarding/setup, no default `Local Shell` is selected/launched before setup/import, and `workspace-state.json` does not contain a reset-created shell-only dead end.

### ⬜ Unit 6e: Live Sidebar And Session Controls E2E
**What**: Create and run `worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow/validate-sidebar-session-controls.sh`. The script must launch the installed app with an isolated home seeded by the Unit 3b diagnostic fixture, capture a screenshot, and run these exact commands:

```bash
set -euo pipefail
ART="worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow"
APP="$HOME/Applications/Ouro Workbench.app"
TEST_SUPPORT="$PWD/$ART/live-sidebar-support"
rm -rf "$TEST_SUPPORT"
mkdir -p "$TEST_SUPPORT"
"$APP/Contents/MacOS/OuroWorkbench" --write-e2e-state sidebar-session-controls "$TEST_SUPPORT/workspace-state.json" > "$ART/sidebar-fixture.log" 2>&1
"$APP/Contents/MacOS/OuroWorkbench" --app-support-root "$TEST_SUPPORT" --auto-launch-resumable-for-e2e > "$ART/e2e-sidebar-app.log" 2>&1 &
PID=$!
trap 'kill "$PID" >/dev/null 2>&1 || true; wait "$PID" >/dev/null 2>&1 || true' EXIT
sleep 6
screencapture -x "$ART/e2e-sidebar-session-controls.png"
plutil -p "$TEST_SUPPORT/workspace-state.json" > "$ART/e2e-sidebar-state.txt"
grep -F 'Fixture Workspace' "$TEST_SUPPORT/workspace-state.json"
grep -F 'Fixture Running Session' "$TEST_SUPPORT/workspace-state.json"
if rg -n 'Section\("Groups"\)|New Group|Move to Group|Delete Terminal Group|Groups with terminals' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift; then
  exit 1
fi
rg -n 'Section\("Workspaces"\)' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
rg -n 'Section\("Boss"\)' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
rg -n 'if !model\.recoverableEntries\.isEmpty' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
rg -n 'Session Controls' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
rg -n 'Label\("Stop", systemImage: "stop.fill"\)' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
test -s "$ART/e2e-sidebar-session-controls.png"
{
  printf 'PASS sidebar_session_controls\n'
  printf 'state_path=%s\n' "$TEST_SUPPORT/workspace-state.json"
  printf 'screenshot=%s\n' "$ART/e2e-sidebar-session-controls.png"
  printf 'assertion=Workspaces section wired in source\n'
  printf 'assertion=Boss section wired in source\n'
  printf 'assertion=healthy recovery hidden by empty recoverable entries\n'
  printf 'assertion=Stop primary action wired in source\n'
  printf 'assertion=Session Controls menu wired in source\n'
} > "$ART/e2e-sidebar-session-controls.md"
grep -F 'PASS sidebar_session_controls' "$ART/e2e-sidebar-session-controls.md"
kill "$PID" >/dev/null 2>&1 || true
wait "$PID" >/dev/null 2>&1 || true
trap - EXIT
```

**Output**: Save notes and screenshots to `2026-06-14-1420-doing-factory-reset-setup-flow/e2e-sidebar-session-controls.md`.
**Acceptance**: Artifact has `PASS`; visible primary labels use `Workspaces`/`Boss`; healthy recovery is hidden; running-session header shows Stop and labeled `Session Controls`; focus/redraw/restart/Ctrl-C/Esc/EOF are not a row of primary icon buttons.

### ⬜ Unit 6f: Live Import Scanner E2E
**What**: Create and run `worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow/validate-import-scanner.sh`. The script must seed deterministic synthetic harness stores under an isolated scan home, run the read-only diagnostic added in Unit 2b against the installed current-source app, and verify source coverage with `jq`:

```bash
set -euo pipefail
ART="worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow"
APP="$HOME/Applications/Ouro Workbench.app"
SCAN_HOME="$PWD/$ART/live-scan-home"
rm -rf "$SCAN_HOME"
mkdir -p "$SCAN_HOME/.codex/archived_sessions" "$SCAN_HOME/.codex/manual-recovery-20260614" "$SCAN_HOME/.claude/tasks" "$SCAN_HOME/.claude/projects/-Users-arimendelow-Projects-fixture"
NOW="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
printf '{"id":"codex-archive-live","timestamp":"%s","cwd":"/Users/arimendelow/Projects/fixture","prompt":"continue fixture archive"}\n' "$NOW" > "$SCAN_HOME/.codex/archived_sessions/session.jsonl"
printf '{"id":"codex-manual-live","timestamp":"%s","cwd":"/Users/arimendelow/Projects/fixture","prompt":"manual recovery fixture"}\n' "$NOW" > "$SCAN_HOME/.codex/manual-recovery-20260614/recovery.jsonl"
printf '{"sessionId":"claude-task-live","updatedAt":"%s","cwd":"/Users/arimendelow/Projects/fixture","summary":"Claude task fixture"}\n' "$NOW" > "$SCAN_HOME/.claude/tasks/task.json"
printf '{"sessionId":"claude-project-live","updatedAt":"%s","cwd":"/Users/arimendelow/Projects/fixture","summary":"Claude project fixture"}\n' "$NOW" > "$SCAN_HOME/.claude/projects/-Users-arimendelow-Projects-fixture/session.json"
"$APP/Contents/MacOS/OuroWorkbench" --dump-recent-sessions-json --scan-home-root "$SCAN_HOME" > "$ART/e2e-import-scanner.json"
jq -e '[.[] | select(.source == "openAICodex") | select((.evidencePaths // []) | map(test("/\\.codex/(archived_sessions|manual-recovery-)")) | any)] | length >= 1' "$ART/e2e-import-scanner.json"
jq -e '[.[] | select(.source == "claudeCode") | select((.evidencePaths // []) | map(test("/\\.claude/(tasks|projects)")) | any)] | length >= 1' "$ART/e2e-import-scanner.json"
jq -e '[.[] | select((.resumeCommand // []) | length > 0) | select((.evidencePaths // []) | length > 0)] | length >= 2' "$ART/e2e-import-scanner.json"
jq -r '.[] | [.source, .title, .workingDirectory, (.resumeCommand | join(" ")), (.evidencePaths | join(","))] | @tsv' "$ART/e2e-import-scanner.json" > "$ART/e2e-import-scanner.tsv"
{
  printf 'PASS import_scanner\n'
  printf 'scan_home=%s\n' "$SCAN_HOME"
  printf 'json=%s\n' "$ART/e2e-import-scanner.json"
  printf 'tsv=%s\n' "$ART/e2e-import-scanner.tsv"
  printf 'assertion=synthetic Codex archived/manual-recovery source detected\n'
  printf 'assertion=synthetic Claude tasks/projects source detected\n'
  printf 'assertion=evidence paths and resume commands present\n'
} > "$ART/e2e-import-scanner.md"
grep -F 'PASS import_scanner' "$ART/e2e-import-scanner.md"
```

**Output**: Save scanner output summary to `2026-06-14-1420-doing-factory-reset-setup-flow/e2e-import-scanner.md`.
**Acceptance**: Artifact has `PASS`; scanner reports candidates from the synthetic isolated Codex archived/manual-recovery source and synthetic isolated Claude task/project source, with evidence paths and resume commands, without reading or mutating any external harness store.

## Execution

- **TDD strictly enforced**: tests -> red -> implement -> green -> refactor
- Commit after every unit phase (`1a` through `6f`) and after each doing-doc status/progress update
- Push after each atomic commit when a remote is configured and the network command succeeds
- Run full test suite before marking unit done
- **All artifacts**: Save outputs, logs, data to `./2026-06-14-1420-doing-factory-reset-setup-flow/`
- **Fixes/blockers**: Spawn sub-agent immediately; do not ask the user
- **Decisions made**: Update docs immediately, commit right away

## Progress Log

- 2026-06-14 14:42 Created from planning doc
- 2026-06-14 15:15 Doing doc reviewer gates converged; status set to ready for direct execution.
- 2026-06-14 15:16 Unit 0 complete: recorded branch, clean status, target files, skill-source availability, and no-human-blocker decision.
- 2026-06-14 15:18 Unit 1a complete: added failing reset marker, setup bootstrap, and launch diagnostic tests; red log saved to unit-1a-red.log.
- 2026-06-14 15:22 Unit 1b complete: implemented wipe-plus-marker reset, setup-mode bootstrap defaults, launch diagnostics, and app launch wiring; green log saved to unit-1b-green.log.
- 2026-06-14 15:28 Unit 1c complete: reran reset/bootstrap/launch diagnostic tests and build; Unit 1b cold review converged after isolated reset-root safety fix.
- 2026-06-14 15:31 Unit 2a complete: added failing Codex/Claude scanner store tests and dump-recent-sessions diagnostic parse tests; red log saved to unit-2a-red.log.
- 2026-06-14 15:37 Unit 2b complete: implemented Codex archived/manual-recovery/index/sqlite union, Claude task/project JSON scanning, and dump-recent-sessions JSON diagnostic; green log saved to unit-2b-green.log.
- 2026-06-14 15:38 Unit 2c complete: reran exact scanner edge coverage commands and full OnboardingTests; log saved to unit-2-scanner.log.
- 2026-06-14 15:39 Unit 3a complete: added failing sidebar surface policy and e2e fixture diagnostic tests; red log saved to unit-3a-red.log.
- 2026-06-14 15:43 Unit 2 review finding addressed: added red/green coverage for Codex `session_meta.payload` archive/manual-recovery JSONL records.
- 2026-06-14 15:46 Unit 3b complete: added WorkbenchSurfacePolicy, schema-backed sidebar e2e fixture writer, Workspaces/Boss sidebar labels, and hidden healthy Recovery; green log saved to unit-3b-green.log.
- 2026-06-14 15:47 Unit 3c complete: reran WorkbenchSurfacePolicyTests, build, and sidebar source assertions; log saved to unit-3-sidebar-policy.log.
- 2026-06-14 15:48 Unit 4a complete: added failing session controls policy tests; red log saved to unit-4a-red.log.
- 2026-06-14 15:50 Unit 4b complete: added session action policy and replaced running-session header icon row with Stop plus Session Controls menu; green log saved to unit-4b-green.log.
- 2026-06-14 15:55 Unit 3 cold-review findings addressed: workspace creation/edit/error copy now uses workspace nouns and sidebar labels/recovery visibility are wired through WorkbenchSurfacePolicy.
- 2026-06-14 15:55 Unit 4c complete: reran WorkbenchSurfacePolicyTests, build, and session-control source assertions; log saved to unit-4-session-controls.log.
