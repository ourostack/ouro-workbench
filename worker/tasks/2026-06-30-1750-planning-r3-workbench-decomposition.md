# Goal

Extract the next Workbench shell-adjacent slices out of `WorkbenchViews.swift` so command/update/settings behavior is easier to audit and cannot hide inside the giant app view file. Keep the change incremental, behavior-preserving, and covered by the existing Workbench view/view-model characterization tests.

## Scope

### In Scope

- Move `WorkbenchMenuCommand`, `dispatchMenuCommand`, and their tiny support types out of `Sources/OuroWorkbenchAppViews/WorkbenchViews.swift` into a dedicated command dispatch source file in `OuroWorkbenchAppViews`.
- Move `CommandPaletteSheet` and its private row/section helpers out of `WorkbenchViews.swift` into a dedicated command palette source file in `OuroWorkbenchAppViews`.
- Move `SettingsSheet` and `SettingsSection` out of `WorkbenchViews.swift` into a dedicated settings source file in `OuroWorkbenchAppViews`.
- Preserve current user-visible behavior, access levels, menu shortcuts, command execution semantics, settings bindings, and update/settings sheet wiring.
- Run targeted characterization tests around dispatch, command palette, settings, release update/settings tail behavior, and the shell boundary script; then run the repo's required local validation before PR merge.
- Keep generated package artifacts and unrelated files untouched.

### Out of Scope

- Signing, notarization, TestFlight, App Store, or release-channel work.
- Moving reusable behavior into `ouro-native-apple-app-shell`; this slice should expose app-local boundaries first and only identify future shell candidates if code proves shared.
- Rewriting Workbench state management, command IDs, settings UX, or update/install policy.
- Broad cleanup of `WorkbenchViewModel.swift` beyond imports or access needed for the extracted views to compile.
- Changing `Package.resolved` or dependency versions.

## Completion Criteria

- [ ] `WorkbenchViews.swift` loses the extracted command dispatch, command palette, and settings sheet declarations while all call sites continue compiling.
- [ ] New files in `Sources/OuroWorkbenchAppViews/` own those declarations with no new shell-boundary allowlist rows.
- [ ] Existing tests for `DispatchMenuCommand`, `CommandPaletteSheet`, `CommandPaletteSheetInteraction`, `SettingsSheet`, and `SettingsSheetInteraction` pass after the extraction.
- [ ] `scripts/check-shell-boundary.sh` passes.
- [ ] Required Workbench local validation and GitHub CI pass for the PR.
- [ ] PR is merged to `main`, branch/worktree cleanup is complete, and no generated Packages noise remains.

## Code Coverage Requirements

- Preserve 100% coverage expectations for every moved declaration by running the existing interaction/snapshot tests that cover those regions.
- Add tests only if extraction changes visibility or creates a new helper that is not already covered by the moved surface tests.
- Do not add coverage exclusions or widen CI allowlists.

## Open Questions

- None requiring human input under the autopilot mandate. If the extraction exposes a reusable shell behavior candidate, record it as a future candidate rather than expanding this PR.

## Decisions Made

- Use branch `worker/r3-workbench-decomposition` in dedicated worktree `/Users/arimendelow/Projects/ouro-workbench-worker-r3-decomposition`.
- Treat this as a behavior-preserving decomposition PR, not a feature PR: move source declarations first, keep test expectations unchanged, then use existing tests as the reviewer gate.
- Keep the moved files in `OuroWorkbenchAppViews`, not `OuroWorkbenchShellAdapter`, because these declarations still depend on `WorkbenchViewModel` and app-only SwiftUI state.
- Prioritize command/settings surfaces before deeper update/diagnostics view-model extraction because those are the shell-adjacent surfaces currently embedded directly in `WorkbenchViews.swift`.

## Context / References

- Roadmap source: `/Users/arimendelow/desk/ouro-md/native-app-shell-next-roadmap/task.md`, lane R3.
- Primary repo: `/Users/arimendelow/Projects/ouro-workbench`.
- Shared shell context repo: `/Users/arimendelow/Projects/ouro-native-apple-app-shell`.
- Repo instructions: `AGENTS.md` says shared-looking Workbench shell glue belongs in `Sources/OuroWorkbenchShellAdapter/`, but Workbench-specific mappings and app-bound views stay in Workbench.
- Existing shell adapter: `Sources/OuroWorkbenchShellAdapter/WorkbenchShellContract.swift`, `Sources/OuroWorkbenchShellAdapter/WorkbenchShellPresentation.swift`.
- Current large files: `Sources/OuroWorkbenchAppViews/WorkbenchViews.swift` is about 10.8k lines; `Sources/OuroWorkbenchAppViews/WorkbenchViewModel.swift` is about 11.2k lines.
- Existing coverage surfaces: `Tests/OuroWorkbenchAppViewsTests/DispatchMenuCommandTests.swift`, `CommandPaletteSheetTests.swift`, `CommandPaletteSheetInteractionTests.swift`, `SettingsSheetTests.swift`, `SettingsSheetInteractionTests.swift`, plus release/update/view-model tail tests.

## Notes

- Baseline reconnaissance found the command palette and settings surfaces already have explicit tests and snapshot coverage. That makes them good extraction targets: the PR can prove no behavior drift without inventing new product behavior.
- The update panel is already a thin adapter over `WorkbenchShellUpdatePanelView`; this slice should not disturb its behavior unless compile boundaries require a tiny move.

## Progress Log

- 2026-06-30 17:50 Created planning doc for R3 Workbench decomposition.
- 2026-06-30 17:50 Planning reviewer gate converged: source files and tests exist, target declarations are in `WorkbenchViews.swift`, and no unresolved planning question blocks conversion.
