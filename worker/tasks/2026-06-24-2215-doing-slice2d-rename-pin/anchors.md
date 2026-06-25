# Slice ②d — Verified anchors (at HEAD d376564, branch feat/slice2d-rename-pin)

Re-verify at execution start (line numbers drift); these were confirmed during conversion.

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
