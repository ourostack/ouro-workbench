# Goal

Fix the post-factory-reset first-run experience so Workbench reliably returns the user to setup/import instead of silently recreating a confusing built-in shell-only workspace.

The reset path should feel like a real factory reset for Workbench-owned state: after reset, the next launch must present setup/import, avoid an undeletable "Local Shell" dead end, and make recent Claude/Codex/Copilot sessions discoverable enough that the user can proceed.

# Scope

## In Scope

- Diagnose and fix why `Reset to Factory Defaults` can relaunch into the main workbench instead of the setup/import flow on a machine whose Ouro boss configuration is already healthy.
- Change first-run/bootstrap behavior so a post-reset workspace does not leave the user trapped with only a built-in `Local Shell` entry and no delete affordance.
- Either omit the built-in local shell during setup-mode first-run or make the fallback shell user-removable in the relevant first-run state, based on the least surprising existing model.
- Ensure setup/import can be forced by reset with an explicit, short-lived marker rather than relying only on readiness/config-gap inference.
- Extend recent-session import discovery to include additional local Codex/Claude stores observed on this machine:
  - Codex archived JSONL sessions under `~/.codex/archived_sessions/`.
  - Codex rollout/manual-recovery JSONL session files under `~/.codex/manual-recovery-*`.
  - Claude task/session records under `~/.claude/tasks/` when they can be converted into safe resume candidates.
- Preserve existing import coverage for `~/.claude/projects`, live Claude processes, cmux state, Codex SQLite/session index, shell history, and existing Workbench sessions.
- Add focused tests for reset/setup forcing, built-in shell behavior, and the new importer stores.
- Update user-facing copy if needed so the reset dialog and first-run state match what the app actually does.

## Out of Scope

- Deleting or modifying Claude, Codex, Copilot, cmux, shell, or Ouro harness-owned history during factory reset.
- Claiming that agent processes survive reset or reboot; imported sessions must remain resumable/respawnable with evidence, not "still running" unless a live process is actually present.
- Broad redesign of the onboarding UI layout beyond what is necessary to unblock setup/import after reset.
- Shipping unrelated Workbench feature work or refactoring the large app file outside the touched reset/onboarding/import paths.
- Treating Claude Code, Codex, or Copilot as fixed app modes; they remain detected terminal identities.

# Completion Criteria

- After `Reset to Factory Defaults`, the next launch presents the setup/import flow even when the selected boss/harness readiness would otherwise be `.ready`.
- A fresh/post-reset workspace does not show an undeletable `Local Shell` as the only apparent thing to do before setup/import.
- If a fallback local shell is still present somewhere, it has a clear, tested removal/archive path or is intentionally hidden/deferred until after setup/import.
- The recent-session scanner returns candidates from representative Codex archived JSONL/manual-recovery files and representative Claude task records, with evidence paths and resume commands.
- Existing scanner tests for Claude project history, live cmux/Claude panels, Codex SQLite/index, shell history, and grouping still pass.
- Factory reset tests prove the explicit setup marker is set/cleared correctly and cannot be immediately overwritten by quit-time save.
- `swift test` passes for the touched targets.

# Code Coverage Requirements

- Add unit tests in `Tests/OuroWorkbenchCoreTests/WorkbenchFactoryResetTests.swift` or a nearby reset/onboarding test file for the reset setup marker behavior.
- Add or update `WorkbenchBootstrapperTests` to cover first-run/post-reset local-shell behavior.
- Add `OnboardingTests` coverage for new Codex JSONL sources and Claude task-store sources.
- Add app/view-model-level tests only if existing seams allow it without brittle UI automation; otherwise cover through pure core seams and small injectable helpers.

# Open Questions

- Should a normal never-reset first launch still include `Local Shell`, or should all fresh launches defer shell creation until after setup/import? Current diagnosis suggests post-reset setup mode should defer it, while ordinary empty fallback behavior may remain useful.
- Which Claude Desktop app store path is canonical for this machine beyond `~/.claude/tasks` and `~/.claude/projects`? Investigation found `~/.claude/tasks` records locally; no separate `Library/Application Support/Claude*` session store was confirmed yet.
- Should older Codex archived sessions outside the normal lookback be offered in a separate "older sessions" group, or should this patch keep the existing lookback filter for signal quality?

