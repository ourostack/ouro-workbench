# Slice ②b — Blast-radius sweep (re-verified at HEAD 3e45d03)

Exhaustive grep of `Tests/` and `Sources/` for: `"Terminals in"`, `terminalsSectionTitle`,
`workspaceSectionTitle`, `SidebarProjectRow`, `Text(project.rootPath)`, `setupWorkspaceName`,
`state.projects` (render uses), `newWorkspaceTitle`, `model.sessionEntries`, and every
`source.contains(`/`appSource()` guard referencing the sidebar/terminals/projects wiring.

## A. Source-level sidebar-render guards that WILL BREAK (must be re-pointed in-slice)

1. **`Tests/OuroWorkbenchCoreTests/WorkspaceHomeNamingTests.swift:52-65`** —
   `testSidebarTerminalsSectionUsesTheRelationshipLabelNotTheBareName`.
   Asserts App source `.contains("Section(WorkbenchSurfacePolicy.terminalsSectionTitle(workspaceName: model.selectedProject?.name))")`.
   The "Terminals in <name>" section is being removed → this guard breaks. RE-POINT to the new
   workspace-rows wiring (assert `WorkspaceSidebarPresentation.resolve(` present + the
   `terminalsSectionTitle(` section ABSENT).
   - **Lines 26-48** (`terminalsSectionTitle` VALUE tests) stay valid ONLY if the function is kept.
     Unit 4 decides: delete `terminalsSectionTitle` (no remaining caller) + remove these value tests.
   - **Lines 9-22** (`setupWorkspaceName == "Home"`) stay GREEN (DB6 — backing default not renamed).

2. **`Tests/OuroWorkbenchCoreTests/WorkbenchSurfacePolicyTests.swift:25-38`** —
   `testAppWorkspaceCopyIsWiredThroughSurfacePolicy`.
   - `:29` `source.contains("Section(WorkbenchSurfacePolicy.workspaceSectionTitle)")` — STAYS valid:
     the new Workspaces section header still uses `WorkbenchSurfacePolicy.workspaceSectionTitle`
     ("Workspaces"). (The constant is reused; only the ForEach body changes.)
   - `:30` `source.contains("SidebarActionRow(title: WorkbenchSurfacePolicy.newWorkspaceTitle")` —
     BREAKS: DB8 removes the "New Workspace" action row. DROP this assertion.
   - `:28` (`bossSectionTitle`) and `:31` (`shouldShowRecovery`) STAY valid (unchanged surfaces).
   - Lines 6-22 (string-constant value tests for `workspaceSectionTitle`/`newWorkspaceTitle`/etc.)
     STAY GREEN — the constants are kept; only the App USE of `newWorkspaceTitle` is removed.

## B. Constraint guards (do NOT break under DB1 — must NOT be regressed)

3. **`Tests/OuroWorkbenchCoreTests/PersistenceSalvageWiringTests.swift:119-238`** — asserts `load()`
   restores `selectedProjectID` and its `didSet` routes through `save()`. CONSTRAINT: ②b must NOT
   remove `selectedProjectID` or its `didSet`-save (DB1). Adding `selectedWorkspaceID` is fine as long
   as `selectedProjectID` + its didSet save stay intact. STAYS GREEN.

4. **`Tests/OuroWorkbenchCoreTests/WorkbenchBootstrapperTests.swift:9-11,22-23,41-45,261`** —
   `state.projects.map(\.name) == ["Home"]`, rootPath assertions. STAY GREEN (DB1 keeps backing
   `WorkbenchProject`/`projectId`; bootstrapper unchanged). Any change here = scope leak → STOP.

5. **`Tests/OuroWorkbenchCoreTests/WorkspaceRootValidationTests.swift:136-150`** — asserts
   App `createGroup`/`renameGroup` validate the root on disk. STAYS GREEN: `createGroup` still called
   at App `:9751` (new-group sheet submit) + `:17709` (boss MCP `createGroup` action); `renameGroup`
   still called at `:9816` (edit-group sheet submit). Backing affordances preserved under DB1.

