# Doing: Factory Reset Setup Flow

**Status**: drafting
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
- [ ] Running sessions show stop as the only primary action. Restart/relaunch, if kept, moves into `Session Controls` or another advanced menu. Launch/resume/recover stays visible for inactive or recoverable sessions.
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

### ⬜ Unit 0: Setup/Research
**What**: Re-read `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`, `Sources/OuroWorkbenchCore/WorkbenchFactoryReset.swift`, `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift`, `Sources/OuroWorkbenchCore/Onboarding.swift`, and the existing reset/bootstrap/onboarding tests. Record current git status and source-of-truth skill availability in artifacts.
**Output**: `2026-06-14-1420-doing-factory-reset-setup-flow/unit-0-research.md`
**Acceptance**: Artifact records branch, status, exact target files, test files, and the decision that implementation can proceed without human input.

### ⬜ Unit 1a: Reset Setup Intent - Tests
**What**: Write failing tests for a core setup intent marker and setup-mode bootstrap. Target `Tests/OuroWorkbenchCoreTests/WorkbenchFactoryResetTests.swift` and `Tests/OuroWorkbenchCoreTests/WorkbenchBootstrapperTests.swift`.
**Output**: Failing tests prove a setup intent marker file named `force-first-run-setup` can be requested under Workbench app support, survives a factory defaults wipe when written after the wipe, can be consumed/cleared, and bootstrapping with `includeLocalShell: false` creates no local shell while using a non-`This Mac` workspace name.
**Acceptance**: Focused test command fails for the new expectations before implementation.

### ⬜ Unit 1b: Reset Setup Intent - Implementation
**What**: Add the minimal core helper and app wiring so reset/fresh first-run loads setup-mode bootstrap, suppresses default shell auto-launch, forces onboarding on next launch, and consumes the explicit reset marker after presentation.
**Output**: Code changes in `Sources/OuroWorkbenchCore/WorkbenchFactoryReset.swift`, `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift`, `Sources/OuroWorkbenchCore/WorkbenchPaths.swift`, and `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`.
**Acceptance**: Unit 1a tests pass; `swift build` succeeds without warnings.

### ⬜ Unit 1c: Reset Setup Intent - Coverage & Refactor
**What**: Run the reset/bootstrap focused tests plus any affected core tests. Refactor only if needed for clarity while keeping behavior unchanged.
**Output**: Test/build output saved to artifacts.
**Acceptance**: New setup-intent code has branch coverage for request, consume, absent marker, setup bootstrap, and ordinary bootstrap.

### ⬜ Unit 2a: Recent Session Scanner Stores - Tests
**What**: Write failing tests in `Tests/OuroWorkbenchCoreTests/OnboardingTests.swift` for Codex archived JSONL, Codex manual-recovery JSONL, Claude task JSON records, and SQLite-plus-session-index union behavior.
**Output**: Fixture tests using temporary `.codex/archived_sessions`, `.codex/manual-recovery-*`, `.codex/session_index.jsonl`, `.codex/state_5.sqlite`, and `.claude/tasks`.
**Acceptance**: Focused onboarding tests fail before scanner implementation because candidates are missing.

### ⬜ Unit 2b: Recent Session Scanner Stores - Implementation
**What**: Extend `RecentSessionScanner.scan()` and helper methods in `Sources/OuroWorkbenchCore/Onboarding.swift` to include deterministic adapters for the new Codex and Claude stores while preserving existing scanner behavior. Add a read-only app diagnostic flag `--dump-recent-sessions-json` in `Sources/OuroWorkbenchApp/main.swift` that prints encoded `RecentSessionCandidate` records and exits before mounting SwiftUI.
**Output**: Scanner returns evidence-backed `RecentSessionCandidate` values with source, kind, title, working directory, recency, resume command, summary, evidence path, confidence, and repository-root grouping. The diagnostic command `swift run OuroWorkbench --dump-recent-sessions-json` emits JSON without mutating Workbench or harness state.
**Acceptance**: Unit 2a tests pass; existing onboarding scanner/proposal tests pass.

### ⬜ Unit 2c: Recent Session Scanner Stores - Coverage & Refactor
**What**: Run onboarding tests and inspect edge cases: old files outside lookback, malformed JSON lines, missing cwd/id, duplicate ids with different confidence, and missing sqlite binary.
**Output**: Test output saved to artifacts.
**Acceptance**: New scanner code has coverage for happy path, stale path, malformed/partial path, and dedupe/union behavior.