# Decisions Made

- Factory reset should not rely exclusively on readiness/config-gap inference. A reset is an explicit request to re-run setup, so it needs explicit state to force setup on relaunch.
- Workbench reset remains non-destructive to agent-owned history. Importer changes only read local stores and create Workbench session entries pointing at resume commands.
- The current `Local Shell` behavior is the immediate cause of the screenshot: `WorkbenchBootstrapper` recreates it after the reset removes `workspace-state.json`, and `TerminalRowContextMenu` hides delete/edit/archive actions for non-custom built-in entries.
- The installed app at `/Applications/Ouro Workbench.app` is `0.1.125`, while source is `0.1.155`; validation should distinguish current-source behavior from the installed dogfood build.

# Context / References

- `Sources/OuroWorkbenchCore/WorkbenchFactoryReset.swift`
  - `wipeData` moves `workspace-state.json` to `workspace-state.<epoch>.bak.json` and clears one defaults domain.
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`
  - `resetToFirstRun()` calls `WorkbenchFactoryReset.wipeData(...)`, relaunches, and terminates.
  - `shouldPresentOnboardingOnLaunch` currently presents only when readiness is not ready and either `.needsAgent` or a config-gap blocker is present.
  - `TerminalRowContextMenu` only exposes edit/archive/delete when `model.isCustomSession(entry)` is true.
- `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift`
  - `WorkbenchDefaults.includeLocalShell` defaults to true.
  - `bootstrappedState(from:)` inserts `BuiltInWorkbenchSessions.localShell(project:)` into empty state.
  - `BuiltInWorkbenchSessions.localShell` creates a trusted `/bin/zsh -l` shell named `Local Shell`.
- `Sources/OuroWorkbenchCore/Onboarding.swift`
  - `RecentSessionScanner.scan()` currently combines Workbench, cmux/live Claude, `~/.claude/projects`, Codex SQLite/session index, and shell history.
  - Existing scanner does not currently enumerate Codex `archived_sessions` or Claude `tasks`.
- Live machine observations on 2026-06-14:
  - `/Applications/Ouro Workbench.app` reports version `0.1.125` / build `201`.
  - Source HEAD is `v0.1.155`.
  - Current post-reset `workspace-state.json` contains one entry: `Local Shell`, working directory `/Users/arimendelow`, no groups.
  - Multiple backup files exist under `~/Library/Application Support/OuroWorkbench/workspace-state.*.bak.json`, proving reset rotated the file but relaunch recreated fresh state.
  - User screenshot shows `Local Shell` context menu lacks delete/archive/edit actions.

# Notes

- A likely implementation shape:
  - Introduce a reset/setup marker in UserDefaults using a key outside the wiped domain or set it after wiping/synchronizing so relaunch can see it.
  - Clear that marker once onboarding is presented or once the user completes/dismisses the setup flow, depending on existing onboarding semantics.
  - Thread a setup-mode/bootstrap option so post-reset load can call `WorkbenchBootstrapper` with `includeLocalShell: false`, or change built-in local shell classification to allow removal only when it is the reset-created fallback.
  - Add importer helpers for bounded JSONL/file enumeration under Codex archived/manual-recovery paths and Claude task directories.
- Guard against a trap: if the reset marker lives in the same defaults domain removed by `wipeData`, setting order matters. The marker must survive the wipe and only be consumed by the next launch.
- Existing root `AGENTS.md` product truth says terminal/TUI agents are first-class and restart recovery is P0; this plan keeps that intact by importing/resuming rather than replacing terminal agents.

# Progress Log

- 2026-06-14 14:20 Diagnosed reset symptom from live app state and drafted planning doc.
- 2026-06-14 14:20 Ran tinfoil pass: verified referenced files/mechanisms exist and completion criteria are testable.
