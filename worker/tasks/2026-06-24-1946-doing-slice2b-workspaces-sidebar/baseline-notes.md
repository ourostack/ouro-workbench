# Slice ②b — Baseline notes (Unit 0)

**Branch**: `feat/slice2b-workspaces-sidebar` @ HEAD `3e45d03` (off `origin/main` @ 93b3668; ②a landed).

## Baseline gates (all GREEN — see baseline-gate.txt)
- `swift build -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` → Build complete, 0 warn/err.
- `swift test` strict → 2738 tests, 0 failures, 1 skipped.
- `Scripts/check-coverage.sh` → PASS; 146/148 files 100% line+region (2 allowlisted:
  `BossAgentMCPClient.swift 1 2`, `SessionActivityReader.swift 0 1`). Allowlist snapshot saved to
  `coverage-allowlist.baseline.txt` (2 non-comment entries) — MUST NOT grow.
- `swift run ... OuroWorkbench --uisurfacetest` → all checks ok (exit 0).

## DB1 render-swap decision (the architecture of ②b)
②b is a **render-layer swap**: the sidebar/tab-strip render `state.workspaces` (the design's visible
truth) via the new pure Core seam `WorkspaceSidebarPresentation`. The directory-anchored
`WorkbenchProject`/`projectId` machinery stays as the **backing launch model** (new terminals still get
a `projectId`; ②a's migration folds them into a workspace on next load). NOT deleting `WorkbenchProject`
/`projectId` (that's ②c/②d). Reversible: a render-layer revert restores the old sidebar without touching
state. After ②a's migration an existing state shows a SINGLE "Restored workspace" containing all
terminals — the design's honest-migration intent; ②b makes that the displayed truth.

## Active-workspace fallback rule (DB2 — pinned in the seam)
`selectedWorkspaceId` valid (in the workspace set) → that workspace. nil OR stale (id not in set) →
the FIRST workspace AFTER pinned-first ordering. Guarantees a just-migrated single-"Restored workspace"
state has a deterministic active workspace with no extra selection step. (Pinned-first ordering is
applied BEFORE the fallback picks "first", so a pinned workspace wins the default.)

## Fork defaults chosen (per the doing doc's Decisions Made)
- **FORK #1 (DB1):** render swap → single "Restored workspace" after migration (NOT 1:1 project→workspace).
- **FORK #2 (DB4):** tabs render in the TOP tab-strip; the sidebar ROW shows `effectiveName` + lean
  attention summary (NO rootPath, NO cost). Single-tab and many-tab both resolve to the tab list; the
  strip renders whatever tabs the active workspace has.
- **FORK #3 (DB5):** an empty workspace renders its ROW + an inline "no tabs yet" empty-state marker in
  the tab-strip (NOT hidden) — onboarding ③ will seed legitimately-empty workspaces.
- **FORK #4 (DB6):** `setupWorkspaceName = "Home"` NOT renamed (invisible backing default after swap).
- **FORK #5 (DB7):** Archived section scoped to the ACTIVE WORKSPACE's tabs (the seam partitions a
  workspace's resolved tabs into active vs archived); hides when the active workspace has no archived tabs.
- **FORK #6 (DB8):** the sidebar "New Workspace" action row is REMOVED (manual create is ②d; seeded by ③/④).
- **DB9:** expose a non-private VM accessor for the seam's entry input (`allSessionEntries` is `private`).

## Migrated-UI fixture (drives Unit 4 --uisurfacetest smoke)
`fixtures/migrated-ui-state.json` (schemaVersion 2, valid + decodable) contains:
- A **pinned** workspace "Pinned workspace" with 1 tab (`needsBossReview` attention) — exercises
  pinned-first ordering + single-tab + FORK #2.
- The migration default **"Restored workspace"** with 4 tabIds: an `active` agent, a `waitingOnHuman`
  agent carrying a `tabNameOverride` ("Agent Substrate"), an `idle` shell, and an `isArchived` agent —
  exercises effectiveTabName, attention-summary arms, and the active/archived partition (DB7).
- An **empty** workspace "Empty workspace" with 0 tabIds — exercises FORK #3 (empty marker).
This is the render target for the migrated sidebar + tab-strip smoke.
