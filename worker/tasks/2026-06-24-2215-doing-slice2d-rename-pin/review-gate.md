# Slice ②d doing-doc — Fresh Unbiased Review Gate

**Reviewer**: fresh context-free general-purpose sub-agent (no prior context).
**Date**: 2026-06-24
**Doc under review**: ../2026-06-24-2215-doing-slice2d-rename-pin.md (at commit f797845)

## VERDICT: PASS (3 MINOR notes, none blocking)

Every load-bearing claim independently verified against the codebase at HEAD on `feat/slice2d-rename-pin`.

### Claims verified (all CONFIRMED)
1. Model exists as described — `Workspace.nameOverride`/`isPinned`/`effectiveName` (WorkspaceModels.swift:685/687/728), `ProcessEntry.tabNameOverride`/`effectiveTabName` (:262/:337); DA4 "empty override honored, revert==nil" explicit in doc-comments.
2. Render sites correct — `WorkspaceSidebarRow` :3158, `WorkspaceTabStrip.tabButton` :3308, `TerminalRowContextMenu` :3497 (mirror pattern + `togglePin`/`isPinned` :3527-3531). Instantiation site :3091 has NO existing `.contextMenu` (clean attachment).
3. Pin re-sort (D2d-4) — `resolve` orders pinned-first (WorkspaceSidebarPresentation.swift:126); `model.workspaceSidebarModel` computed, re-resolves each render (:11470). No new sort wiring needed.
4. Access level (D2d-6) — App plain `import OuroWorkbenchCore` :4 (not @testable); `public extension WorkspaceState` block :898 (precedent `applyAutomaticBossDefaults` :930). New mutators must be public — confirmed.
5. Keyboard shortcuts free (D2d-5) — no `.keyboardShortcut("r"` anywhere; chord-dispatcher pattern (D2d-8) real (`.commands { CommandMenu(...) }` targeting `model.activeEntry` :297-302); `activeWorkspaceRow` :11481 + `selectedEntryID` :10412 exist as chord targets.
6. `WorkspaceRow` lacks `nameOverride` (:70-78) — Unit 4b's additive-field anticipation is correct. Source-guard helpers real (WorkspaceSidebarWiringTests.swift:232/:240; NavCheckInWiringTests.swift:65-70 chord-targets-active example). `--uisurfacetest` `fittingSize`+assert-seam pattern real.

### Rubric judgement
- COVERAGE: every ②d affordance maps to a unit; planning-coverage-checklist cross-checks cleanly; nothing dropped.
- SCOPE DISCIPLINE: no creep into ②c/④/⑤/creation-flow; Unit 7 guards it.
- TDD RIGOR: Core seams RED-first XCTest + 100% region + frozen allowlist; SwiftUI source-regression-first + `--uisurfacetest`; no fabricated SwiftUI XCTests.
- DECISION SOUNDNESS (D2d-1): empty/whitespace = no-op is reasonable + reversible; NOT a contradiction with DA4 (model layer honors empty; D2d-1 only stops the EDITOR producing one). Internally consistent.
- INTERNAL CONSISTENCY: real anchors, one-commit-per-unit, gates listed, no AI attribution, `SerpentGuide.ouro/` flagged not-to-stage (confirmed untracked).

### MINOR notes (incorporated into the doc)
1. Confirm at execution the tab chord targets `selectedEntryID` (the selected tab). No fix needed.
2. Keep Unit 4a's RED assert + Unit 4b's GREEN token for the Remove-Custom-Name gate in LOCKSTEP (whichever token 4b implements). → Doc hardened in Unit 4a.
3. Unit 6a Escape-cancel: pick ONE mechanism and assert that exact token, not a vacuous "any-of-three" multi-contains. → Doc hardened in Unit 6a.

## Outcome
PASS. Doc declared READY_FOR_EXECUTION. Notes 2 & 3 hardened into the doc; note 1 is execution-time discipline.
