# U5 Unit 2 — B1 (sidebar / workspace tabs+rows cluster) drive-to-100% records

**Measured on** `WorkbenchViews.swift` @ branch `u5-b1-sidebar` (off `origin/main 4ed673d`, post-B2/B4).
Coverage via `swift test --enable-code-coverage` → `xcrun llvm-cov export … WorkbenchViews.swift`
(gate metric = code-region segments with `kind==0 && count==0`); per-view attribution via
`/tmp/b1-measure.py` over `decls-postsplit.txt` (same producer as the batch plan).

## The recipe (confirmed for B1)

ViewInspector 0.10.3 **descends `Menu {}` content**, **invokes `Button` actions via `.tap()`**, and
**invokes `callOnSubmit()` / `callOnExitCommand()`**. So the prior C0/C1/SU3/SU4/SU-C suites that
snapshot the LABELS of these sidebar/tab/menu views never executed their ACTION closures — those were
the uncovered regions. Each driven region: invoke the closure → assert the `@Published`/`state`
side-effect → MUTATION-VERIFY (mutate the action body in `WorkbenchViews.swift` → the effect-assertion
goes RED → revert → GREEN). The mutation sweep is recorded per-view below.

## File-summary delta (B1 cluster)

| metric | BEFORE (post-B2) | AFTER B1 |
|---|---|---|
| WorkbenchViews.swift region | 69.11% (923 uncov / 2988) | **~70.6% (~877 uncov / 2988)** |
| **B1 cluster uncovered regions** | **54** | **8** (all genuine carves) |
| tests | 3504 / 1 skip / 0 fail | **3504 + 50 B1 tests / 1 skip / 0 fail** |

> B1 closed **46 of 54** regions (driven+asserted+mutation-verified). The remaining **8** are genuine,
> `--show-regions`-justified carves recorded for Unit 3 (7 = the `.task` self-refresh loop;
> 1 = a proven-dead `?? "unknown"` fallback). NONE is an un-driven ordinary arm.

## Per-view BEFORE → driven (via INVOCATION + effect asserted + mutation RED→GREEN) → carved → AFTER

| view | line | BEFORE uncov | driven | carved | AFTER uncov |
|---|---|---|---|---|---|
| WorkbenchSidebarView | 3025 | 20 | 13 | **7** | 7 |
| TerminalRowContextMenu | 3615 | 16 | 16 | 0 | **0** |
| WorkspaceRowContextMenu | 3234 | 3 | 3 | 0 | **0** |
| WorkspaceTabStrip | 3309 | 3 | 3 | 0 | **0** |
| WorkspaceTabContextMenu | 3446 | 3 | 3 | 0 | **0** |
| SidebarFilterField | 2946 | 2 | 2 | 0 | **0** |
| InlineRenameEditor | 3271 | 2 | 2 | 0 | **0** |
| WorkspaceSidebarRow | 3169 | 1 | 1 | 0 | **0** |
| SidebarAgentRow | 3488 | 1 | 1 | 0 | **0** |
| TerminalAgentRow | 3717 | 1 | 1 | 0 | **0** |
| GitBranchChip | 3847 | 1 | 0 | **1** | 1 |
| ElapsedTimePill | 3886 | 1 | 1 | 0 | **0** |
| **B1 total** | | **54** | **46** | **8** | **8** |

### TerminalRowContextMenu (16→0) — `TerminalRowContextMenuInteractionTests`
DRIVEN via INVOCATION (each `find(button:).tap()` asserts a `@Published`/`state` mutation):
- Launch (inactive custom) → `launch(entry)` builds a plan cleanly (no `errorMessage`); the async
  `start` Task is the live-PTY path charged on the non-gated VM file.
- Stop (live `.active` session, injected `TerminalSessionController` — NO `start()`, no spawn) →
  `requestStop` arms `pendingStopSession` (the U11 consequence-gated path).
- Ask Boss → the `Task { await runBossQuestion(about:) }`'s synchronous prefix sets `bossQuestion`
  + expands the boss pane.
- Pin/Unpin → `togglePin` flips `isPinned`; the pinned fixture also renders the `isPinned` ternary's
  "Unpin from Top"/`pin.slash` arm.
- Copy Launch Command → records the `copyLaunchCommand` action-log entry.
- Copy Last 20 Lines (a real transcript file on disk → the button is ENABLED) → records the
  `copyTranscriptTail` action-log entry (success path). The no-transcript arm is `.disabled` —
  a tap can't reach it (defensively-disabled, NOT carved: the action region is driven via the enabled path).
