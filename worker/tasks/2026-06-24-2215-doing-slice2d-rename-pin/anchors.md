# Slice ②d — Verified anchors (at HEAD d376564, branch feat/slice2d-rename-pin)

Re-verify at execution start (line numbers drift); these were confirmed during conversion.

## Unit 0 execution-time re-verification (HEAD 1f831a9 on feat/slice2d-rename-pin)
All anchors below RE-CONFIRMED at execution start. Drift / clarifications recorded:
- `WorkspaceSidebarRow` struct @ :3158 (body Button @ :3163, `Text(row.effectiveName)` @ :3170). ✔
- Instantiation @ :3091 (`WorkspaceSidebarRow(row: row, model: model)`). ✔
- `WorkspaceTabStrip` @ :3223; `tabButton(_:)` @ :3308 (`Text(tab.effectiveTabName)` @ :3317). ✔
- `TerminalRowContextMenu` @ :3497 (mirror `.contextMenu { Button { … } label: { Label(…) } }`). ✔
- `togglePin(for:)` @ :11421 / `isPinned(_:)` @ :11431 — NOTE: `togglePin` persists via `try store.save(state)` DIRECTLY (catch → errorMessage), it does NOT call the `save()` wrapper. The `②d` thin wrappers will call the canonical `save()` @ :20309 (`@discardableResult private func save() -> Bool`) per D2d-7 (cleaner + batched-save-aware). The source-guard for ②d wrappers asserts the Core mutator + `save()` (not `store.save`).
- Canonical persistence: `WorkbenchViewModel.save()` @ :20309. (A second unrelated `save()` @ :10071 is inside an edit-sheet view — ignore.)
- `WorkbenchViewModel` @ :10397; `@Published var selectedEntryID` @ :10412; `selectedWorkspaceID` @ :10461; `activeWorkspaceRow` @ :11481; `workspaceSidebarModel` @ :11470.
- Chord dispatcher: `WorkbenchMenuCommand` enum @ :128; `handleMenuCommand` switch @ :251; `.commands { CommandMenu("Terminal") { … } }` @ :41-107; `menuCommand(_:_:_:_:)` helper @ :110. ②d adds `.renameWorkspace`/`.renameTab` cases + `menuCommand("Rename Workspace…", .renameWorkspace, "r", [.command, .shift])` / `menuCommand("Rename Tab…", .renameTab, "r")` + switch arms targeting active workspace / selected tab (D2d-8).
- `import OuroWorkbenchCore` (plain) @ :4 → new Core seams MUST be public (D2d-6). ✔
- No `.keyboardShortcut("r"` anywhere (D2d-5 free). ✔
- Core model: `Workspace` @ :678 (`autoName` :682, `nameOverride` :685, `isPinned` :687, `effectiveName` :728); `ProcessEntry.tabNameOverride` @ :262, `effectiveTabName` @ :337. `public extension WorkspaceState` @ :898 (precedent `applyAutomaticBossDefaults` @ :930). ✔
- `WorkspaceSidebarPresentation.resolve` @ :119; pinned-first @ :126; `WorkspaceRow` @ :70 — has `effectiveName`/`isPinned`, **lacks `nameOverride`** → Unit 4b additive field CONFIRMED needed; `resolve` maps the row @ :164-173.
- Test helpers: `appSource()` @ :232 + `repoRoot()` @ :240 in WorkspaceSidebarWiringTests.swift (copy verbatim). Chord-targets-active example NavCheckInWiringTests.swift @ :62-72. UISurfaceTest `fittingSize`+assert-seam @ :96-241.
- Coverage allowlist (`Scripts/coverage-allowlist.txt`): only `BossAgentMCPClient.swift 1 2` + `SessionActivityReader.swift 0 1`. MUST NOT grow.