6. **`Tests/OuroWorkbenchCoreTests/WorkspaceNameDerivationTests.swift:78-80`** — asserts the
   new-group SHEET autofills the name on `.onChange(of: rootPath)`. The sheet (`:515`) stays; only the
   SIDEBAR action ROW that opened it (`:3127`) is removed. STAYS GREEN.

## C. Cosmetic-only (no assertion fails; update stale line ref)

7. **`Tests/OuroWorkbenchCoreTests/OnboardingBossChoiceRowAccessibilityWiringTests.swift:12`** —
   a `///` doc-comment: "`SidebarProjectRow` ~:3182". It slices `OnboardingBossChoiceRow`, NOT
   `SidebarProjectRow`, so NO assertion fails. If Unit 2b deletes `SidebarProjectRow`, update this
   stale comment (drop the `~:3182` reference or re-word to a still-existing example like `SidebarAgentRow`).

## D. Verified BUMP-SAFE — fixture-only, do NOT touch (STAY GREEN under DB1)

- `WorkspaceSummaryTests.swift`, `OnboardingTests.swift`, `AutonomyReadinessTests.swift:182`
  (`state.projects[0].id`), `BossAgentPromptBuilderTests.swift` — use `project.id`/`rootPath` ONLY as
  fixture inputs to construct `ProcessEntry`/`WorkbenchProject` (no sidebar-render assertions).
- `WorkspaceStructureTests.swift:424-432` — reads `state.projects` as a non-destructive-migration
  invariant; backing model unchanged → STAYS GREEN.
- `WorkspaceExportImportRobustnessWiringTests.swift` — import/export robustness; unrelated.

## E. App-source render sites to CHANGE (no test, but the edit target)

- `OuroWorkbenchApp.swift:3098-3130` — "Workspaces"(=projects) `Section` → `ForEach(model.state.projects)`
  → `SidebarProjectRow` + `SidebarActionRow(newWorkspaceTitle)`. REPLACE with `state.workspaces` render.
- `OuroWorkbenchApp.swift:3131-3168` — "Terminals in <name>" `Section` → `ForEach(model.sessionEntries)`
  → `TerminalAgentRow`. REMOVE (tabs move to the top tab-strip).
- `OuroWorkbenchApp.swift:3218-3308` — `struct SidebarProjectRow` (PWD dump `Text(project.rootPath)` @ :3248).
  Instantiated ONLY at :3100 → DEAD after removal → delete the struct.
- `OuroWorkbenchApp.swift:3169-3184` (Archived) + `:3189-3213` (Recovery) — KEEP (preserve).
- `OuroWorkbenchApp.swift:365-398` (detail column) — MOUNT the new cmux tab-strip above the detail Group.
- `OuroWorkbenchApp.swift:11389` — `private var allSessionEntries` → expose non-private accessor (DB9).

## F. Backing-model methods that lose their ONLY sidebar caller (kept under DB1; Swift won't warn)

Removing the projects section removes the sole call sites of these VM methods; they remain compilable
(Swift does not warn on uncalled instance methods) and stay as backing-model surface under DB1:
- `beginEditingGroup` (only caller :3110) — KEEP (DB1; reachable later via ②d affordances).
- `requestDeleteGroup` (only caller :3113), `setGroupColorTag` (:3116), `moveGroups` (:3125) — KEEP.
- `isNewGroupSheetPresented = true` (only trigger :3128 removed) — the `@Published var` + `.sheet` (:515)
  stay; the sheet is simply no longer reachable from the sidebar in ②b (manual create is ②d / FORK #6).
- `terminalCount(in:)` / `totalTerminalCount(in:)` (callers :3102-3105) — KEEP (DB1; used by accessibility/menus).

## Completeness assertion
The ONLY source-level guards asserting sidebar-render wiring are A1 + A2. All other matches are
value/constant tests (stay), constraint guards (must-not-break), fixture-only (bump-safe), or cosmetic.
This matches the ②a-style "literal blast radius" discipline; no missed sidebar-render source-guard found.