- Open Working Directory (a `/tmp/...` dir that does not exist) → the missing-directory guard sets `errorMessage`.
- Edit Session… → `editingSession == entry`. Duplicate Session → `processEntries` grows by one.
- Move to Workspace (two-project state; the descended `Menu`'s "Backend" target Button) → the entry's
  `projectId` changes to the target.
- Archive/Restore → `isArchived` flips. Delete Session… → arms `pendingDeleteSession`.
- MUTATION-VERIFY: `model.togglePin(for: entry)` → `_ = model` → `testNegativeControl_pinActionTogglesPin`
  + `testTap_pin…` RED → reverted → GREEN. `moveSession` mutation likewise covered by `testNegativeControl_moveActionChangesProject`.

### WorkbenchSidebarView (20→7) — `WorkbenchSidebarViewInteractionTests`
DRIVEN (13): the boss-section `ForEach(model.ouroAgents)` body (agents set via the `@Published ouroAgents`
the scan writes) + the `SidebarAgentRow.select` closure (tap → `selectAgent` → `selectedAgentName`);
"Create Agent"/"Clone from Git…" (non-empty-agents else arm → `isProviderConfigPresented`/`isOuroAgentInstallSheetPresented`);
"Create Your First Agent" (empty-agents if arm → provider form); "New Terminal" → `isNewSessionSheetPresented`;
the `if shouldShowRecovery` arm + its Button (driven by a real `.needsRecovery` `ProcessRun` →
`recoveryDigest.actionableCount > 0`) → `isRecoverySheetPresented`. Negative control: no recoverable
runs → the Recovery section vanishes (the arm flips). MUTATION-VERIFY: `model.isRecoverySheetPresented = true`
→ `_ = model` → `testRecovery_buttonTap_presentsRecoverySheet` RED → reverted → GREEN.

CARVE (7) — recorded for Unit 3:
- `L3044:15` / `L3045:19` / `L3045:37` / `L3047:20` / `L3047:37` / `L3047:46` / `L3049:14` — the
  `.task { while !Task.isCancelled { try? await Task.sleep(SessionChip.refreshIntervalNanoseconds);
  if Task.isCancelled { break }; model.refreshSessionActivity() } }` self-throttling refresh loop.
  ViewInspector's `callTask()` would ENTER this infinite sleep loop and never return (it runs until the
  view disappears — there is no in-process exit seam), so the loop body + its continuation `}` are
  toolchain-untestable in-process. (`.task` toolchain-untestable carve, per the batch recipe.)

### WorkspaceRowContextMenu (3→0) — `WorkspaceRowContextMenuInteractionTests`
DRIVEN: Pin/Unpin Workspace → `toggleWorkspacePin` flips `workspaces[0].isPinned`; Rename Workspace…
→ `beginRename(.workspace)` (isEditing true, draft prefilled); Remove Custom Workspace Name (the
`nameOverride != nil` arm) → `removeCustomWorkspaceName` clears the override. MUTATION-VERIFY:
`model.toggleWorkspacePin(row.id)` → `_ = (model, row)` → `testNegativeControl_pinActionTogglesWorkspacePin` RED → reverted → GREEN.

### WorkspaceTabStrip (3→0) — `WorkspaceTabStripInteractionTests`
DRIVEN: the tab `Button` action → `select(tab)` (`L3324` helper + `L3407` action) → `selectedEntryID`;
the FP4 filter-empty-state "Clear" Button (`L3385`) → `sidebarFilter = ""`. MUTATION-VERIFY:
`select(_:)` body `model.selectedEntryID = tab.id` → `_ = tab` → `testNegativeControl_tabSelectSetsSelection` RED → reverted → GREEN.

### WorkspaceTabContextMenu (3→0) — `WorkspaceTabContextMenuInteractionTests`
DRIVEN STANDALONE (the menu is the unit; `.contextMenu` non-descent): renders the "Rename Tab…" Label
+ taps it → `beginRename(.tab)` (isEditing(.tab) true, draft = effectiveTabName). MUTATION-VERIFY:
`model.beginRename(.tab(tab.id), …)` → `_ = (model, tab)` → `testNegativeControl_renameActionBeginsRename` RED → reverted → GREEN.

### SidebarFilterField (2→0) — `SidebarFilterFieldInteractionTests`
DRIVEN: the clear Button (`L2965`) → `sidebarFilter = ""`; the suggestion-chip Button (`L2997`) →
`sidebarFilter = chip.token` ("status:waiting"/"owner:agent"). MUTATION-VERIFY: `model.sidebarFilter = ""`
removed → `testNegativeControl_clearActionEmptiesFilter` RED → reverted → GREEN.