## Render sites (App SwiftUI — attach menus/editors here)
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:3158` — `struct WorkspaceSidebarRow: View` (workspace context menu + inline editor host). Its `Button { model.selectedWorkspaceID = row.id } label: { HStack … Text(row.effectiveName) … }` body is where the `.contextMenu` attaches and where the label↔editor swap happens.
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:3091` — render site where `WorkspaceSidebarRow(row: row, model: model)` is instantiated (a `.contextMenu { }` can attach here OR inside the struct).
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:3223` — `struct WorkspaceTabStrip: View`.
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:3308` — `private func tabButton(_ tab: ResolvedTab) -> some View` (tab context menu + inline editor host; renders `Text(tab.effectiveTabName)`).
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:3497` — `struct TerminalRowContextMenu: View` (PATTERN to mirror: `.contextMenu { Button { … } label: { Label(text, systemImage:) } }`, Divider, `.disabled(…)`).

## Mirror targets (existing pin pattern for ProcessEntry)
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:11421` — `func togglePin(for entry: ProcessEntry)`.
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:11431` — `func isPinned(_ entry: ProcessEntry) -> Bool`.

## Core model (mutators target these — already exist)
- `Sources/OuroWorkbenchCore/WorkspaceModels.swift:678` — `struct Workspace` (`autoName`, `nameOverride: String?`, `isPinned: Bool`, `tabIds`; `effectiveName == nameOverride ?? autoName` @ :728; empty override honored per DA4 @ :673-674).
- `Sources/OuroWorkbenchCore/WorkspaceModels.swift:262` — `ProcessEntry.tabNameOverride: String?`; `effectiveTabName == tabNameOverride ?? name` @ :337.
- `Sources/OuroWorkbenchCore/WorkspaceModels.swift:~907` — `public extension WorkspaceState { mutating func … }` (ADD the new public mutators in THIS block — D2d-6).
- `Sources/OuroWorkbenchCore/WorkspaceModels.swift:930` — `applyAutomaticBossDefaults()` (pure-mutator-on-state precedent).

## Seam (pin re-sort is automatic — D2d-4)
- `Sources/OuroWorkbenchCore/WorkspaceSidebarPresentation.swift:118` — `static func resolve(workspaces:entries:selectedWorkspaceId:)`; pinned-first @ :126 (`filter(\.isPinned) + filter { !$0.isPinned }`).
- `WorkspaceRow` fields @ :71-78 — has `effectiveName`/`isPinned` but **NOT `nameOverride`**. Unit 4b adds `nameOverride: String?` to `WorkspaceRow` + its `resolve` mapping if the menu needs `nameOverride != nil` from the row (extend `WorkspaceSidebarPresentationTests` for the new field).
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:11470` — `var workspaceSidebarModel` (computed; re-resolves every render → pin toggle re-sorts automatically).

## Persistence / state mutation (App side)
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:10397` — `final class WorkbenchViewModel: ObservableObject` (App module; `@Published var state` @ :10398).
- `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift:20308` — `@discardableResult private func save()` (thin wrappers call this after mutating `state`).
- App imports Core with PLAIN `import OuroWorkbenchCore` @ :4 (NOT @testable) → new Core seams MUST be `public` (D2d-6).

## Test patterns to mirror
- `Tests/OuroWorkbenchCoreTests/WorkspaceStructureTests.swift` — Core model test style (`@testable import OuroWorkbenchCore`; `testEffectiveName…`).
- `Tests/OuroWorkbenchCoreTests/WorkspaceSidebarWiringTests.swift:232` — `appSource()` + `:240` `repoRoot()` source-guard helpers (copy verbatim into the new wiring test file).
- `Tests/OuroWorkbenchCoreTests/NavCheckInWiringTests.swift:62-72` — keyboard-chord-targets-active-entry source-guard example (mirror for ⌘R/⇧⌘R targeting active workspace/tab).
- `Sources/OuroWorkbenchApp/UISurfaceTest.swift:225-241` — render-smoke pattern (`fittingSize(view, constrainedTo:)` → assert positive size; mutate `model.state` → assert seam).

## Keyboard shortcuts — free (D2d-5)
- No existing `.keyboardShortcut("r", …)` in `OuroWorkbenchApp.swift`. `⌘R` and `⇧⌘R` are unbound.