### ⬜ Unit 3a: Sidebar Workspace Policy - Tests
**What**: Add failing tests for a pure sidebar/setup surface policy. Target a new `Tests/OuroWorkbenchCoreTests/WorkbenchSurfacePolicyTests.swift` covering workspace noun copy, setup-mode project name, boss section label/status, hidden healthy recovery, and shown actionable recovery.
**Output**: Failing tests specify exact expected values: section title `Workspaces`, setup workspace name `Unsorted Sessions`, no `This Mac` workspace name, compact boss status labels, and recovery visibility only when recoverable count is greater than zero.
**Acceptance**: Focused policy tests fail before implementation because `WorkbenchSurfacePolicy` does not exist or returns old `Groups`/always-recovery behavior.

### ⬜ Unit 3b: Sidebar Workspace Policy - Implementation
**What**: Add `Sources/OuroWorkbenchCore/WorkbenchSurfacePolicy.swift` and wire `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` sidebar/setup labels through it. Replace primary `Groups` text with `Workspaces`, use `Unsorted Sessions` for setup-mode bootstrap, replace permanent `Agents` section title with compact `Boss`, and hide the sidebar `Recovery` section when `model.recoverableEntries.isEmpty`. Add a hidden diagnostic flag `--write-e2e-state sidebar-session-controls PATH` in `Sources/OuroWorkbenchApp/main.swift` that writes a deterministic Workbench state for Unit 6e and exits before mounting SwiftUI.
**Output**: Core policy plus app sidebar copy/visibility changes. The diagnostic command `swift run OuroWorkbench --write-e2e-state sidebar-session-controls /tmp/workspace-state.json` writes a state containing one workspace named `Fixture Workspace` and one trusted auto-resume terminal agent named `Fixture Running Session`.
**Acceptance**: Unit 3a tests pass; `swift build` succeeds; `rg -n 'Section\\(\"Groups\"\\)|New Group|Move to Group|Delete Terminal Group|Groups with terminals' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` returns no primary user-facing sidebar/header strings.

### ⬜ Unit 3c: Sidebar Workspace Policy - Coverage & Refactor
**What**: Run `swift test --filter WorkbenchSurfacePolicyTests` and `swift build`. Keep any refactor limited to `WorkbenchSurfacePolicy` naming and call sites already changed in Unit 3b.
**Output**: Test/build output saved to `2026-06-14-1420-doing-factory-reset-setup-flow/unit-3-sidebar-policy.log`.
**Acceptance**: Policy branches for setup mode, normal mode, healthy recovery, and actionable recovery are covered and green.

### ⬜ Unit 4a: Running Session Controls Policy - Tests
**What**: Add failing tests for a pure running-session chrome policy in `Tests/OuroWorkbenchCoreTests/WorkbenchSurfacePolicyTests.swift`. Cover visible primary actions for running, stopped, archived, and recoverable sessions.
**Output**: Tests require running sessions to expose only `stop` as a primary action and to expose `focus`, `redraw`, `restart`, `controlC`, `escape`, and `eof` only as advanced session controls.
**Acceptance**: Tests fail before implementation because the policy does not exist or still treats low-level controls/restart as primary.

### ⬜ Unit 4b: Running Session Controls Policy - Implementation
**What**: Extend `Sources/OuroWorkbenchCore/WorkbenchSurfacePolicy.swift` for session chrome actions and update `RunningSessionHeaderControls` in `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` so the header shows a visible Stop button plus a labeled `Session Controls` menu containing Focus, Redraw, Restart, Ctrl-C, Esc, EOF, Copy Launch Command, and Open Working Directory.
**Output**: Header UI no longer shows the screenshot's row of unlabeled low-level icons; advanced actions remain reachable with labels/tooltips.
**Acceptance**: Unit 4a tests pass; `swift build` succeeds; `rg -n 'RunningSessionHeaderControls|Session Controls|Ctrl-C|EOF|Restart' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` shows the actions under the menu implementation, not as separate primary image buttons.

### ⬜ Unit 4c: Running Session Controls Policy - Coverage & Refactor
**What**: Run `swift test --filter WorkbenchSurfacePolicyTests` and `swift build`. Keep refactor scoped to the policy enum/action naming and `RunningSessionHeaderControls`.
**Output**: Test/build output saved to `2026-06-14-1420-doing-factory-reset-setup-flow/unit-4-session-controls.log`.
**Acceptance**: Running/stopped/archived/recoverable action policies are covered and green.

