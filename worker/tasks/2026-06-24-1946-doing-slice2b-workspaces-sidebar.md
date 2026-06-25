# Doing: Slice ②b — Named-Workspace Sidebar + Tab Layout; DELETE "Terminals in Home"

**Status**: drafting → (review gate) → READY_FOR_EXECUTION
**Execution Mode**: direct
**Created**: 2026-06-24 19:46
**Planning**: ./2026-06-24-1755-planning-workspaces-converged-design.md
**Ideation**: ./2026-06-24-1745-ideation-workspaces-onboarding-bring-back.md
**Depends on (landed)**: ./2026-06-24-1832-doing-slice2a-storage-schema.md (Workspace/Tab model + migration — PR #285, merged into `origin/main` @ 93b3668)
**Artifacts**: ./2026-06-24-1946-doing-slice2b-workspaces-sidebar/
**Branch**: `feat/slice2b-workspaces-sidebar` (off `origin/main` @ 93b3668 — **do NOT branch again**)

## Execution Mode

- **pending**: Awaiting user approval before each unit starts (interactive)
- **spawn**: Spawn sub-agent for each unit (parallel/autonomous)
- **direct**: Execute units sequentially in current session (default) ← **this slice**

Rationale: the units are tightly coupled (Core view-model seam → App sidebar rewire → App tab-strip → string/test cleanup), share `OuroWorkbenchApp.swift` + `WorkbenchSurfacePolicy.swift`, and each must leave the strict build / test / coverage / `--uisurfacetest` gates green. The testable LOGIC is extracted to a real Core seam with strict XCTest TDD (red→green→100% coverage); the SwiftUI view wiring (which is NOT XCTest-visible) is guarded by a source-level regression test + a `--uisurfacetest` rendering smoke, exactly as Slice ① and the existing `*WiringTests` do. Sequential `direct`, **one commit per unit**.

---

## Objective
Adopt Slice ②a's persisted `Workspace`/tab model in the App UI and **delete the "Terminals in Home" concept** (and the second meaning of "workspace"). Concretely:
- The **sidebar** renders the persisted `state.workspaces` as named rows (`effectiveName`); each workspace's tabs are its `tabIds` → `ProcessEntry`s, displayed by `effectiveTabName`. Rows are **lean**: name + light work-context (attention glyph / branch IF already available on the entry). **NO PWD dump, NO cost.**
- The **active workspace's tabs render across the top** (cmux tab-strip), each named by `effectiveTabName`.
- **Kill "Home"**: remove the `setupWorkspaceName = "Home"` *display-as-workspace* and the `terminalsSectionTitle(workspaceName:)` "Terminals in <name>" framing, plus the flat-list-scoped-to-selected-project framing. After ②a's migration, existing sessions appear under the single **"Restored workspace"**; verify that renders correctly.

**This slice is render-layer + view-model-derivation only.** It does NOT move state to a dedicated git-init store (②c), does NOT add Rename/Pin/Remove-Custom-Name affordances (②d), does NOT add propose-first bring-back (④) or smart auto-names (⑤). ②b keeps using the existing `WorkbenchStore` / `workspace-state.json`.

---

## CRITICAL ARCHITECTURE FINDING (re-verified at HEAD 93b3668) — read before any unit

The repo currently has **two coexisting membership models** in `WorkspaceState`:

1. **OLD (live, rendered today)** — `state.projects: [WorkbenchProject]` (directory-anchored; carries `rootPath` = the PWD the new design forbids) + `ProcessEntry.projectId` (each entry belongs to exactly one project). The sidebar renders these as the "Workspaces" section (`OuroWorkbenchApp.swift:3098-3130`, `SidebarProjectRow` @ :3218 dumps `Text(project.rootPath)` @ :3248), and a SECOND "Terminals in <name>" section (`:3131`) renders `model.sessionEntries` (the flat list filtered to `selectedProjectID`). `WorkbenchProject` is also the **backing/launch model**: `WorkbenchBootstrapper` mints a default project named `"Home"` (`WorkbenchSurfacePolicyTests`/`WorkbenchBootstrapperTests:9-10`), and new terminals are created with `makeEntry(projectId: project.id, …)` (`:13377`, `:15728`, `:17423`).

2. **NEW (②a, persisted, currently UNRENDERED)** — `state.workspaces: [Workspace]` (NOT directory-anchored; membership = `tabIds: [UUID]` → `ProcessEntry.id`). **No code reads `state.workspaces`** anywhere except the migration call comment (`OuroWorkbenchApp.swift:19948`). ②a's migration folds every non-archived entry into ONE workspace `autoName == "Restored workspace"`, **independent of `projectId`**.

**Consequence (this is the whole UX of ②b):** rendering `state.workspaces` literally → after migration the sidebar shows a **single row** ("Restored workspace") whose tabs are *all* terminals — collapsing the existing multi-project grouping out of view. That is the design's *honest migration* intent ("existing sessions appear under the single 'Restored workspace'"). ②b makes that the displayed truth.

**Scope decision (DB1, reversible/auditable default — see Decisions Made):** ②b is a **render swap**: the sidebar/tab-strip render `state.workspaces` (+ `effectiveTabName`/`effectiveName`); the `WorkbenchProject`/`projectId` machinery stays as the *backing launch model* for ②b (new terminals still get a `projectId`; ②a's migration guarantees they're also folded into a workspace on next load). ②b does NOT delete `WorkbenchProject` or `projectId` (that is a larger, separable change — ②c/②d territory). ②b deletes the *user-visible* "projects-as-workspaces" + "Terminals in Home" surface and replaces it with the workspace/tab surface. This keeps ②b minimal, independent, and reversible (a render-layer revert restores the old sidebar without touching state). **This is FORK #1 for the operator — flagged below.**

---

## The testable Core seam (the only XCTest-able new logic)

App SwiftUI views are NOT XCTest-visible. Per the prompt's honest TDD posture, ALL grouping/ordering/display-derivation LOGIC is extracted into a **pure Core seam** with real failing XCTest first + 100% line+region coverage (allowlist must NOT grow). The view wiring uses a source-level regression guard + `--uisurfacetest` smoke.

**New Core seam: `WorkspaceSidebarPresentation` (in `Sources/OuroWorkbenchCore/`).** A pure value-deriver that takes `(workspaces: [Workspace], entries: [ProcessEntry], selectedWorkspaceId: UUID?)` and returns the ordered, resolved view-model the sidebar/tab-strip render — NO SwiftUI, NO view-model dependency. It owns:
- **Workspace row ordering**: pinned workspaces first (stable), then the rest in stored order (mirrors the entry pin rule in `sessionEntries` @ `:11275`).
- **Tab resolution + ordering**: for a workspace, resolve `tabIds → ProcessEntry` (skipping dangling ids whose entry was deleted; attribute drops so they're never silently wrong), in `tabIds` order, each carrying `effectiveTabName`.
- **`effectiveName` / `effectiveTabName` surfacing** (already on the model; the seam just selects them so the view never re-derives).
- **The active-workspace selection rule**: which workspace is "active" given `selectedWorkspaceId` (fallback to the first / pinned-first when nil; pin the rule so an empty/just-migrated state has a deterministic active workspace).
- **Empty-workspace handling**: a workspace with zero resolved tabs yields an explicit empty-state marker (so the view shows "no tabs yet", never blank pixels) — see FORK #3.
- **Lean row work-context**: surfaces ONLY already-available light context (the design's "branch/attention if already available"). The seam returns a typed `WorkspaceRowContext` (e.g. attention summary derived from the workspace's tabs' `ProcessEntry.attention`); branch/diffstat live on the App side via `model.gitStatus(for:)` (already rendered per-tab by `GitBranchChip`) and are passed through the view, NOT recomputed in Core — the seam only decides *whether/which* attention summary to show, keeping the testable derivation pure. **NEVER cost.** (FORK #2 governs exactly what sits in the row.)
- **Archived partition (DB7)**: split a workspace's tabs into active vs archived (`ProcessEntry.isArchived`), so the App renders the active tabs in the strip and an optional per-workspace Archived list. This partition is pure derivation → testable in the seam.

This seam is the unit-tested heart: workspace ordering, tab ordering, dangling-id drop, active-workspace selection, empty handling, attention summary. 100% line+region.

---

## Anchors (re-verified at HEAD 93b3668)

### App render sites to change (`Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift`)
- **`WorkbenchSidebarView` / `sessionList`** @ `:3045` / `:3069-3215` — the single `List` holding the sidebar sections.
- **"Workspaces" section (projects)** @ `:3098-3130` — `Section(WorkbenchSurfacePolicy.workspaceSectionTitle)` → `ForEach(model.state.projects)` → `SidebarProjectRow`. This is the projects-as-workspaces surface ②b replaces with workspace rows.
- **`SidebarProjectRow`** @ `:3218`, with the **PWD dump** `Text(project.rootPath)` @ `:3248` — the forbidden surface.
- **"Terminals in <name>" section** @ `:3131` — `Section(WorkbenchSurfacePolicy.terminalsSectionTitle(workspaceName: model.selectedProject?.name))` → `ForEach(model.sessionEntries)` → `TerminalAgentRow`. This is the "Home" framing ②b kills; tabs move to the top tab-strip.
- **`TerminalAgentRow`** @ `:3568`, **`SessionChip`** @ `:3809` — the per-tab row (Slice ① already removed the `$X tok` cost badge; the attention health glyph stays). Reused to render tabs by `effectiveTabName`.
- **Archived section** @ `:3169`, **Recovery section** @ `:3189` — KEEP; ②b's rewire must preserve them.
- **Detail pane / `NavigationSplitView`** @ `:362-413` — sidebar column @ `:363`; detail column @ `:365` (Header @ `:372` / BossDashboard @ `:377` / selected-entry `DetailSplitContainer` @ `:392`). The **cmux tab-strip mounts in the detail column, above the selected-session detail** (between the Boss dashboard divider and the session detail Group) — the active workspace's tabs across the top.
- **Migration call (DO NOT touch)** @ `:19948` — `state.migrateToWorkspaceStructure()` already runs at bootstrap (②a). ②b relies on it; verify the rendered "Restored workspace" is the migration's output.

### View-model data already available (no new data invented)
- `model.sessionEntries` @ `:11270` — flat, `selectedProject`-filtered, pinned-first list (today's tab source).
- `state.workspaces` (②a) — the new membership; `Workspace.effectiveName` / `ProcessEntry.effectiveTabName` (②a) ready to render.
- `ProcessEntry.attention: AttentionState` (`WorkspaceModels.swift:225`) + `model.gitStatus(for:)` (`:12339`) — already-available light work-context (attention glyph already rendered by `SessionChip`; branch via gitStatus). **No new metadata surface is introduced** (master plan: work-context-as-new-surface is a later slice; ②b only reuses what exists).
- `selectedEntryID` @ `:10377`, `selectedProjectID` @ `:10364`, `selectedProject` @ `:11400` — selection wiring.

### Core string/policy site to change (`Sources/OuroWorkbenchCore/WorkbenchSurfacePolicy.swift`)
- `terminalsSectionTitle(workspaceName:)` @ `:56-62` — the "Terminals in <name>" / "Terminals" producer. ②b removes its sidebar use; the function's fate (delete vs keep-unused) is decided in the cleanup unit (delete if no other caller — verify).
- `setupWorkspaceName = "Home"` @ `:45` — the default-project name. **NOT renamed by ②b's render swap** (it's the backing-project name, no longer shown as a workspace row once the sidebar renders `state.workspaces`). Confirm no other VISIBLE surface shows it; the backing default is invisible after the swap. (If the operator wants the backing default renamed too, that's FORK #4.)

### Tests that WILL break (blast radius — must be updated in-slice)
- `Tests/OuroWorkbenchCoreTests/WorkspaceHomeNamingTests.swift:52-64` — **source-level wiring guard** asserting the App source `.contains("Section(WorkbenchSurfacePolicy.terminalsSectionTitle(workspaceName: model.selectedProject?.name))")` AND `.contains(false: "Section(model.selectedProject?.name ?? \"Terminals\")")`. Removing the "Terminals in" section **breaks this guard** → it must be re-pointed to the new workspace-sidebar wiring (assert the new `state.workspaces` render is present; the old "Terminals in" section is gone). Lines 27-46 (`terminalsSectionTitle` value tests) stay valid ONLY if the function is kept; if deleted, remove those too.
- `Tests/OuroWorkbenchCoreTests/WorkbenchSurfacePolicyTests.swift:25-38` (`testAppWorkspaceCopyIsWiredThroughSurfacePolicy`) — asserts the App source `.contains("Section(WorkbenchSurfacePolicy.workspaceSectionTitle)")`. If the "Workspaces"(=projects) section is replaced by the workspace-rows section, this guard must be re-pointed to the new wiring constant. Lines 6-22 (string-constant value tests) stay valid if the constants are kept.
- `Tests/OuroWorkbenchCoreTests/WorkbenchSurfacePolicyTests.swift:92-98` + `WorkspaceHomeNamingTests.swift:9-22` (`setupWorkspaceName == "Home"`) — stay GREEN as long as ②b does NOT rename the backing default (DB1). Only touched if FORK #4 is taken.
- `Tests/OuroWorkbenchCoreTests/WorkbenchBootstrapperTests.swift:9-10,41` (`state.projects.map(\.name) == ["Home"]`) — stay GREEN under DB1 (backing project unchanged). Only touched if FORK #4 is taken.
- `Tests/OuroWorkbenchCoreTests/PersistenceSalvageWiringTests.swift:158-225` — **App-source guard** asserting `load()` restores `selectedProjectID` and `selectedProjectID.didSet` routes through `save()` (the implicit-save discipline). **CONSTRAINT (not a break under DB1):** ②b must NOT remove `selectedProjectID` or its `didSet`-save (DB1 keeps the backing `WorkbenchProject`/`projectId` model). If Unit 2b ADDS a `selectedWorkspaceID`, leave `selectedProjectID` intact so this guard stays GREEN. (If a future slice removes `selectedProjectID`, this guard must move with it — out of ②b scope.)
- `Tests/OuroWorkbenchCoreTests/OnboardingBossChoiceRowAccessibilityWiringTests.swift:12` — **cosmetic only**: a `///` doc-comment references "`SidebarProjectRow` ~:3182" (it slices `OnboardingBossChoiceRow`, NOT `SidebarProjectRow`, so it does NOT break). If Unit 2b moves/deletes `SidebarProjectRow`, update that stale comment line reference (no test assertion fails).
- **NOTE (verified bump-safe, do NOT touch):** `WorkspaceSummaryTests.swift`, `OnboardingTests.swift`, `AutonomyReadinessTests.swift`, `BossAgentPromptBuilderTests.swift` use `project.id`/`project.rootPath` ONLY as fixture inputs to construct `ProcessEntry`/`WorkbenchProject` (no sidebar-render assertions); they stay GREEN because DB1 keeps `WorkbenchProject`/`projectId`.
- **Unit 0 must re-grep ALL of `Tests/` for `"Terminals in"`, `terminalsSectionTitle`, `workspaceSectionTitle`, `SidebarProjectRow`, `rootPath`, `selectedProjectID`, and any source-`.contains(`/`appSource()` guard touching the sidebar/projects/terminals wiring, and record the exact, complete blast-radius set before any edit.** (The items above were swept at draft time — confirm completeness at execution HEAD; this is the ②a-style "literal blast radius" discipline that caught a missed literal in ②a.)

---

## Completion Criteria
- [ ] Sidebar renders `state.workspaces` as named rows using `effectiveName`; each workspace's tabs are its `tabIds → ProcessEntry`, displayed by `effectiveTabName`. The migrated "Restored workspace" renders as one row with all its tabs.
- [ ] Sidebar rows are LEAN: name + light work-context (attention/branch IF already available). **NO `project.rootPath` PWD dump. NO cost.** (`Text(project.rootPath)` no longer in the sidebar render path.)
- [ ] The active workspace's tabs render across the top (cmux tab-strip) in the detail column, each named by `effectiveTabName`.
- [ ] "Terminals in Home" is GONE: the `terminalsSectionTitle(workspaceName:)` sidebar section is removed; the flat-list-scoped-to-selected-project framing is removed; no user-visible "Home" workspace row.
- [ ] After ②a's migration, an existing (pre-②b) state renders all sessions under the single "Restored workspace" — verified via the `--uisurfacetest` smoke loading a migrated fixture.
- [ ] Archived + Recovery sections still render (preserved).
- [ ] `WorkspaceSidebarPresentation` Core seam exists with: workspace ordering (pinned-first), tab resolution+ordering, dangling-id drop, active-workspace selection, empty-workspace handling, attention summary — all pure, all unit-tested.
- [ ] Source-level regression guard (new `*WiringTests`) asserts the new workspace/tab wiring is present and the old "Terminals in"/projects-as-workspaces/PWD-dump wiring is gone.
- [ ] `swift run … OuroWorkbench --uisurfacetest` passes (sidebar + tab-strip render with a populated migrated state; no crash).
- [ ] 100% line+region coverage on all new Core code (`Scripts/check-coverage.sh` green; `Scripts/coverage-allowlist.txt` does NOT grow).
- [ ] `swift build`/`swift test` with `-Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` — 0 warnings, 0 failures (incl. the updated blast-radius tests).
- [ ] `SerpentGuide.ouro/` NOT staged. No Co-Authored-By / AI attribution. One commit per unit.

## Code Coverage Requirements
**MANDATORY: 100% line + region coverage on all new Core code.**
- No growth of `Scripts/coverage-allowlist.txt`. Every new line + branch arm of `WorkspaceSidebarPresentation` (ordering, tab resolution, dangling-id drop, active-workspace selection, empty handling, attention summary) must be exercised by an XCTest.
- All error/edge paths tested: empty `workspaces`, workspace with empty `tabIds`, dangling `tabId` (entry deleted), `selectedWorkspaceId` nil / stale / valid, single-tab vs many-tab workspace, pinned vs unpinned ordering, mixed override/auto names, attention-summary arms (all `AttentionState` values present in tabs), active/archived partition (some archived, none archived, all archived).
- Core IS test-visible (`@testable import OuroWorkbenchCore`). This is **strict XCTest TDD** for the seam. App view wiring is NOT coverage-gated but IS compiled under the strict flags.
- App-side: no new uncovered Core; the view code lives in `OuroWorkbenchApp` (not gated). The Core seam carries ALL the gated logic.

## TDD Requirements
**Strict TDD — no exceptions (for the Core seam):**
1. **Tests first**: write failing XCTest for the seam BEFORE any implementation.
2. **Verify failure**: `swift test` strict — confirm RED for the RIGHT reason (missing symbol / wrong behavior).
3. **Minimal implementation**: just enough Core code to pass.
4. **Verify pass**: `swift test` strict — GREEN, 0 warnings.
5. **Refactor + coverage**: `Scripts/check-coverage.sh` → 100%; refactor with tests green.
6. **No skipping**: never write seam implementation without a failing test first.

**For App view wiring (NOT XCTest-visible — Slice ① pattern):** write the source-level regression guard FIRST (it fails RED while the old wiring is present / new wiring absent), then do the view edit to make it GREEN, then confirm `--uisurfacetest`. **Do NOT fabricate XCTests for SwiftUI glyphs.**

---

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

> Every Core-seam unit: red XCTest → green minimal impl → coverage 100% → strict build/test → **one commit**. Every App-wiring unit: red source-guard → green view edit → `--uisurfacetest` → strict build → **one commit**. Save red/green/coverage/gate tails to the artifacts dir per unit.

### ⬜ Unit 0: Baseline + blast-radius sweep + migrated UI fixture (Setup/Research)
**What**:
- Capture the GREEN baseline: strict `swift test` + `Scripts/check-coverage.sh`; save tails to `artifacts/baseline-gate.txt`. Confirms the branch starts clean (allowlist = its current entries; `--uisurfacetest` passes).
- **Blast-radius sweep**: grep ALL of `Tests/` and `Sources/` for: `"Terminals in"`, `terminalsSectionTitle`, `workspaceSectionTitle`, `SidebarProjectRow`, `Text(project.rootPath)`, `setupWorkspaceName`, `state.projects` (render uses), and every `source.contains(` guard referencing the sidebar/terminals section. Record the EXACT, complete set of files+lines that will break or must change in `artifacts/blast-radius.md` (the known two `*WiringTests`/`*Tests` are seeds — confirm completeness, ②a-style). No edit yet.
- Build a **migrated-state UI fixture**: a `WorkspaceState` (or its JSON) that has gone through ②a's migration — one `Workspace{autoName:"Restored workspace", tabIds:[…]}` covering ≥2 `ProcessEntry`s (mix of names + one `tabNameOverride` set), plus a second pinned workspace with 1 tab and an empty workspace with 0 tabs (to exercise FORK #2/#3 in the smoke). Save to `artifacts/fixtures/migrated-ui-state.json`. This drives the `--uisurfacetest` smoke (Unit 4) and documents the render target.
- Record in `artifacts/baseline-notes.md`: the DB1 render-swap decision, the active-workspace fallback rule chosen, and the three forks' chosen defaults.
**Output**: `artifacts/baseline-gate.txt`, `artifacts/blast-radius.md`, `artifacts/fixtures/migrated-ui-state.json`, `artifacts/baseline-notes.md`.
**Acceptance**: baseline gates GREEN as recorded; blast-radius.md enumerates every breaking test/site with file:line; fixture is valid JSON decodable as `WorkspaceState` (sanity-decode in a throwaway test or `python3 -m json.tool`); notes capture DB1 + fallback rule + fork defaults.
**Commit** `docs(doing): slice2b baseline + blast-radius sweep + migrated UI fixture` (artifacts only; no source change).

### ⬜ Unit 1a: `WorkspaceSidebarPresentation` seam — Tests (RED)
**What**: New file `Tests/OuroWorkbenchCoreTests/WorkspaceSidebarPresentationTests.swift`, all FAILING (type doesn't exist). Assert the pure derivation:
- **Workspace ordering**: pinned workspaces first (stable), then stored order. Mixed pinned/unpinned input → pinned-first output, order within each partition preserved.
- **Tab resolution + ordering**: given a workspace's `tabIds` and the entry list, resolve to `ProcessEntry`s in `tabIds` order; each tab exposes `effectiveTabName`.
- **Dangling-id drop**: a `tabId` with no matching entry is skipped (not crashed, not blank); the drop is observable (e.g. resolved-tab count < tabIds count; attribute the drop so it's never silently wrong).
- **Active-workspace selection**: `selectedWorkspaceId` valid → that workspace; nil → deterministic fallback (first after pinned-first ordering); stale (id not in workspaces) → same fallback. Pin the rule.
- **Empty-workspace handling**: a workspace with 0 resolved tabs yields an explicit empty marker (FORK #3 default: render the row + an inline "no tabs yet" tab-strip state, NOT hide the workspace).
- **Attention summary (lean row context)**: a workspace's row context summarizes its tabs' `ProcessEntry.attention` (e.g. "any tab needs attention" / highest-severity state) — cover every `AttentionState` arm. **No cost field anywhere in the returned type** (assert via the type's surface / a Mirror-style check that no usd/tok/cost member exists — mirrors ②a's boundary invariant).
- **Single-tab vs many-tab**: both resolve correctly (FORK #2 governs row presentation, but the seam returns the tab list either way).
- **Archived partition (DB7)**: a workspace's tabs split into active vs archived (`ProcessEntry.isArchived`); the strip uses active, the archived list uses archived; a workspace with no archived tabs yields an empty archived partition (so the App can hide the section).
**Acceptance**: tests FAIL to compile/run because `WorkspaceSidebarPresentation` is undefined (red, right reason). Record `artifacts/unit1a-red.txt`.

### ⬜ Unit 1b: `WorkspaceSidebarPresentation` seam — Implementation (GREEN)
**What**: Add `Sources/OuroWorkbenchCore/WorkspaceSidebarPresentation.swift` — a pure `enum`/`struct` deriver (no SwiftUI, no view-model dep): `public static func resolve(workspaces:entries:selectedWorkspaceId:) -> WorkspaceSidebarModel` (typed result: ordered rows, each with `effectiveName`, resolved ordered tabs `[ResolvedTab]` carrying `effectiveTabName` + `attention`, `isPinned`, an `isEmpty` marker, and a `WorkspaceRowContext` attention summary). Implement ordering, resolution, dangling drop, active selection, empty handling, attention summary. Mirror ②a's lenient/pure posture. Doc-comment it as the **sidebar/tab-strip view-model derivation seam** and state it carries NO cost/runtime-pid fields.
**Acceptance**: Unit 1a tests PASS (green). Strict `swift build`/`swift test` — 0 warnings/0 failures. Record `artifacts/unit1b-green.txt`. **Commit** `feat(core): add WorkspaceSidebarPresentation derivation seam (ordering, tab resolution, attention summary)`.

### ⬜ Unit 1c: seam coverage + no-cost/no-runtime boundary invariant — Coverage & Refactor
**What**: `Scripts/check-coverage.sh`; add targeted tests for any uncovered arm (empty workspaces list, empty `tabIds`, all-dangling tabIds, every `AttentionState`, pinned-only/unpinned-only ordering, nil/stale/valid selection). Add the **boundary invariant** test: the returned model + `ResolvedTab` + `WorkspaceRowContext` expose ONLY structure/work-context fields (name, tabs, attention, pin, empty-marker) and NO cost/usd/tok/pid/run field (Mirror or explicit enumeration — mirrors ②a DA2). Allowlist unchanged.
**Acceptance**: `Scripts/check-coverage.sh` 100% on the seam; allowlist not grown; boundary invariant green. Record `artifacts/unit1c-coverage.txt`. **Commit** `test(core): pin WorkspaceSidebarPresentation 100% coverage + no-cost/no-runtime boundary invariant`.

### ⬜ Unit 2a: sidebar rewire — source-regression guard (RED)
**What**: New file `Tests/OuroWorkbenchCoreTests/WorkspaceSidebarWiringTests.swift` (mirrors the existing `*WiringTests` + `WorkspaceHomeNamingTests` `appSource()`/`repoRoot()` pattern). Assert against the App source, **failing while the OLD wiring is still present**:
- PRESENT (new): the sidebar renders workspace rows via `WorkspaceSidebarPresentation.resolve(` (the seam is wired in), and a new workspace-rows section/`ForEach` over the resolved model.
- ABSENT (old): `ForEach(model.state.projects)` in the sidebar section, `SidebarProjectRow(`, `Text(project.rootPath)`, and `Section(WorkbenchSurfacePolicy.terminalsSectionTitle(workspaceName: model.selectedProject?.name))` are GONE from the sidebar render path.
- KEEP-present: the Archived section and the Recovery section wiring still present (regression guard that the rewire didn't drop them).
Also **update the two known breaking guards** to their new truth (re-point `WorkspaceHomeNamingTests:52-64` and `WorkbenchSurfacePolicyTests:25-38` to assert the new wiring) — but as RED first if they reference symbols not yet present; coordinate so the suite is red for the right reason.
**Acceptance**: the new guard FAILS because the old wiring is still present / the new wiring absent (red, right reason). Record `artifacts/unit2a-red.txt`.

### ⬜ Unit 2b: sidebar rewire — view edit (GREEN)
**What**: In `OuroWorkbenchApp.swift`:
- Replace the "Workspaces"(=projects) section (`:3098-3130`) AND the "Terminals in <name>" section (`:3131-3168`) with a single **Workspaces section that renders `state.workspaces`** via `WorkspaceSidebarPresentation.resolve(workspaces: model.state.workspaces, entries: model.allSessionEntries, selectedWorkspaceId: …)`. Each workspace row shows `effectiveName` + lean work-context (attention summary from the seam; NO `rootPath`, NO cost). Reuse `TerminalAgentRow`/`SessionChip` to render the workspace's tabs by `effectiveTabName` per FORK #2's chosen presentation (see Decisions).
- Add a `selectedWorkspaceID` to the view-model (mirrors `selectedProjectID`) OR derive active workspace from the selected entry's membership — pick per the seam's active-workspace rule; wire selection so clicking a tab selects its entry (existing `selectedEntryID`) and its workspace becomes active. **Do NOT remove `selectedProjectID` or its `didSet`-save** (DB1 — backing model; `PersistenceSalvageWiringTests:158-225` guards it).
- **Archived-section scoping decision (DB7):** today `archivedSessionEntries` is scoped to `selectedProjectID` (`:11385-11398`). With the sidebar now selecting WORKSPACES, define the rule: scope Archived to the ACTIVE WORKSPACE's tabs (archived entries whose id was a member, or whose `projectId` matches the workspace's tabs' projects) OR show all archived globally. **Default (DB7): scope Archived to the active workspace** (archived entries among that workspace's tab population), so the section stays coherent with the selected unit; if a workspace has no archived tabs, the section hides (existing `!isEmpty` guard). Pin and test this in the seam if it becomes derivation logic.
- Preserve Recovery section unchanged (it's global, not project-scoped).
- The PWD dump (`Text(project.rootPath)`) is removed from the sidebar path.
- Keep `WorkbenchProject`/`projectId` machinery intact (DB1 — backing model; new-terminal flows still pass `projectId`). Do NOT delete `SidebarProjectRow` if it's still referenced elsewhere (verify; if now-dead, removal is allowed and proven by warnings-as-errors).
**Acceptance**: Unit 2a guard PASSES (green); the two re-pointed guards pass. Strict `swift build` — 0 warnings (proves no dead/broken refs). Record `artifacts/unit2b-green.txt`. **Commit** `feat(app): render named workspaces in sidebar; delete projects-as-workspaces + PWD dump`.

### ⬜ Unit 3a: cmux tab-strip — source-regression guard (RED)
**What**: Extend `WorkspaceSidebarWiringTests` (or a sibling) asserting against the App source, failing while absent:
- PRESENT (new): a tab-strip view in the detail column (e.g. `WorkspaceTabStrip` / a horizontal tab row) that renders the active workspace's resolved tabs by `effectiveTabName`, mounted above the session detail (between the Boss dashboard divider @ `:379` and the detail `Group` @ `:383`).
- The tab-strip sources its tabs from `WorkspaceSidebarPresentation` (the active workspace's tabs), NOT from a re-derived flat list.
**Acceptance**: FAILS because the tab-strip wiring is absent (red, right reason). Record `artifacts/unit3a-red.txt`.

### ⬜ Unit 3b: cmux tab-strip — view edit (GREEN)
**What**: In `OuroWorkbenchApp.swift` detail column (`:365-398`), add the **active-workspace tab-strip across the top**: a horizontal strip of named tabs (`effectiveTabName`) for the active workspace's resolved tabs; selecting a tab sets `selectedEntryID`; the selected tab is highlighted; the strip sits above the existing `HeaderView`/detail `Group` (cmux layout). Empty active workspace → the strip shows the empty marker (FORK #3). Single-tab → per FORK #2 presentation. Mount it so it does not starve the pinned header (respect the existing `.fixedSize`/`.layoutPriority` posture).
**Acceptance**: Unit 3a guard PASSES (green). Strict `swift build` — 0 warnings. Record `artifacts/unit3b-green.txt`. **Commit** `feat(app): add cmux tab-strip rendering the active workspace's named tabs across the top`.

### ⬜ Unit 4: "Home"/"Terminals in" cleanup + full-gate integration (GREEN, confirm)
**What**:
- Remove the now-unused "Terminals in" framing: if `terminalsSectionTitle(workspaceName:)` (`WorkbenchSurfacePolicy.swift:56-62`) has NO remaining caller after Unit 2b, delete it AND its value-tests (`WorkspaceHomeNamingTests:27-46`); if a caller remains, keep it and leave those tests. Verify by grep. Either way, the sidebar no longer shows "Terminals in <name>".
- Confirm `setupWorkspaceName = "Home"` is no longer a VISIBLE workspace row (it's the invisible backing-project default under DB1). Do NOT rename it unless FORK #4 is taken. The `setupWorkspaceName == "Home"` + `WorkbenchBootstrapperTests` assertions stay GREEN.
- Run the FULL gate set, tails to `artifacts/unit4-gates.txt`:
  - `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` — 0 warnings.
  - `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` — 0 failures (incl. updated blast-radius tests).
  - `swift run -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete OuroWorkbench --uisurfacetest` — no crash. **Extend the `--uisurfacetest` smoke** (`UISurfaceTest.swift`) to instantiate the sidebar + tab-strip with the Unit-0 migrated fixture (a `WorkspaceState` with the "Restored workspace" + a pinned single-tab + an empty workspace) and assert they render/fit without crash — mirroring the existing `fittingSize(...)` smoke. This is the App-side "renders correctly" proof for the migrated "Restored workspace".
  - `Scripts/check-coverage.sh` — PASS; `git diff Scripts/coverage-allowlist.txt` EMPTY (did not grow).
- `git diff --name-only` for the slice touches ONLY: `Sources/OuroWorkbenchCore/WorkspaceSidebarPresentation.swift` (new); `Sources/OuroWorkbenchCore/WorkbenchSurfacePolicy.swift` (if `terminalsSectionTitle` deleted); `Sources/OuroWorkbenchApp/OuroWorkbenchApp.swift` (sidebar + tab-strip); `Sources/OuroWorkbenchApp/UISurfaceTest.swift` (smoke extension); the new `Tests/…/WorkspaceSidebarPresentationTests.swift` + `Tests/…/WorkspaceSidebarWiringTests.swift`; the updated `Tests/…/WorkspaceHomeNamingTests.swift` + `Tests/…/WorkbenchSurfacePolicyTests.swift` (re-pointed guards; + value-test removals IF `terminalsSectionTitle` deleted); plus `worker/tasks/…` docs/artifacts. Any file OUTSIDE this set changing — especially `WorkbenchBootstrapperTests.swift` (should NOT change under DB1) — is a scope leak; stop and investigate. NO `SerpentGuide.ouro/`.
**Acceptance**: all four gates green; allowlist unchanged; only expected files changed; the `--uisurfacetest` smoke renders the migrated "Restored workspace" sidebar + tab-strip without crash. Record `artifacts/unit4-gates.txt`. **Commit** `feat(app): remove Terminals-in-Home framing; smoke-test migrated workspace render`.

---

## Execution
- **TDD strictly enforced**: Core seam = real XCTest red→green→coverage; App wiring = source-guard red→view-edit green→`--uisurfacetest`. One commit per unit. NO Co-Authored-By / AI attribution.
- **Push** after the slice's units complete (per repo workflow); do NOT open a PR (operator instruction).
- **All artifacts** (red/green/coverage/gate tails, fixtures, blast-radius, notes) → `./2026-06-24-1946-doing-slice2b-workspaces-sidebar/`.
- **Do NOT stage** `SerpentGuide.ouro/`.
- **Do NOT** move state to a dedicated store (②c), add Rename/Pin/Remove-Name affordances (②d), add propose-first bring-back (④), or smart auto-names (⑤). ②b renders `autoName`/`effectiveName` as-is; the migrated default is literally "Restored workspace".
- **Do NOT** delete `WorkbenchProject` / `projectId` (DB1 — backing launch model; render-layer swap only).
- **Fixes/blockers**: if a gate fails unexpectedly (e.g. a hidden source-guard the blast sweep missed, or selection wiring that breaks an existing flow), spawn a sub-agent to investigate immediately; update this doc + commit (`docs(doing):`).
- **Decisions made during execution**: update this doc immediately, commit right away.

## Decisions Made (②b defaults — reversible/auditable picks)
- **DB1 — ②b is a render-layer swap; `WorkbenchProject`/`projectId` stay as the backing launch model.** The sidebar/tab-strip render `state.workspaces` (the design's visible truth); the directory-anchored project machinery remains for now (new terminals still get a `projectId`; ②a's migration folds them into a workspace on next load). Deleting `WorkbenchProject`/`projectId` is a larger, separable change (②c/②d). Reversible: a render-layer revert restores the old sidebar without touching state. **This is FORK #1 — see below.**
- **DB2 — Active-workspace fallback is deterministic.** `selectedWorkspaceId` valid → that workspace; nil/stale → first after pinned-first ordering. Guarantees a just-migrated state (one "Restored workspace") has a defined active workspace with no extra selection step.
- **DB3 — Dangling `tabId`s are dropped (not crashed, not blank) and the drop is attributed.** Mirrors ②a's lenient posture; a deleted entry's stale id never sinks the render.
- **DB4 — The lean row carries attention summary + (App-side) branch; NEVER cost.** The Core seam decides which attention summary to show; branch comes from the existing `model.gitStatus(for:)` passed through the view. No new metadata surface is invented (master plan defers work-context-as-new-surface). **FORK #2 governs the exact row/tab presentation.**
- **DB5 — Empty workspace renders its row + an inline "no tabs yet" tab-strip state** (not hidden). Honest, never-blank. **FORK #3.**
- **DB6 — `setupWorkspaceName = "Home"` is NOT renamed by ②b.** It's the invisible backing-project default after the render swap; renaming it (and its tests) is out of ②b's minimal scope. **FORK #4 if the operator wants it renamed/removed.**
- **DB7 — Archived section is scoped to the active workspace** (not the old `selectedProjectID`, not global). Keeps the Archived list coherent with the selected unit; hides when the active workspace has no archived tabs. Reversible to global if the operator prefers (FORK #5).

## Open forks for the operator (FLAGGED — defaults chosen above; the first three are user-facing UI/UX on the first VISIBLE slice)
1. **FORK #1 (architecture, has UX consequence) — render swap vs full project→workspace migration.** Default (DB1): ②b renders `state.workspaces` and leaves `WorkbenchProject`/`projectId` as the backing model. **UX consequence:** after ②a's migration the sidebar shows a SINGLE "Restored workspace" row containing every terminal — the operator's previous multi-project grouping is no longer the displayed structure (it survives in state, just isn't shown). This is the design's stated honest-migration intent, but it is the single most visible change in ②b. *Alternative:* ②b could derive one workspace PER existing project (group by `projectId`) so the migrated sidebar preserves the prior grouping shape — at the cost of contradicting ②a's "fold into one Restored workspace" migration and adding a project→workspace derivation ②a explicitly didn't do. **Surface to operator: is the single "Restored workspace" the desired first-run-after-upgrade view, or should existing projects map 1:1 to workspaces?**
2. **FORK #2 (user-facing UI/UX) — how a workspace with one vs many tabs is presented.** Default: tabs always render in the top tab-strip (even a single-tab workspace shows one tab); the sidebar workspace ROW shows `effectiveName` + attention summary (lean), and expanding/selecting it makes its tabs the active tab-strip. *Alternatives:* (a) inline the tabs UNDER the workspace row in the sidebar (disclosure-style) instead of / in addition to the top strip; (b) collapse a single-tab workspace's name into the tab itself (no separate row). **Surface to operator: tabs-on-top only, or sidebar-disclosure too? Single-tab special-casing?**
3. **FORK #3 (user-facing UI/UX) — empty-workspace handling.** Default (DB5): show the workspace row + an inline "no tabs yet" empty state in the tab-strip. *Alternative:* hide empty workspaces entirely. Chosen visible because onboarding (③) will seed workspaces that legitimately start empty, and hiding them would make a just-created workspace vanish. **Surface to operator if a hidden-until-populated policy is preferred.**
4. **FORK #4 (minor, low-visibility) — rename the backing default "Home" project.** Default (DB6): leave `setupWorkspaceName = "Home"` (invisible after the swap). *Alternative:* rename/remove it for cleanliness. Out of ②b's minimal scope; flagged only for completeness. **Not user-facing under DB1; surface only if a clean removal is wanted.**
5. **FORK #5 (user-facing UI/UX) — Archived section scoping.** Default (DB7): scope the Archived section to the ACTIVE WORKSPACE's tabs (hides when none). *Alternative:* show archived terminals globally (all workspaces) in one Archived section. Chosen workspace-scoped to stay coherent with "everything is shown under its workspace," but a global archive is defensible if the operator treats archive as a flat recycle-bin. **Surface to operator: per-workspace archive or global archive?**

## Progress Log
- 2026-06-24 19:46 Created from master plan Slice ②b. Read master plan (Slice ② decomposition, ②a→②b dep, D4), ideation (cmux model, no-Home, lean rows, name-by-work), and the ②a doing doc (Workspace/Tab model + migration). Re-verified ALL anchors at HEAD 93b3668 (= origin/main; ②a landed via PR #285): the sidebar renders `state.projects`/`SidebarProjectRow` (PWD dump `Text(project.rootPath)` @ :3248) + a "Terminals in <name>" section (`terminalsSectionTitle` @ WorkbenchSurfacePolicy.swift:56) over `model.sessionEntries`; NOTHING reads `state.workspaces` yet (only the migration call @ :19948); NO existing top tab-strip (terminals are sidebar rows + a single-entry detail pane). Confirmed the two coexisting membership models (`WorkbenchProject`+`projectId` vs `Workspace.tabIds`) and the central UX consequence (migration folds all entries into one "Restored workspace"). Confirmed the App-side test posture: `--uisurfacetest` (`UISurfaceTest.swift`) only exercises About/Update today (extendable to smoke the sidebar); source-level wiring guards (`*WiringTests` + `WorkspaceHomeNamingTests:52-64`/`WorkbenchSurfacePolicyTests:25-38`) are the established App-view-regression mechanism; `WorkbenchProject` work-context (`attention`, `gitStatus`) already available for lean rows. Identified the testable Core seam (`WorkspaceSidebarPresentation`) and the blast radius. Did an independent exhaustive `appSource()`-guard sweep of `Tests/`: confirmed the two known source-guards (`WorkspaceHomeNamingTests:52-64`, `WorkbenchSurfacePolicyTests:25-38`) + `WorkbenchBootstrapperTests:9-10` break; ADDED `PersistenceSalvageWiringTests:158-225` (constraint: keep `selectedProjectID` under DB1) and the cosmetic `OnboardingBossChoiceRowAccessibilityWiringTests:12` comment ref; confirmed `WorkspaceSummary/Onboarding/AutonomyReadiness/BossAgentPromptBuilder` tests are fixture-only (bump-safe under DB1). Confirmed `migratedWorkspaceSeedName == "Restored workspace"` (WorkspaceModels.swift:941). Surfaced the Archived-section scoping question (DB7 / FORK #5). Defined Units 0–4. Recorded DB1–DB7 defaults; flagged 5 forks (FORKS #1,#2,#3,#5 user-facing; #4 low-visibility) for the operator. **Status: drafting → pending fresh sub-agent review gate before READY_FOR_EXECUTION.**
