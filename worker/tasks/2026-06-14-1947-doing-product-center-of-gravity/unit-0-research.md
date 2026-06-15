# Unit 0 Research: Product Center Of Gravity

## Branch And Status

- Branch: `worker/product-center-of-gravity`
- Status at start: clean worktree
- Source-of-truth skill check:
  - `subagents/work-planner.md` missing; no repo-local planner skill file to sync.
  - `subagents/work-doer.md` missing; no repo-local doer skill file to sync.

## Target Files

- `Sources/OuroWorkbenchCore/WorkbenchBootstrapper.swift`
- `Sources/OuroWorkbenchCore/CustomTerminalSession.swift`
- `Sources/OuroWorkbenchCore/RecoveryPlanner.swift`
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`
- `Sources/OuroWorkbenchMCP/main.swift`
- `Sources/OuroWorkbenchCore/WorkbenchScenarioMatrix.swift`
- `Sources/OuroWorkbenchScenarioVerifier/main.swift`
- `Tests/OuroWorkbenchCoreTests/WorkbenchBootstrapperTests.swift`
- `Tests/OuroWorkbenchCoreTests/WorkbenchLaunchDiagnosticsTests.swift`
- `Tests/OuroWorkbenchCoreTests/CustomTerminalSessionTests.swift`
- `Tests/OuroWorkbenchCoreTests/BossWorkbenchActionAuthorizerTests.swift`
- `Tests/OuroWorkbenchCoreTests/WorkbenchScenarioMatrixTests.swift`
- `scripts/generate-workbench-5000-matrix.rb`
- `README.md`
- `docs/guide.md`
- `docs/roadmap.md`
- `docs/workbench-surface-spec.md`

## Current Drift To Remove

- `WorkbenchDefaults` defaults to `projectName: "This Mac"` and `includeLocalShell: true`.
- `WorkbenchBootstrapper.bootstrappedState` inserts or repairs `BuiltInWorkbenchSessions.localShell`.
- `BuiltInWorkbenchSessions` defines a trusted, auto-resuming `/bin/zsh -l` row named `Local Shell`.
- App startup still has `launchDefaultShellIfNeeded()` special-casing auto-launchable `Local Shell`.
- MCP `currentState()` loads through the same bootstrapper defaults, so it can synthesize `Local Shell`.
- `CustomTerminalSessionManager.isCustomSession` only accepts `.terminalAgent`, which makes persisted `.shell` rows second-class for edit/archive/restore/delete surfaces.
- Scenario fixtures and generator still use `local_shell` / `Local Shell` as the canonical shell identity.
- Current docs still include old guidance around a persistent default `Local Shell`.

## Decisions

- Persisted `.shell` rows are compatibility/user state and must be preserved, including rows still named `Local Shell`.
- No empty bootstrap, first-run setup, reset, app fallback, MCP read, or startup path may create, repair, select, or launch a built-in `Local Shell`.
- Explicit user-owned shell auto-resume remains supported through the normal `RecoveryPlanner.autoLaunchEligibleEntries` preference path.
- Scenario shell coverage remains, but the canonical key/display becomes `user_shell` / `User Shell` and the fixture must remain `kind == .shell`.