### InlineRenameEditor (2→0) — `InlineRenameEditorInteractionTests`
DRIVEN via `callOnSubmit()` / `callOnExitCommand()`: `.onSubmit { commitRename() }` (`L3278`) → a valid
draft writes the override; `.onExitCommand { cancelRename() }` (`L3279`) → closes the editor without
writing. MUTATION-VERIFY: both closures' bodies → `_ = model` → `testNegativeControl_onSubmitCommits`
+ `testNegativeControl_onExitCommandCancels` RED → reverted → GREEN.

### WorkspaceSidebarRow (1→0) — `WorkspaceSidebarRowInteractionTests`
DRIVEN: the `rowButton` Button action (`L3185`) → `selectedWorkspaceID = row.id`. MUTATION-VERIFY:
that assignment → `_ = (model, row)` → `testNegativeControl_rowTapSetsSelection` RED → reverted → GREEN.

### SidebarAgentRow (1→0) — `SidebarAgentRowInteractionTests`
DRIVEN: the `isSelected ? Color.accentColor… : .clear` selection-background ternary's TRUE arm
(`L3539:40`) rendered with `isSelected: true`; the `Button(action: select)` tap fires the select closure.
The select closure is mutation-proven via a captured flag (a Button with no action would not fire it).

### TerminalAgentRow (1→0) — `TerminalAgentRowGitLabelInteractionTests`
DRIVEN: the `accessibilityLabel`'s `gitStatus.dirty ? ", uncommitted changes" : ""` TRUE arm (`L3839:60`),
rendered with a dirty `GitSessionStatus` parsed from real porcelain → the a11y read contains
"uncommitted changes". MUTATION-VERIFY: the dirty ternary flattened to `? "" : ""` → the dirty assertions RED → reverted → GREEN.

### ElapsedTimePill (1→0) — `ElapsedTimePillDefaultArgTests`
DRIVEN: the `var now: Date? = nil` default-argument region (`L3893:22`), exercised by constructing
`ElapsedTimePill(startDate:)` WITHOUT `now:` (every prior call site passed `now:` explicitly). Asserted
via `XCTAssertNil(pill.now)` (the default's effect) + the pill still renders. MUTATION-VERIFY: the default
`= nil` → `= Date()` → `testDefaultArg_nowIsNil` RED → reverted → GREEN.

### GitBranchChip (1→1, pure carve) — no new test
CARVE (1) — recorded for Unit 3:
- `L3875:55` — the `status.branchLabel ?? "unknown"` fallback in `helpText`. `helpText` is called from
  EXACTLY ONE site, `.help(helpText)` at `L3869`, which is INSIDE `if let label = status.branchLabel`.
  When `helpText` runs, `status.branchLabel` is therefore provably non-nil (the enclosing `if let`
  already unwrapped it; `branchLabel` is a deterministic side-effect-free computed property), so the
  `?? "unknown"` arm is unreachable through any seam. (AN-006-style proven-dead branch.) The chip's
  other arms (branch label, dirty dot, ahead/behind, not-a-repo empty body, and the rest of `helpText`)
  are all driven by the existing `GitBranchChipLeafTests`.

## Carve summary (8 regions → Unit-3 allowlist candidates)

| kind | regions | views |
|---|---|---|
| `.task` self-refresh infinite loop (toolchain-untestable, `callTask` never returns) | 7 | WorkbenchSidebarView |
| proven-dead `?? "unknown"` fallback (branchLabel non-nil inside its enclosing `if let`) | 1 | GitBranchChip |

All 8 are genuinely-unreachable through any real seam (verified via the line:col + the enclosing-guard
analysis above); NONE is an un-driven ordinary arm. Lowering either carve count by driving it is
impossible without a fake (the loop hangs; the fallback is dead) — they are the measured minimum for B1.

## New test files (one commit per view)

- `TerminalRowContextMenuInteractionTests.swift`
- `WorkbenchSidebarViewInteractionTests.swift`
- `WorkspaceRowContextMenuInteractionTests.swift`
- `WorkspaceTabStripInteractionTests.swift`
- `WorkspaceTabContextMenuInteractionTests.swift`
- `SidebarFilterFieldInteractionTests.swift`
- `InlineRenameEditorInteractionTests.swift`
- `WorkspaceSidebarRowInteractionTests.swift`
- `SidebarAgentRowInteractionTests.swift`
- `TerminalAgentRowGitLabelInteractionTests.swift`
- `ElapsedTimePillDefaultArgTests.swift`
- (GitBranchChip: pure carve — no new test)