### ⬜ Unit 5a: Boss-Led Onboarding Copy - Tests
**What**: Add failing tests for a pure onboarding narrative helper. Target `Tests/OuroWorkbenchCoreTests/OnboardingTests.swift` or a new `Tests/OuroWorkbenchCoreTests/OnboardingNarrativeTests.swift`.
**Output**: Tests require copy for boss-ready welcome, scan intro, proposal summary, ambiguous/low-confidence explanation, and duplicate external session cleanup guidance.
**Acceptance**: Tests fail before implementation because `WorkbenchOnboardingNarrative` does not exist or old copy omits boss-led import/cleanup language.

### ⬜ Unit 5b: Boss-Led Onboarding Copy - Implementation
**What**: Add `Sources/OuroWorkbenchCore/WorkbenchOnboardingNarrative.swift` and use it in `OnboardingWelcomePage`, `OnboardingBootstrapView`, `OnboardingGroupProposalView`, `OnboardingSessionPreviewSheet`, and import summary/banner copy in `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`.
**Output**: Onboarding copy says the boss can see this Mac, will scan local coding-agent sessions, will ask before unclear imports, and will guide cleanup of duplicates after Workbench resumes approved sessions.
**Acceptance**: Unit 5a tests pass; `swift build` succeeds; source inspection confirms setup/import copy no longer frames import as a static app-only wizard.

### ⬜ Unit 5c: Boss-Led Onboarding Flow Policy - Tests
**What**: Add failing tests for pure onboarding flow decisions in `Tests/OuroWorkbenchCoreTests/OnboardingNarrativeTests.swift`: wizard phase before boss readiness, boss-led import phase after readiness, proposal visual support when candidates exist, ambiguity prompt when low-confidence candidates exist, and duplicate cleanup guidance after import.
**Output**: Tests define `WorkbenchOnboardingFlowPolicy` inputs and expected phase/prompt values.
**Acceptance**: Tests fail before implementation because flow policy does not exist or old readiness/import states do not distinguish boss-led phases.

### ⬜ Unit 5d: Boss-Led Onboarding Flow Policy - Implementation
**What**: Add `WorkbenchOnboardingFlowPolicy` in `Sources/OuroWorkbenchCore/WorkbenchOnboardingNarrative.swift` and wire `WorkbenchOnboardingSheet.advance`, `primaryActionTitle`, `OnboardingBootstrapView`, and `handleOnboardingInstruction` through it where those functions choose setup/import/arrange behavior.
**Output**: Traditional wizard remains limited to boss setup/readiness; after readiness, the boss-led import phase drives scan/proposal/arrange and duplicate cleanup messaging.
**Acceptance**: Unit 5c tests pass; `swift build` succeeds; source inspection shows `OnboardingBootstrapView` using policy/narrative values for scan, proposal, ambiguity, and cleanup text.

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
**What**: Create and run `worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow/validate-reset-setup.sh`. The script must run these exact validation steps with an isolated home:

```bash
ART="worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow"
APP="$HOME/Applications/Ouro Workbench.app"
TEST_HOME="$PWD/$ART/live-reset-home"
rm -rf "$TEST_HOME"
mkdir -p "$TEST_HOME/Library/Application Support/OuroWorkbench"
printf 'reset\n' > "$TEST_HOME/Library/Application Support/OuroWorkbench/force-first-run-setup"
env HOME="$TEST_HOME" "$APP/Contents/MacOS/OuroWorkbench" > "$ART/e2e-reset-app.log" 2>&1 &
PID=$!
sleep 6
screencapture -x "$ART/e2e-reset-setup.png"
STATE="$TEST_HOME/Library/Application Support/OuroWorkbench/workspace-state.json"
test -f "$STATE"
plutil -p "$STATE" > "$ART/e2e-reset-state.txt"
! grep -F 'Local Shell' "$STATE"
! test -e "$TEST_HOME/Library/Application Support/OuroWorkbench/force-first-run-setup"
kill "$PID" >/dev/null 2>&1 || true
wait "$PID" >/dev/null 2>&1 || true
```

**Output**: Save notes and screenshots to `2026-06-14-1420-doing-factory-reset-setup-flow/e2e-reset-setup.md`.
**Acceptance**: Artifact has `PASS`; next launch presents onboarding/setup, no default `Local Shell` is selected/launched before setup/import, and `workspace-state.json` does not contain a reset-created shell-only dead end.

