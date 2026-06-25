# Doing: Slice ②d — In-App Editing Affordances (Rename Workspace ⇧⌘R, Rename Tab ⌘R, Pin, Remove Custom Name)

**Status**: READY_FOR_EXECUTION
**Execution Mode**: direct
**Created**: 2026-06-24 22:15
**Planning**: ./2026-06-24-1755-planning-workspaces-converged-design.md (master plan; Slice ②d)
**Ideation**: ./2026-06-24-1745-ideation-workspaces-onboarding-bring-back.md (naming model: auto-name + revertible custom override)
**Depends on (landed)**: ./2026-06-24-1832-doing-slice2a-storage-schema.md (Workspace/Tab name model — PR #285) + ./2026-06-24-1946-doing-slice2b-workspaces-sidebar.md (named sidebar + cmux tab-strip — PR #286, merged into `origin/main` @ d376564)
**Deferred — DO NOT depend on**: Slice ②c (dedicated git-init store / opt-in remote). ②d keeps using the existing `WorkbenchStore` / `workspace-state.json`.
**Artifacts**: ./2026-06-24-2215-doing-slice2d-rename-pin/
**Branch**: `feat/slice2d-rename-pin` (off `origin/main` @ d376564 — **do NOT branch again**)

## Execution Mode

- **pending**: Awaiting user approval before each unit starts (interactive)
- **spawn**: Spawn sub-agent for each unit (parallel/autonomous)
- **direct**: Execute units sequentially in current session (default) ← **this slice**

Rationale: the units are tightly coupled (pure Core mutators + a pure rename-commit helper → App context menus → App inline editors → keyboard shortcuts), all touch `OuroWorkbenchApp.swift` + `WorkspaceModels.swift`, and each must leave the strict build / test / coverage / `--uisurfacetest` gates green. The testable LOGIC (model mutators + the empty/whitespace rename-commit decision + the "is rename active / commit / cancel" editor state) is extracted into pure Core seams with strict XCTest TDD (real red→green→100% region). The SwiftUI menus / editors / keyboard-shortcuts are NOT XCTest-visible, so they are guarded by a source-level regression test (`appSource()` + `source.contains(...)`) + a `--uisurfacetest` rendering smoke, exactly as Slices ①/②b and the existing `*WiringTests`. Sequential `direct`, **one commit per unit**.

---

## Objective
Wire the cmux in-app editing affordances to the EXISTING `Workspace` / `ProcessEntry` name model (Slice ②a) and the existing sidebar/tab-strip render sites (Slice ②b). The model already has `Workspace.nameOverride` / `isPinned` / `effectiveName == nameOverride ?? autoName` and `ProcessEntry.tabNameOverride` / `effectiveTabName == tabNameOverride ?? name`. ②d adds ONLY the editing surface + the pure mutators behind it:

- **Workspace context menu** on the sidebar `WorkspaceSidebarRow` (`OuroWorkbenchApp.swift:3158`):
  - **Pin Workspace / Unpin Workspace** — toggles `Workspace.isPinned`; re-sorts pinned-first via the EXISTING `WorkspaceSidebarPresentation.resolve` seam (no new sort wiring — the sidebar model is a computed property that re-resolves on every render).
  - **Rename Workspace… (⇧⌘R)** — opens an inline editor prefilled with `effectiveName`; commit sets `nameOverride`.
  - **Remove Custom Workspace Name** — clears `nameOverride` → reverts to `autoName`; **shown ONLY when an override exists** (`nameOverride != nil`).
- **Tab context menu** on the `WorkspaceTabStrip` tab button (`OuroWorkbenchApp.swift:3308` `tabButton(_:)`):
  - **Rename Tab… (⌘R)** — opens an inline editor prefilled with `effectiveTabName`; commit sets `ProcessEntry.tabNameOverride`.
- **Inline rename editors** matching the cmux pattern: a `TextField` prefilled with the current name, **Enter = commit, Escape = cancel**, helper caption "Press Enter to rename, Escape to cancel."

**This slice is editing-affordances + pure mutators only.** It does NOT auto-GENERATE smart names (⑤ — auto-names stay whatever ②a/②b produced: "Restored workspace", entry names), does NOT add a workspace CREATION flow (onboarding ③/④), does NOT add propose-first bring-back (④), and does NOT move state to a dedicated git store (②c). It edits EXISTING workspaces/tabs only, persisting via the existing `WorkbenchStore`.

---

## Completion Criteria
- [x] Pure Core mutators on `WorkspaceState` exist and are 100% line+region covered: `setWorkspaceNameOverride(workspaceId:to:)`, `clearWorkspaceNameOverride(workspaceId:)`, `toggleWorkspacePin(workspaceId:)`, `setTabNameOverride(tabId:to:)`. Each is a no-op for an unknown id (covered).
- [x] Pure `WorkspaceRenameCommit` helper decides empty/whitespace commit semantics (DECISION D2d-1 below); 100% region covered.
- [ ] Pure `InlineRenameState` (or equivalent) models "is rename active / which target / commit / cancel" transitions; 100% region covered.
- [ ] Workspace context menu (Pin/Unpin, Rename ⇧⌘R, Remove Custom Name) attached to `WorkspaceSidebarRow`; "Remove Custom Name" item conditional on `nameOverride != nil`.
- [ ] Tab context menu (Rename ⌘R) attached to `WorkspaceTabStrip` tab button.
- [ ] Inline editors (prefilled, Enter=commit, Escape=cancel, helper caption) render for workspace + tab rename.
- [ ] Pinning a workspace re-sorts pinned-first (verified through the existing seam in a Core test + the `--uisurfacetest` smoke).
- [ ] Source-regression guard (`appSource()`) pins the new menus/editors/shortcuts present.
- [ ] `--uisurfacetest` smoke renders the menus/editors without crash AND exercises the mutators through `model.state`.
- [ ] 100% test coverage on all new Core code (`Scripts/coverage-allowlist.txt` does NOT grow).
- [ ] All tests pass under strict flags; 0 warnings.
- [ ] `Scripts/check-coverage.sh` green; `Scripts/preflight.sh` green.

## Code Coverage Requirements
**MANDATORY: 100% coverage on all new Core code.**
- No growth of `Scripts/coverage-allowlist.txt`. New mutators + helpers live in `OuroWorkbenchCore` and are 100% line + region (region = every conditional arm taken).
- All branches covered: each mutator's found-id AND unknown-id (no-op) arm; the rename-commit helper's commit / no-op arms (empty, whitespace-only, non-empty, unchanged-vs-changed); the inline-editor state's begin / commit / cancel / target-switch transitions.
- Edge cases: nil override, empty-string input, whitespace-only input, unchanged input (commit == current), unknown id.
- App-side SwiftUI (menus/editors/shortcuts) is NOT coverage-gated but IS compiled under `-warnings-as-errors -strict-concurrency=complete` and guarded by the source-regression test + `--uisurfacetest`.

## TDD Requirements
**Strict TDD — no exceptions, for every Core seam (Units 1–3):**
1. **Tests first**: write the failing XCTest BEFORE the mutator/helper.
2. **Verify failure**: run, confirm RED (the symbol genuinely does not exist / returns wrong value — not a compile-skip).
3. **Minimal implementation**: just enough to pass.
4. **Verify pass**: run, confirm GREEN under strict flags.
5. **Refactor**: clean up, keep green; confirm 100% region via `Scripts/check-coverage.sh`.
6. **No skipping**: never write a mutator/helper without a failing test first.

For App SwiftUI wiring (Units 4–6): NOT XCTest-renderable. Do **not** fabricate SwiftUI XCTests. Guard with the source-regression test (write the `source.contains(...)` assertion first → RED because the wiring isn't there yet → add the SwiftUI → GREEN) + extend the `--uisurfacetest` smoke. Any non-trivial editor STATE logic is extracted to Unit 3's pure helper and tested there.

---

## Decisions Made (this slice)

### D2d-1 — Empty / whitespace-only rename commit = NO-OP (reject), not override-to-empty, not revert. (reversible default)
The model (②a DA4) HONORS an empty-string `nameOverride` (it is a deliberate value; revert is unambiguously `nil`). That stays intact at the model layer. But the **inline editor must not be able to PRODUCE** an empty/whitespace name:
- An empty/whitespace-only commit (Enter on a blank or all-spaces field) is a **no-op**: the editor closes, the name is UNCHANGED (neither sets an empty override nor reverts).
- Rationale (reversibility + footgun avoidance): (a) the operator loses nothing — the existing name persists, fully reversible; (b) a blank workspace/tab name renders an invisible/confusing row; (c) "revert to auto" already has its OWN explicit affordance ("Remove Custom Workspace Name"), so a blank commit must NOT silently mean revert (ambiguous) NOR silently set a blank override (footgun).
- A non-empty commit is **trimmed of leading/trailing whitespace** then set as the override. If the trimmed value EQUALS the current `effectiveName`, it is also a no-op (no spurious override write / no needless save).
- This is encoded as the pure `WorkspaceRenameCommit.resolve(input:current:) -> Outcome` helper (Unit 3), so the decision is unit-tested, not buried in a SwiftUI closure. The model's empty-override-honored semantics are untouched and still covered by ②a's existing tests.
- Tab rename uses the SAME helper (same rule for `tabNameOverride`).

### D2d-2 — "Remove Custom Workspace Name" appears ONLY when an override exists.
Per the cmux reference and the revert semantics: the item is conditional on `workspace.nameOverride != nil`. When there's no override there is nothing to remove, so the item is hidden (not disabled) to keep the menu lean. (No tab equivalent in this slice — the cmux tab menu only has Rename Tab; tab revert is out of scope for ②d, deferred until/if requested.)

### D2d-3 — Inline editor, not a sheet/dialog.
The cmux reference is an INLINE text field replacing the row/tab label in place (prefilled, Enter=commit, Escape=cancel, "Press Enter to rename, Escape to cancel" caption). Matches the operator's confirmed cmux affordance and is the lighter-weight, more reversible surface than a modal sheet. (UX FORK logged in the planning return.)

### D2d-4 — Pin re-sort needs NO new wiring.
`model.workspaceSidebarModel` is a COMPUTED property that calls `WorkspaceSidebarPresentation.resolve(workspaces: state.workspaces, …)` on every render, and `resolve` already orders `filter(\.isPinned) + filter { !$0.isPinned }` (pinned-first, stable). `@Published var state` re-renders on mutation. So `toggleWorkspacePin` mutating `state.workspaces[i].isPinned` re-sorts automatically. A Core test asserts the seam re-orders after a toggle; the smoke confirms render.

### D2d-5 — Keyboard shortcuts ⌘R / ⇧⌘R are FREE (no conflict).
Verified at HEAD: no existing `.keyboardShortcut("r", …)` anywhere in `OuroWorkbenchApp.swift`. `⌘R` (Rename Tab) and `⇧⌘R` (Rename Workspace) are unbound. The three existing `.keyboardShortcut(.return, modifiers: [.command])` (⌘↩) are inside unrelated sheets and do not collide with a plain-Enter (no modifier) editor commit. (Logged in return for operator awareness.)

### D2d-8 — Shortcut PLACEMENT: prefer the established chord dispatcher, allow context-menu-button. (executor picks the idiomatic one)
Repo convention for global chords is the menu-bar `AppMenu` / chord dispatcher (e.g. `⌘.` Stop, `⌘L` Redraw target `model.activeEntry`), NOT a `.keyboardShortcut` on a context-menu `Button` — the existing `TerminalRowContextMenu` carries NO shortcuts on its items. So the PREFERRED placement is a chord that targets the active workspace/active tab (`model.activeWorkspaceRow` / `model.selectedEntryID`) and opens the inline rename: `⇧⌘R` → begin-rename the active workspace, `⌘R` → begin-rename the selected tab. SwiftUI also supports `.keyboardShortcut` directly on the context-menu Button (valid while the host is in the responder chain), which co-locates the shortcut with its menu item and matches cmux's "⌘R" affordance label. **Reversible default: wire the shortcut via the chord dispatcher targeting the active workspace/tab** (matches the in-repo pattern, works even with no menu open) AND show the "⌘R"/"⇧⌘R" hint as the menu item's label/`Text` so the affordance reads like cmux. The source-guard (Units 4a/5a) asserts the chord EXISTS and targets the active workspace/tab + opens rename — it does NOT pin a specific SwiftUI placement, so the executor can choose context-menu-button if that proves cleaner. (UX FORK logged in the return.)

### D2d-6 — Mutators live on `WorkspaceState`, not `WorkbenchStore`; in a `public extension` (cross-module access).
The App mutates `model.state` (a `WorkspaceState`) directly and persists via `store.save(state)` / the `save()` `didSet` path. `WorkbenchStore` exposes only `save`/`load` — it is NOT where structure mutators belong. So the pure mutators are `mutating func`s on `WorkspaceState` (the durable-structure owner), invoked from thin App wrappers that call `save()`. This mirrors the existing `state.applyAutomaticBossDefaults()` pure-mutator-on-state pattern. **CRITICAL ACCESS DETAIL**: the App imports Core with a PLAIN `import OuroWorkbenchCore` (NOT `@testable`), so the mutators MUST be public to be callable from `WorkbenchViewModel`. The existing precedent lives in a `public extension WorkspaceState { mutating func … }` block (members of a `public extension` are public by default) — add the new mutators to that same `public extension` (or mark each `public mutating func`). An `internal` mutator would compile in Core + its tests but FAIL the App build cross-module.

### D2d-7 — App-side thin wrappers persist via `save()`.
Each Core mutator gets a thin `WorkbenchViewModel` wrapper (e.g. `renameWorkspace(_:to:)`, `removeCustomWorkspaceName(_:)`, `toggleWorkspacePin(_:)`, `renameTab(_:to:)`) that calls the pure `state.<mutator>(…)` then `save()`. These wrappers are App-side (not coverage-gated) but are pinned by the source-regression test (they must call the Core mutator + `save()`).

---

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

**Every unit header starts with a status emoji.**

### ✅ Unit 0: Setup / Anchor re-verification
**What**: At current HEAD on `feat/slice2d-rename-pin`, re-confirm the anchors this slice attaches to (they were verified during conversion but re-verify before editing, since line numbers drift):
- `WorkspaceSidebarRow` struct + its `Button { … } label: { … }` body (workspace context-menu + editor host).
- `WorkspaceTabStrip.tabButton(_:)` (tab context-menu + editor host).
- `Workspace` (`nameOverride`/`isPinned`/`effectiveName`) + `ProcessEntry` (`tabNameOverride`/`effectiveTabName`) in `WorkspaceModels.swift`.
- `WorkspaceSidebarPresentation.resolve` pinned-first ordering.
- The existing `TerminalRowContextMenu` (mirror its `.contextMenu { Button { … } label: { Label(…) } }` shape) + `model.togglePin(for:)` / `model.isPinned(_:)` (mirror for workspace pin).
- The `WorkspaceStructureTests.swift` test style + the `appSource()`/`repoRoot()` source-guard helper (copy verbatim into the new wiring test file).
**Output**: A short anchor note in `./2026-06-24-2215-doing-slice2d-rename-pin/anchors.md` (file:line for each). No code change.
**Acceptance**: Every anchor resolves at HEAD; any drift from the file:line in this doc is recorded. `git status` clean except the artifacts note.

### ✅ Unit 1a: Core mutators — Tests (RED)
**What**: In a new `Tests/OuroWorkbenchCoreTests/WorkspaceEditingMutatorsTests.swift`, write FAILING XCTests for four pure mutators on `WorkspaceState` (mirroring `WorkspaceStructureTests` style):
- `setWorkspaceNameOverride(workspaceId:to:)`: sets `nameOverride` on the matching workspace; **unknown id = no-op** (state unchanged); setting to `nil` is allowed (alias for clear — but prefer `clear…` for intent).
- `clearWorkspaceNameOverride(workspaceId:)`: sets `nameOverride = nil` (revert to `autoName`); unknown id = no-op; already-nil = no-op (idempotent).
- `toggleWorkspacePin(workspaceId:)`: flips `isPinned`; unknown id = no-op. Assert toggling twice returns to original.
- `setTabNameOverride(tabId:to:)`: sets `ProcessEntry.tabNameOverride` on the matching entry; unknown id = no-op; setting `nil` allowed.
Cover EVERY arm: found-id, unknown-id, nil-vs-value, idempotent-clear, double-toggle.
**Acceptance**: Tests compile and FAIL (symbols don't exist yet) — real RED, run and shown.

### ✅ Unit 1b: Core mutators — Implementation (GREEN)
**What**: Add the four mutators to `WorkspaceState` in `WorkspaceModels.swift`, inside the existing `public extension WorkspaceState` block (so they're PUBLIC — D2d-6; an `internal` mutator passes Core tests but breaks the plain-`import` App build). Pure; `firstIndex(where:)` guard → mutate → else no-op. Doc-comment each, cross-referencing the model's name semantics (DA4 honored, revert == nil). Also make `WorkspaceRenameCommit` / `InlineRenameState` (Units 2/3) and any new public seam types `public` for the same reason.
**Acceptance**: All Unit 1a tests PASS under `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete`. 0 warnings.

### ✅ Unit 1c: Core mutators — Coverage & Refactor
**What**: Run `Scripts/check-coverage.sh`; confirm the four mutators are 100% line+region. Add any missing-arm test (e.g. a no-op path the suite didn't hit). Confirm `Scripts/coverage-allowlist.txt` is UNCHANGED.
**Acceptance**: `check-coverage.sh` green for `WorkspaceModels.swift`; allowlist unchanged; tests still green.
**Commit (Unit 1, one commit)**: `feat(core): WorkspaceState rename/pin/tab-override mutators (②d)`

### ✅ Unit 2a: Rename-commit semantics helper — Tests (RED)
**What**: New `Tests/OuroWorkbenchCoreTests/WorkspaceRenameCommitTests.swift`. Failing tests for a pure `WorkspaceRenameCommit.resolve(input:current:) -> Outcome` (D2d-1), where `Outcome` is `.commit(String)` or `.noop`:
- empty input → `.noop`.
- whitespace-only input → `.noop`.
- non-empty input with surrounding whitespace → `.commit(trimmed)`.
- trimmed input EQUAL to `current` → `.noop` (no spurious write).
- trimmed input DIFFERENT from `current` → `.commit(trimmed)`.
- (document: the model still honors an empty override if set programmatically — that's ②a's test, not this helper's; this helper just prevents the EDITOR from producing one.)
**Acceptance**: Tests compile and FAIL (helper doesn't exist) — real RED, shown.

### ✅ Unit 2b: Rename-commit semantics helper — Implementation (GREEN)
**What**: Add `WorkspaceRenameCommit` (a pure enum/struct in `OuroWorkbenchCore`, e.g. new `WorkspaceRenameCommit.swift`) implementing D2d-1: trim, empty→noop, unchanged→noop, else commit(trimmed).
**Acceptance**: All Unit 2a tests PASS under strict flags. 0 warnings.

### ✅ Unit 2c: Rename-commit helper — Coverage & Refactor
**What**: `Scripts/check-coverage.sh` → 100% line+region on `WorkspaceRenameCommit.swift`. Add any missing-arm test. Allowlist unchanged.
**Acceptance**: green; allowlist unchanged; tests green.
**Commit (Unit 2, one commit)**: `feat(core): WorkspaceRenameCommit empty/whitespace decision helper (②d)`

### ⬜ Unit 3a: Inline-editor state helper — Tests (RED)
**What**: New `Tests/OuroWorkbenchCoreTests/InlineRenameStateTests.swift`. Failing tests for a pure `InlineRenameState` modeling "which target (if any) is being renamed and the draft text":
- A target identifier enum/case for `.workspace(UUID)` vs `.tab(UUID)` (so one editor state serves both menus).
- `begin(target:prefill:)` → active with the prefilled draft.
- `cancel()` → inactive, draft cleared.
- `commit()` → returns the current draft + target for the caller to resolve through `WorkspaceRenameCommit`, then goes inactive.
- `isEditing(target:)` predicate (so a row/tab knows whether to show the editor vs the label).
- begin on a NEW target while one is active → switches target, replaces draft (no stale draft leak).
Cover every transition arm.
**Acceptance**: Tests compile and FAIL — real RED, shown.

### ⬜ Unit 3b: Inline-editor state helper — Implementation (GREEN)
**What**: Add `InlineRenameState` (pure `OuroWorkbenchCore` value type, e.g. `InlineRenameState.swift`). Keep it framework-free (no SwiftUI) so it is XCTest-visible and coverage-gated. The App holds it as `@Published var inlineRename: InlineRenameState` and binds the editor's `TextField` text to its draft.
**Acceptance**: Unit 3a tests PASS under strict flags; 0 warnings.

### ⬜ Unit 3c: Inline-editor state helper — Coverage & Refactor
**What**: `check-coverage.sh` → 100% line+region on `InlineRenameState.swift`. Allowlist unchanged.
**Acceptance**: green; allowlist unchanged; tests green.
**Commit (Unit 3, one commit)**: `feat(core): InlineRenameState begin/commit/cancel/switch transitions (②d)`

### ⬜ Unit 4a: App workspace context menu + thin wrappers — Source guard (RED)
**What**: In a new `Tests/OuroWorkbenchCoreTests/WorkspaceEditingAffordancesWiringTests.swift` (copy the `appSource()`/`repoRoot()` helper verbatim), write FAILING `source.contains(...)` assertions for the WORKSPACE menu wiring:
- `WorkspaceSidebarRow` (or its host) attaches a `.contextMenu` with Pin/Unpin, Rename Workspace, Remove Custom Name.
- The ⇧⌘R Rename-Workspace chord exists and targets the active workspace + opens rename (per D2d-8: assert `.keyboardShortcut("r", modifiers: [.command, .shift])` is present AND its action begins-rename on the active workspace, e.g. `beginRename(.workspace(`/`activeWorkspaceRow`). Placement-agnostic: chord dispatcher OR context-menu button — assert the chord + its target, not a fixed location).
- The Remove-Custom-Name item is gated on `nameOverride != nil` (assert the conditional token, e.g. `row.nameOverride != nil` or the wrapper guard). The exact token isn't fixed until Unit 4b decides whether the gate reads `WorkspaceRow.nameOverride` or a VM helper (`workspaceNameOverride(_:)`) — keep the RED assert and the GREEN token in LOCKSTEP: whichever 4b implements, 4a asserts that same token (review note 2).
- Thin VM wrappers call the Core mutators + `save()` (assert `state.toggleWorkspacePin`, `state.setWorkspaceNameOverride`, `state.clearWorkspaceNameOverride` appear in the App source and are followed by a `save()` in their wrapper).
**Acceptance**: Assertions FAIL (wiring absent) — real RED, shown.

### ⬜ Unit 4b: App workspace context menu + thin wrappers — Implementation (GREEN)
**What**: 
- Add VM wrappers on `WorkbenchViewModel`: `toggleWorkspacePin(_ id:)`, `renameWorkspace(_ id:to:)` (resolves input via `WorkspaceRenameCommit` then `setWorkspaceNameOverride`), `removeCustomWorkspaceName(_ id:)` (→ `clearWorkspaceNameOverride`), each calling `save()`. Expose `workspaceNameOverride(_ id:) -> String?` (or pass the row's `nameOverride`) for the conditional menu item.
- Add the workspace `.contextMenu` to the `WorkspaceSidebarRow` render (mirror `TerminalRowContextMenu` shape): Pin/Unpin (label flips on `row.isPinned`, `pin`/`pin.slash` icon), Rename Workspace… (⇧⌘R) → `model.beginRename(.workspace(row.id), prefill: row.effectiveName)`, and — only when an override exists — Remove Custom Workspace Name → `model.removeCustomWorkspaceName(row.id)`.
- `WorkspaceRow` must surface `nameOverride` (add to the seam's `WorkspaceRow` if not present — small additive Core change; if added, extend the seam's existing tests for it). **Re-verify** whether `WorkspaceRow` already carries enough to decide `nameOverride != nil`; if it only has `effectiveName`/`isPinned`, add `nameOverride: String?` to `WorkspaceRow` + its `resolve` mapping (covered by the existing seam tests, extended).
**Acceptance**: Unit 4a source assertions PASS; `swift build`/`swift test` strict green, 0 warnings.

### ⬜ Unit 4c: Workspace menu — coverage of any Core seam change
**What**: If Unit 4b added `nameOverride` to `WorkspaceRow`/`resolve`, run `check-coverage.sh` and extend `WorkspaceSidebarPresentationTests`/`WorkspaceSidebarWiringTests` so the new field's mapping is 100% covered. Allowlist unchanged.
**Acceptance**: `check-coverage.sh` green; allowlist unchanged.
**Commit (Unit 4, one commit)**: `feat(app): workspace context menu — pin, rename (⇧⌘R), remove custom name (②d)`

### ⬜ Unit 5a: App tab context menu — Source guard (RED)
**What**: Extend `WorkspaceEditingAffordancesWiringTests` with FAILING `source.contains(...)` for the TAB menu:
- `WorkspaceTabStrip.tabButton(_:)` attaches a `.contextMenu` with Rename Tab.
- The ⌘R Rename-Tab chord exists and targets the selected tab + opens rename (per D2d-8: assert `.keyboardShortcut("r", modifiers: [.command])` present AND its action begins-rename on the selected tab, e.g. `beginRename(.tab(`/`selectedEntryID`). Placement-agnostic).
- The VM wrapper `renameTab(_ id:to:)` calls `WorkspaceRenameCommit` → `state.setTabNameOverride` + `save()`.
**Acceptance**: New assertions FAIL — real RED, shown.

### ⬜ Unit 5b: App tab context menu — Implementation (GREEN)
**What**: Add VM `renameTab(_ id:to:)` (resolve via `WorkspaceRenameCommit`, then `setTabNameOverride`, then `save()`). Add the `.contextMenu` to `tabButton` with Rename Tab… (⌘R) → `model.beginRename(.tab(tab.id), prefill: tab.effectiveTabName)`.
**Acceptance**: Unit 5a assertions PASS; strict build/test green, 0 warnings.
**Commit (Unit 5, one commit)**: `feat(app): tab context menu — rename tab (⌘R) (②d)`

### ⬜ Unit 6a: Inline rename editors + caption — Source guard (RED)
**What**: Extend the wiring test with FAILING `source.contains(...)` for the INLINE EDITORS:
- `WorkspaceSidebarRow` shows a `TextField` bound to the inline-rename draft when `model.inlineRename.isEditing(.workspace(row.id))`, else the label.
- `WorkspaceTabStrip.tabButton` shows a `TextField` when `model.inlineRename.isEditing(.tab(tab.id))`, else the label.
- Each editor: `.onSubmit` (Enter) → `model.commitRename()`; an Escape path → `model.cancelRename()`. **Pick ONE Escape mechanism** (`.onExitCommand` OR `.onKeyPress(.escape)` OR a `.keyboardShortcut(.cancelAction)` cancel button) and assert that EXACT token in the source guard — do NOT write a vacuous "any of three" multi-contains, which would weaken the guard (review note 3).
- The helper caption text "Press Enter to rename, Escape to cancel." is present.
- `commitRename()` routes through `WorkspaceRenameCommit.resolve` and, on `.commit`, dispatches to `renameWorkspace`/`renameTab` per the active target; on `.noop` just closes (D2d-1).
**Acceptance**: Assertions FAIL — real RED, shown.

### ⬜ Unit 6b: Inline rename editors — Implementation (GREEN)
**What**: 
- Add `@Published var inlineRename: InlineRenameState` to `WorkbenchViewModel` + `beginRename(_:prefill:)`, `commitRename()`, `cancelRename()` (commit routes through `WorkspaceRenameCommit` then the per-target wrapper; the Core helpers carry the logic).
- Render the inline `TextField` (prefilled via `begin`'s draft binding, Enter=commit, Escape=cancel, caption) in both `WorkspaceSidebarRow` and `tabButton`, swapping the label for the editor while that target is active.
**Acceptance**: Unit 6a assertions PASS; strict build/test green, 0 warnings.

### ⬜ Unit 6c: `--uisurfacetest` rendering smoke + final gates
**What**: Extend `UISurfaceTest.swift` with a ②d smoke that:
- Builds a `WorkbenchViewModel` with ≥2 workspaces (one with `nameOverride`, one without) + ≥1 tab.
- Renders `WorkbenchSidebarView` + `WorkspaceTabStrip` while an inline rename is active for a workspace AND (separately) a tab — assert positive fitting sizes (no crash).
- Exercises the mutators through `model.state`: toggle pin on the unpinned one → assert the seam re-orders pinned-first (D2d-4); set a name override → assert `effectiveName` changes; clear it → assert revert to `autoName`; set a tab override → assert `effectiveTabName` changes.
- Drives `WorkspaceRenameCommit` for empty/whitespace input via `commitRename()` and asserts NO override was written (D2d-1).
Then run the FULL gate: `swift build`/`swift test` strict, `Scripts/check-coverage.sh`, `swift run … --uisurfacetest`, `Scripts/preflight.sh`. Confirm allowlist unchanged.
**Acceptance**: All gates green; `--uisurfacetest` prints the ②d smoke success line; allowlist unchanged.
**Commit (Unit 6, one commit)**: `feat(app): inline rename editors (Enter/Escape) + ②d uisurfacetest smoke`

### ⬜ Unit 7: Fresh unbiased review gate (autonomous signoff)
**What**: Spawn a FRESH, context-free sub-agent (general-purpose) to review the ②d diff against this doing doc + the slice scope. It must independently verify: (a) every Completion Criterion is met with evidence; (b) Core mutators/helpers are genuinely 100% region (not allowlisted away); (c) the source-regression guard actually pins the menus/editors/shortcuts (not vacuous asserts); (d) NO scope-creep into ②c/④/⑤ (no smart auto-naming, no creation flow, no git store); (e) strict gates + `--uisurfacetest` + `preflight` green; (f) one-commit-per-unit, no AI attribution, `SerpentGuide.ouro/` not staged. The reviewer returns PASS or a defect list.
**Output**: Reviewer verdict saved to `./2026-06-24-2215-doing-slice2d-rename-pin/review-gate.md`.
**Acceptance**: Reviewer returns PASS. If defects: fix (each its own commit), re-run gates, re-review until PASS. Then set this doc's Status to `done`.

## Execution
- **TDD strictly enforced** on Units 1–3 (Core): tests → RED → implement → GREEN → 100% region. Units 4–6 use source-regression-guard-first (assert RED → wire SwiftUI → GREEN) + `--uisurfacetest`; do NOT fabricate SwiftUI XCTests.
- **One commit per unit** (Units 1–6 each one commit; Unit 0 is an artifacts-only note that may fold into Unit 1's commit or stand alone). Unit 7 fixes are each their own commit.
- Run the FULL gate before marking any App unit done: `swift build`/`swift test` strict, `check-coverage.sh`, `--uisurfacetest`, and `preflight.sh` at the end (Unit 6c).
- `Scripts/coverage-allowlist.txt` must NOT grow — if a new Core line can't be covered, the design is wrong; restructure rather than allowlist.
- **All artifacts** (anchor note, review verdict) → `./2026-06-24-2215-doing-slice2d-rename-pin/`.
- **NO Co-Authored-By / AI attribution** in any commit. Do **NOT** stage `SerpentGuide.ouro/`.
- Gate on OUR products only; the pre-existing 3rd-party `SwiftTermFuzz` strict-concurrency error is NOT ours — ignore it.
- **Blockers**: spawn a sub-agent immediately; don't stall. **Decisions**: update this doc + commit right away.
- Do **NOT** open a PR (per task). Branch stays `feat/slice2d-rename-pin`.

## Progress Log
- 2026-06-24 22:15 Created from master plan (Slice ②d); anchors re-verified at HEAD d376564; render sites + Core seams + empty-commit decision recorded.
- 2026-06-24 22:15 Validation pass: confirmed WorkspaceRow lacks `nameOverride` (Unit 4b additive need real); confirmed mutators must be public (App uses plain import) → D2d-6/D2d-8 refined.
- 2026-06-24 22:15 Fresh unbiased sub-agent review gate spawned on the doing doc (autonomous signoff, no human gate).
- 2026-06-24 22:15 Review gate returned PASS (all claims independently verified; 3 MINOR notes). Notes 2 & 3 hardened into Units 4a/6a (RED/GREEN token lockstep; single Escape mechanism). Verdict saved to artifacts/review-gate.md. Status → READY_FOR_EXECUTION.
- Unit 0 complete: all anchors re-verified at execution-start HEAD; recorded one clarification (`togglePin` persists via `store.save` directly; ②d wrappers use the canonical `save()` @ :20309) + confirmed `WorkspaceRow` lacks `nameOverride` (4b additive need real) + chord-dispatcher plan for ⌘R/⇧⌘R. anchors.md updated. (commit 31c9886)
- 2026-06-24 22:33 Unit 1 complete: 4 pure `WorkspaceState` mutators (`setWorkspaceNameOverride`/`clearWorkspaceNameOverride`/`toggleWorkspacePin`/`setTabNameOverride`) in the existing `public extension`; 15 XCTests (every arm: found/unknown-noop/nil/idempotent-clear/double-toggle) RED→GREEN under strict flags, 0 warn; `check-coverage.sh` green (WorkspaceModels.swift 100% line+region), allowlist unchanged. (commit 6ab1149)
- 2026-06-24 22:46 Unit 2 complete: pure `WorkspaceRenameCommit.resolve(input:current:) -> Outcome` (D2d-1: empty/whitespace→noop, trimmed-non-empty→commit, trimmed==current→noop, case-change is a real change); 8 XCTests RED→GREEN strict, 0 warn; coverage green (148/150 at 100%, new file covered), allowlist unchanged. (commit d5be56c)
