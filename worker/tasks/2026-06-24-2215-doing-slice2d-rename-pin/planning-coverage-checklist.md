# Slice ②d — Planning Coverage Checklist

Maps every Slice ②d requirement (from the master plan + ideation + task brief) to a doing unit. ✅ = has a unit; ❌ = missing.

## In-scope affordances (task brief "Slice ②d scope")
- ✅ Workspace context menu: Pin/Unpin Workspace (toggle `isPinned`) → Units 1 (mutator) + 4 (menu)
- ✅ Workspace context menu: Rename Workspace (⇧⌘R → inline editor sets `nameOverride`) → Units 1+3+4+6
- ✅ Workspace context menu: Remove Custom Workspace Name (clears `nameOverride` → reverts to `autoName`; only shown when override exists) → Units 1 (clear mutator) + 4 (conditional item, D2d-2)
- ✅ Tab context menu: Rename Tab (⌘R → inline editor sets `ProcessEntry.tabNameOverride`) → Units 1 (mutator) + 3 + 5 + 6
- ✅ Inline rename editors (prefilled, Enter=commit, Escape=cancel, "Press Enter to rename, Escape to cancel" caption) → Units 3 (state) + 6 (editor render)
- ✅ Empty/whitespace commit semantics decided + recorded → D2d-1 + Unit 2 (pure helper, tested)
- ✅ Model mutators as testable seam (`setWorkspaceNameOverride`, `clearWorkspaceNameOverride`, `toggleWorkspacePin`, `setTabNameOverride`) on `WorkspaceState` → Unit 1 (D2d-6)
- ✅ Pin re-sorts via existing seam (pinned-first reacts) → D2d-4 + Unit 1c assert + Unit 6c smoke

## TDD posture (task brief "TDD posture")
- ✅ Model mutators = pure Core, real failing XCTest first, 100% coverage, allowlist NOT grown → Units 1a/1b/1c
- ✅ SwiftUI menus/editors/shortcuts NOT XCTest-visible → source-regression guard (`appSource()`) + `--uisurfacetest` → Units 4a/5a/6a + 6c
- ✅ Do NOT fabricate SwiftUI XCTests → stated in TDD Requirements + Execution
- ✅ Non-trivial editor STATE logic extracted to a pure testable helper → Unit 3 (`InlineRenameState`)

## Out of scope (task brief — must NOT appear in any unit)
- ✅ NO dedicated git store / opt-in remote (②c deferred) → stated; keeps `WorkbenchStore`/`workspace-state.json` (D2d-6)
- ✅ NO propose-first bring-back (④) → not in any unit
- ✅ NO boss naming INTELLIGENCE / smart auto-naming (⑤) → explicitly excluded in Objective; auto-names stay as-is
- ✅ NO new workspace CREATION flow (③/④) → explicitly excluded in Objective
- ✅ Unit 7 review gate explicitly checks for NO scope-creep into ②c/④/⑤

## Hard constraints (task brief "Constraints")
- ✅ Strict build/test (`-warnings-as-errors -strict-concurrency=complete`), 0 warn/fail → Completion Criteria + every unit acceptance
- ✅ Ignore pre-existing 3rd-party `SwiftTermFuzz` strict-concurrency error → Execution note
- ✅ `--uisurfacetest` passes → Unit 6c
- ✅ `Scripts/check-coverage.sh` green; allowlist unchanged → Units 1c/2c/3c/4c + Completion Criteria
- ✅ One commit per unit → Execution + per-unit commit lines
- ✅ NO Co-Authored-By / AI attribution → Execution note
- ✅ Do NOT stage `SerpentGuide.ouro/` → Execution note
- ✅ Branch stays `feat/slice2d-rename-pin`; NO new branch; NO PR → header + Execution

## Decisions recorded
- ✅ D2d-1 empty/whitespace commit = no-op (reject) — reversible default
- ✅ D2d-2 Remove-Custom-Name shown only when override exists
- ✅ D2d-3 inline editor not sheet
- ✅ D2d-4 pin re-sort needs no new wiring
- ✅ D2d-5 ⌘R/⇧⌘R free (no conflict)
- ✅ D2d-6 mutators on WorkspaceState not WorkbenchStore
- ✅ D2d-7 thin App wrappers persist via save()
- ✅ D2d-8 shortcut placement (chord dispatcher preferred, context-menu-button allowed)

## Result
Full coverage confirmed. No missing units.