### ⬜ Unit 6e: Live Sidebar And Session Controls E2E
**What**: Create and run `worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow/validate-sidebar-session-controls.sh`. The script must launch the installed app with an isolated home seeded by the Unit 3b diagnostic fixture, capture a screenshot, and run these exact commands:

```bash
ART="worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow"
APP="$HOME/Applications/Ouro Workbench.app"
TEST_HOME="$PWD/$ART/live-sidebar-home"
rm -rf "$TEST_HOME"
mkdir -p "$TEST_HOME/Library/Application Support/OuroWorkbench"
mkdir -p "$TEST_HOME/Library/Preferences"
"$APP/Contents/MacOS/OuroWorkbench" --write-e2e-state sidebar-session-controls "$TEST_HOME/Library/Application Support/OuroWorkbench/workspace-state.json" > "$ART/sidebar-fixture.log" 2>&1
defaults write "$TEST_HOME/Library/Preferences/com.ourostack.workbench" ouro.workbench.autoLaunchResumableOnStartup -bool true
env HOME="$TEST_HOME" "$APP/Contents/MacOS/OuroWorkbench" > "$ART/e2e-sidebar-app.log" 2>&1 &
PID=$!
sleep 6
screencapture -x "$ART/e2e-sidebar-session-controls.png"
plutil -p "$TEST_HOME/Library/Application Support/OuroWorkbench/workspace-state.json" > "$ART/e2e-sidebar-state.txt"
grep -F 'Fixture Workspace' "$TEST_HOME/Library/Application Support/OuroWorkbench/workspace-state.json"
grep -F 'Fixture Running Session' "$TEST_HOME/Library/Application Support/OuroWorkbench/workspace-state.json"
rg -n 'Section\("Groups"\)|New Group|Move to Group|Delete Terminal Group|Groups with terminals' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift && exit 1
rg -n 'Session Controls' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
rg -n 'Label\("Stop", systemImage: "stop.fill"\)' Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift
kill "$PID" >/dev/null 2>&1 || true
wait "$PID" >/dev/null 2>&1 || true
```

**Output**: Save notes and screenshots to `2026-06-14-1420-doing-factory-reset-setup-flow/e2e-sidebar-session-controls.md`.
**Acceptance**: Artifact has `PASS`; visible primary labels use `Workspaces`/`Boss`; healthy recovery is hidden; running-session header shows Stop and labeled `Session Controls`; focus/redraw/restart/Ctrl-C/Esc/EOF are not a row of primary icon buttons.

### ⬜ Unit 6f: Live Import Scanner E2E
**What**: Run the read-only diagnostic added in Unit 2b against the installed current-source app and verify source coverage with `jq`:

```bash
ART="worker/tasks/2026-06-14-1420-doing-factory-reset-setup-flow"
APP="$HOME/Applications/Ouro Workbench.app"
"$APP/Contents/MacOS/OuroWorkbench" --dump-recent-sessions-json > "$ART/e2e-import-scanner.json"
jq -e '[.[] | select(.source == "openAICodex") | select((.evidencePaths // []) | map(test("/\\.codex/(archived_sessions|manual-recovery-)")) | any)] | length >= 1' "$ART/e2e-import-scanner.json"
jq -e '[.[] | select(.source == "claudeCode") | select((.evidencePaths // []) | map(test("/\\.claude/(tasks|projects)")) | any)] | length >= 1' "$ART/e2e-import-scanner.json"
jq -r '.[] | [.source, .title, .workingDirectory, (.resumeCommand | join(" ")), (.evidencePaths | join(","))] | @tsv' "$ART/e2e-import-scanner.json" > "$ART/e2e-import-scanner.tsv"
```

**Output**: Save scanner output summary to `2026-06-14-1420-doing-factory-reset-setup-flow/e2e-import-scanner.md`.
**Acceptance**: Artifact has `PASS`; scanner reports candidates from at least one real or synthetic Codex archived/manual-recovery source and one Claude task/project source, with evidence paths and resume commands, without mutating any external harness store.

## Execution

- **TDD strictly enforced**: tests -> red -> implement -> green -> refactor
- Commit after each phase (1a, 1b, 1c)
- Push after each unit complete when a remote is configured
- Run full test suite before marking unit done
- **All artifacts**: Save outputs, logs, data to `./2026-06-14-1420-doing-factory-reset-setup-flow/`
- **Fixes/blockers**: Spawn sub-agent immediately; do not ask the user
- **Decisions made**: Update docs immediately, commit right away

## Progress Log

- 2026-06-14 14:42 Created from planning doc
