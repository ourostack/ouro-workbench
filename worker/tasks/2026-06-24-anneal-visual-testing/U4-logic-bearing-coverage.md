# Doing: U4 — Logic-bearing view snapshot coverage (the long tail)

**Status**: drafting → READY_FOR_EXECUTION (autonomous; operator intermittently present → a fresh unbiased sub-agent review gate substitutes for human signoff)
**Execution Mode**: spawn (one work-doer sub-agent per PR-cluster; strict TDD; one commit per sub-unit; serialized merges; a PR per cluster — see "PR cadence"). NEVER two build-lock holders in one checkout (anneal §4: worktree-isolate / static-only / stagger).
**Created**: 2026-06-25 13:0x
**Planning**: this doc IS the planning doc, converted in place (the campaign convention — see U1/U2/U3). Goal/Scope/Decisions are the authoritative context; the cluster decomposition + execution sections are appended.
**Campaign / Journal**: ../2026-06-24-anneal-visual-testing.md  (the authoritative anneal journal — this is its U4 plan)
**Artifacts**: ./U4-logic-bearing-coverage/  (the 127-view classification, per-cluster coverage snapshots, the allowlist-candidate dossiers, spike records, review records, gate logs)
**Branch**: feat/anneal-coverage-logic-bearing-plan (off origin/main @ `7a65601` = `#298`; `git fetch && git checkout -b … origin/main` — origin/main churns from external PRs). This branch carries the PLAN + journal entry only; the EXECUTION clusters land as their own PRs/branches off the latest main.
**Harness (LIVE on main, the proven pattern)**: `Tests/OuroWorkbenchAppViewsTests/{AssertViewSnapshot,ViewSnapshotHost,ViewTreeSerializer,ViewSnapshotNode,ViewSnapshotStore}.swift` + the U1–U3 surface tests. The harness already pins Locale (`en_US_POSIX`), forces TimeZone=UTC, drops `.help` tooltips (AN-004), de-dups `TextField` placeholders + reads bound values (AN-002), and the fixtures inject a temp `agentBundlesURL` into BOTH `BossWorkbenchMCPRegistrar` AND `OuroAgentInventory` (AN-001). **U4 adds only fixtures + tests + (where unavoidable) `private`→`internal` access-widenings; no new harness mechanism is expected** (spikes named below gate the few risk surfaces).

## Execution Mode

- **spawn** — each PR-cluster is driven by its own work-doer pass (strict TDD: write the failing state-set test → red → provenance fixture + (if needed) access-widening → green → coverage check → refactor), one commit per sub-unit, serialized merges. Each cluster is its OWN PR (the brief: "each PR a coherent reviewable batch of related views"). The fresh review gate (P5, ≥2 independent reviewers) runs per cluster before merge.
- Why not `direct`: 66 views across ~12 clusters demands isolated, individually-reviewable, revertible PRs — anneal demands "every fix is its own PR, independently revertible."

## Objective (from planning Goal)

Snapshot the **66 logic-bearing uncovered views (~215 enumerated states)** in `OuroWorkbenchAppViews` via the LIVE ViewInspector harness — each fixture provenance-built through the REAL model seam, each surface with a ≥1 **mutation-verified** negative control, every committed reference deterministic (P3) and minimal/agent-legible (P4b/P4e) — grouped into PR-scoped clusters by area/file-locality, sequenced high-value/high-fan-out first, with the audit's provenance/determinism edge-cases (AN-001 / path-leak / clock / context-menu-popover / non-injectable) handled. This drives the views-lib coverage from **16.02% region / 13.02% line** (post-U3) toward the eventual coverage-gate — **WITHOUT gating the views lib in U4** (the gate is the FINAL campaign step, after the branchless-29 + untestable allowlist decision lands with the operator).

**DO NOT include time estimates (hours/days).**

## The 127-view classification (the audit, reconciled @ HEAD `7a65601`)

The full struct enumeration + per-struct LOGIC-BEARING/BRANCHLESS classification lives in `./U4-logic-bearing-coverage/view-classification.md` (built from two parallel structural reads of every uncovered `body`). Headline (the campaign's audit numbers):

| Bucket | Count | This plan? |
|---|---|---|
| **Covered** (U0–U3: surfaces A/B/C/D/E/F + the SU3r leaf) | **30** | — done |
| **Logic-bearing uncovered (~215 states)** | **66** | **YES — U4 scope** |
| Branchless-presentational (single static node tree) | **29** | DEFERRED — separate allowlist decision (operator) |
| Genuinely-untestable (shell / live-PTY only) | **2–3** | DEFERRED — honest-allowlist (operator); dossiers below |

**Reconciliation note (recorded, not hand-waved):** a raw structural sweep flags ~74 uncovered structs as "has a conditional," but the audit's *logic-bearing* test is stricter — "needs a MULTI-STATE snapshot set because a data-driven branch changes the **serialized node tree**." ~5 structs whose only conditional is an **attribute-only** ternary (`.opacity`/`.foregroundStyle`/`.font` on an otherwise-invariant tree — `OnboardingProgressDots`, `ProviderModelPill`, `DetailPaneChrome`, `TerminalSearchToggleButton`-shaped) produce a near-invariant serialized tree → the audit bins them with the branchless-29 (the harness whitelist drops geometry/color/font — P4b). The 2 full shells (`WorkbenchRootView`, `MachineRuntimeView`) move to the allowlist-candidate list. 74 − 5 (attribute-only → branchless) − ~3 (the untestable/shell carve-outs net) = **66 logic-bearing**, the campaign headline. Each cluster's unit RE-CONFIRMS its members against `view-classification.md` at execution time; an attribute-only view that turns out to flip a real node still gets snapshotted (coverage-% wins).

## Scope

### In Scope

- The **66 logic-bearing uncovered views (~215 states)**, decomposed into the PR-clusters in "Cluster / PR decomposition" below.
- Per view: its COMPLETE enumerated state-set (P4c), each fixture **provenance-built via the real seam** (P2 — `WorkbenchStore.save`→VM, `AgentProposalQueue.enqueue`, the pure Core producers, or direct `@Published` injection where that IS the real seam), snapshotted via the LIVE `assertViewSnapshot`.
- A ≥1 **mutation-verified** negative control PER SURFACE (P2 / upgraded skill: break a REAL guard → the snapshot/state test goes RED; restore byte-identically → green). NOT a fixture tweak.
- The provenance/determinism edge-cases (CRITICAL — the C1/AN-006 class), handled per "Edge-case fixture playbook" below: `SessionChip`/`GitBranchChip` real-target fixtures; AN-001 temp `agentBundlesURL` + fixed `OuroAgentRecord`; path-leak fixed/relative paths; fixed-timestamp/injected-clock fixtures; standalone context-menu/popover snapshots.
- A per-surface a11y-identifier audit (selective policy D-U2-2): add `.accessibilityIdentifier` ONLY where two serialized nodes would otherwise be byte-identical AND defeat a negative control; else "none needed."
- Where a target is `private` (`@testable import` can't reach it), a **`private`→`internal` access-widening** (access-only, zero-behavior — the SU-E precedent), surfaced to the operator per cluster (NOT strictly test-only). The list of `private` targets is in `view-classification.md`.
- Record the running views-lib coverage % as each cluster lands (artifact, input to the final gate step).
- One commit per sub-unit; a PR per cluster; NO AI attribution; `SerpentGuide.ouro/` never staged.
- A fresh, unbiased sub-agent review gate (no inherited context) before READY, and again per-cluster pre-merge (P5).

### Out of Scope

- **Coverage-gating the views lib** (`COVERAGE_DIRS`/allowlist UNCHANGED through ALL of U4 — the gate is the campaign's FINAL step, after the branchless-29 + untestable allowlist decision lands with the operator). Running coverage % is recorded per cluster as PROGRESS, never as a gate.
- The **29 branchless-presentational** views and the **2–3 genuinely-untestable** views — a SEPARATE later allowlist decision pending the operator. They are LISTED here (deferred + the allowlist-candidate dossiers) but NOT planned/snapshotted in U4.
- Retiring grep-guards (P7 — tracks to the final gate step as coverage lands; ~269 sites stay green through U4).
- Fixing the AN-001 SOURCE defect (still open; mitigated in-fixture in every VM fixture).
- ViewInspector dep changes (U5, deferred; the dep is on main, exact-pinned `0.10.3`, test-target only).
- Any product BEHAVIOR change. The only Sources touches U4 allows are: (a) selective `.accessibilityIdentifier` IF an a11y audit proves one is needed (expected: rare); (b) `private`→`internal` access-widenings (zero-behavior). Both are surfaced to the operator. The clock seam (`TimelineView` `now:`) is ALREADY done in U2; the logic-bearing clock views (`DecisionInboxSheet`, `ElapsedTimePill`) already carry the injectable `now:` — **no new clock source-touch is expected** (re-verified per the clock-cluster unit).

## Cluster / PR decomposition (high-value/high-fan-out FIRST)

**~12 PR-clusters, grouped by area/file-locality.** The 5 high-fan-out sheets the brief named are each their own PR (C2/C7/C8/C9 + the Boss-dashboard C5). Sequence is high-value-first; clusters with NO cross-dependency fan out (serialized merges). Each cluster names: its views, the seam, the edge-cases it carries, and any access-widening. Member lists RE-CONFIRM against `view-classification.md` at execution.

> **Dependency note:** the only hard ordering is **C0 (the edge-case spikes) FIRST** — it de-risks the AN-001/path-leak/clock/standalone-menu/`ContentUnavailableView`/live-arm patterns ONE time, on the cheapest representative of each, so every later cluster reuses a proven recipe instead of re-discovering it. Everything after C0 is independent (file-locality clusters don't share fixtures); they fan out, serialized merges.

### C0 — Edge-case spike pack (de-risk every flagged pattern ONCE) — FIRST
**Views (representative, 1 each):** `GitBranchChip` (real-target fixture), `OuroAgentManagerView` (AN-001 + fixed `OuroAgentRecord`), `AgentInspectorPanel` (path-leak), `BossWatchStatusView` (fixed-timestamp clock), `TerminalRowContextMenu` (standalone menu), `SessionDetailView` inactive arm (live-arm carve-out).
**Why first / value:** proves the 6 edge-case recipes are sound before fanning out 66 views; turns each later cluster into "apply the recipe." Each representative is also a real logic-bearing target → counts toward the 66 (not throwaway).
**Output:** a proven fixture recipe per edge-case (committed as the first member of each pattern's home cluster) + `./U4-logic-bearing-coverage/edge-case-spikes.md`.
**Access-widening:** `AgentInspectorPanel` (private→internal).

### C1 — Sidebar tail (chips, rows, filter, context-menus) — HIGH VALUE (closes the C1-family gap)
**Views (8):** `GitBranchChip`, `SessionChip`, `SidebarFilterField`, `SidebarAgentRow`, `WorkspaceRowContextMenu`, `TerminalRowContextMenu`, `WorkspaceTabContextMenu`*, `SidebarCountBadge`*.
**Why high value:** `SessionChip`/`GitBranchChip` are the audit's "look-covered-but-AREN'T" real targets (no live fixture drives `activity != nil` / `gitStatus.isRepo`); closing them removes a false-coverage illusion. The context-menus are the standalone-snapshot pattern.
**Seam:** build `SessionActivity`/`GitSessionStatus` fixtures (the chip drivers) + `ProcessEntry` via `WorkbenchStore.save`→VM for the rows; context-menus instantiated STANDALONE.
**Edge-cases:** real-target chip fixtures (C0); standalone menu snapshots (C0).
*Two starred views are BRANCHLESS — re-confirm at execution; if truly branchless they DROP to the deferred-29 (not forced).*

### C2 — `BossDashboardView` + dashboard strip (high-fan-out sheet #1) — HIGH VALUE, OWN PR
**Views (~9):** `BossDashboardView`, `InboxDoorPill`*, `BossNeedsMeCodingColumns`, `DashboardMetricsStrip`*, `MetricStateChip`, `MetricChip`, `WorkbenchVisibilityStrip`*, `MailboxWarningView`*, `HabitHistoryPanelView`.
**Seam:** `model.bossDashboard` / `model.inboxDoor` / `model.bossWatch*` `@Published` derived from the pure dashboard producers; provenance-build the dashboard model via the real seam (trace the producer in the spike).
**Edge-cases:** none new (no path/clock in the rendered tree — re-confirm; `HabitHistoryPanelView` rows may carry dates → fixed-timestamp if so).

### C3 — Header / boss-selector / autonomy popovers — HIGH VALUE
**Views (~8):** `HeaderView`, `BossWatchHeaderToggle`, `BossSelectorView`, `BossAgentNamePopover`, `AutonomyStatusButton`, `AutonomyStatusPopover`, `AutonomyStatusCheckRow`, `BossConversationView`.
**Seam:** `model.bossAgentChoices` / autonomy presentation `@Published`; popovers instantiated STANDALONE (the `.popover{}` content is not descended).
**Edge-cases:** standalone popover snapshots (C0); AN-001 (boss-choice names ← inventory → temp `agentBundlesURL` + fixed records).
**Access-widening:** none expected (these are `internal`).

### C4 — Decision log / inbox + command palette — HIGH VALUE (high-fan-out: `DecisionLogRow`)
**Views (~5):** `DecisionLogSheet`, `DecisionInboxSheet`, **`DecisionLogRow`** (the brief's 5th named high-fan-out target — its OWN sub-unit/commit within this PR; it has the deepest state-set of the five: `@State taught` · `if let friend` · `if let proposed` · `if let pref` · `mode == .inbox` · `if let confidence`), `CommandPaletteSheet`, `ShortcutHelpSheet`.
**Seam:** `model.state.decisionLog` via `WorkbenchStore.save`→VM; `DecisionInboxSheet` already carries the injectable `now:` (U2) → fixed clock.
**Edge-cases:** clock (`DecisionInboxSheet` `now:` injected — already wired); `DecisionLogRow` `@State private var taught` (snapshot the initial state). `DecisionLogRow`'s enumerated state-set is large enough that C4 SPLITS to a C4a (DecisionLogRow solo) + C4b (log/inbox/palette/shortcut) pair if it exceeds a single reviewable batch (Q4 default).
**Access-widening:** `DecisionLogRow` (private→internal).

### C5 — `ReportBugSheet` (high-fan-out sheet #2) — OWN PR
**Views (1, deep state-set):** `ReportBugSheet`.
**Seam:** `model.bugReportNote` / `model.bugReportError` / `model.bugReportIssueURL` `@Published`; states {empty-note / typed-note / error / success-with-issue-URL / collecting}.
**Edge-cases:** the issue-URL/error are model strings → fix them in the fixture (no machine path).

### C6 — `ProviderConfigSheet` + agent install/onboarding-sheet forms (high-fan-out sheet #3) — OWN PR(s)
**Views (~5):** `ProviderConfigSheet`, `OuroAgentInstallSheet`, `WorkbenchOnboardingSheet`*, `OnboardingPageContent`, `OnboardingFlowHeader`.
**Seam:** `model.providerConfig*` `@Published` + the onboarding page router.
**Edge-cases (NEW — recorded):** `ProviderConfigSheet` has `@State private var humanName = NSFullUserName()` and `@State private var provider`/`values` — the `@State` DEFAULT initializer reads the **machine user name** (a P3 leak). Fixture must drive the rendered value through the model/binding, or assert the leak-free subtree; if the `@State` default is unavoidable in the snapshot, this view's *initial-@State* arm becomes a recorded determinism constraint (pin via a binding seam or carve the `humanName` row). **Spike in C0-adjacent** (this is the one genuinely-new determinism landmine the audit's edge-case list didn't enumerate — see Open Questions Q3).
*`WorkbenchOnboardingSheet` is the router shell (`switch page`); re-confirm it isn't a shell-allowlist candidate at execution.*

### C7 — Agent-detail family (path-leak cluster) — OWN PR
**Views (~7):** `AgentDetailView`, `AgentTitleStrip`, `AgentInspectorPanel`, `AgentStatusCard`, `LanePanel`, `BossWorkbenchMCPSetupView`, `OuroAgentRowView`.
**Seam:** fixed `OuroAgentRecord` (AN-001 + relative/fixed `bundlePath`/`configPath` — the path-leak fix) + `model.workbenchMCPRegistration(for:)` fixtures.
**Edge-cases:** **path-leak (hard)** — `AgentInspectorPanel`/`AgentStatusCard`/`OuroAgentRowView` render `bundlePath`/`configPath` as visible `Text` → fixtures MUST use fixed/relative paths (C0 recipe); AN-001.
**Access-widening:** `AgentInspectorPanel`, `AgentStatusCard`, `AgentTitleStrip`, `LanePanel` (private→internal).

### C8 — Agent manager / inventory — OWN PR (AN-001 cluster)
**Views (~4):** `OuroAgentManagerView`, `AgentHomeEmptyState`, `OnboardingAgentProviderSummary`*, `MarkdownMessageView`.
**Seam:** direct `model.ouroAgents = [fixed OuroAgentRecord]` (the SU-E3 seam) + AN-001 temp `agentBundlesURL`.
**Edge-cases:** AN-001 (empty/one/many ouroAgents); `MarkdownMessageView` `ForEach(blocks)` over a fixed markdown string.
**Access-widening:** `OnboardingAgentProviderSummary` (private→internal).

### C9 — Session-detail family (live-terminal-arm carve-out) — OWN PR
**Views (~12):** `SessionDetailView` (INACTIVE arm), `DetailSplitContainer` (INACTIVE arms), `SessionAttentionBanner`, `SessionTitleStrip`, `SessionInspectorPanel`, `SessionStatusBar`, `CustomSessionManagementBar`, `InactiveTerminalSurface`, `TranscriptHistoryView`, `EmptyPanePicker`, `TerminalSearchBar`, `DetailPaneChrome`*.
**Seam:** `WorkbenchStore.save`→VM with NO `activeSession` (so `model.activeSession(for:) == nil` → the INACTIVE branch renders; the LIVE `TerminalPane` arm is never constructed → allowlist that arm, snapshot the SwiftUI states).
**Edge-cases:** **live-terminal-arm carve-out (C0)** — assert the inactive/inspector/empty/banner states; the `if let session` LIVE arm (embeds `TerminalPane`) is an honest-allowlist candidate (dossier below). `SessionInspectorPanel` may render a transcript path → fixed/relative.
**Access-widening:** `SessionAttentionBanner`, `SessionTitleStrip`, `SessionInspectorPanel` (private→internal).

### C10 — Session-status list + transcript/action logs — OWN PR
**Views (~8):** `SessionStatusListView`, `SessionStatusBucketSection`, `SessionStatusRowView`, `ActionLogView`, `BossActionReceiptStrip`, `TranscriptSearchView`, `OnboardingBossReconstructView`, `RecoveryDrillView`.
**Seam:** `model.sessionStatus*` / `model.actionLog` / `model.transcriptSearchResults` `@Published`.
**Edge-cases:** `BossActionReceiptStrip`/`ActionLogView` rows may carry timestamps → fixed-timestamp fixtures; `RecoveryDrillView` is the drill harness (real producer).
**Access-widening:** `SessionStatusBucketSection`, `SessionStatusRowView`, `OnboardingBossReconstructView` (private→internal).

### C11 — Harness-status + settings + import-summary sheets — OWN PR
**Views (~7):** `HarnessStatusSheet`, `HarnessAgentRow`, `HarnessActionRow`, `HarnessActionResultBanner`, `SettingsSheet`, `ImportSummaryBanner`, `NewTerminalSessionSheet`.
**Seam:** `model.harnessStatus*` / `model.importSummary` `@Published`; `HarnessStatusSheet` `if let observedAt` → fixed-timestamp.
**Edge-cases:** clock (`HarnessStatusSheet` `observedAt` → fixed); import-summary entry-id is a UUID → fixed.
**Access-widening:** `HarnessAgentRow`, `HarnessActionRow`, `HarnessActionResultBanner`, `SettingsSection` (private→internal).

> **Cluster count: C0–C11 = 12 PR-batches** (C0 first; C1–C11 fan out, serialized merges). The 5 high-fan-out sheets get their own PR: `BossDashboardView` (C2), `ReportBugSheet` (C5), `ProviderConfigSheet` (C6), `HarnessStatusSheet` (C11), and the agent-detail/manager split across C7/C8. **Realistic PR count: 12–16** — C6 and C9 are large enough to split (the form-sheet trio C6; the 12-view session family C9) if a cluster exceeds a single reviewable batch; the doer splits at execution and records it.

## Edge-case fixture playbook (the CRITICAL C1/AN-006-class risks — how each is pinned)

1. **`SessionChip` / `GitBranchChip` real targets.** They LOOK covered (built inside `TerminalAgentRow`) but AREN'T: no live fixture drives `activity != nil` / `isStalled` (`SessionChip` gate `if !entry.isArchived, activity != nil || isStalled`) or `gitStatus.isRepo` (`GitBranchChip` gate `if let label = status.branchLabel`). **Fix:** build `SessionActivity` (todo/active-form) + `GitSessionStatus(isRepo:true, branchLabel:, dirty:, ahead:, behind:)` fixtures and snapshot the chips — preferably STANDALONE (the cleanest seam) AND, where the real `TerminalAgentRow(activity:gitStatus:)` path accepts them, on the row. (C1; AN-003 is the OBSERVATION that the live SIDEBAR never wires these — so standalone/row-leaf is the legitimate seam, exactly the SU3r pattern.)
2. **AN-001 seam** (`OuroAgentManagerView`, `OuroAgentRowView`, `BossWorkbenchMCPSetupView`, `AgentStatusCard`, `AgentInspectorPanel`, boss-choice/autonomy name reads): inject a temp `agentBundlesURL` into BOTH `BossWorkbenchMCPRegistrar` AND `OuroAgentInventory` (so `scan()` of the non-existent temp dir → `[]`), and drive `model.ouroAgents = [fixed OuroAgentRecord]` directly (the SU-E3-proven seam). FIXED `OuroAgentRecord` → no machine-local agent name leaks. (E3 mitigation, extended.)
3. **Path-leak (hard).** `AgentInspectorPanel` (`:8170`) renders `agent.bundlePath` + `agent.configPath` as visible `Text(...).textSelection`; `AgentStatusCard`/`OuroAgentRowView` similar. → fixtures MUST construct the `OuroAgentRecord` with FIXED, relative paths (e.g. `bundlePath: "AgentBundles/fixture-agent"`, `configPath: "AgentBundles/fixture-agent/config.json"`) so no `/Users/…` reaches the tree. The host whitelist can't strip a *content* `Text` (unlike `.help`), so the FIXTURE is the only fix (P3). A determinism assertion (`!tree.contains("/Users/")`) defends it.
4. **Clock.** `BossWatchStatusView` renders `change.occurredAt.formatted(date:.omitted, time:.standard)` (baked at construction); `DecisionInboxSheet`/`ElapsedTimePill` use the injectable `now:` (U2 — already wired); `HarnessStatusSheet` `if let observedAt`; `BossActionReceiptStrip`/`ActionLogView`/`HabitHistoryPanelView` may carry timestamps. → fixtures use a CANONICAL FIXED `Date` (a single epoch constant) so every formatted string is byte-identical; the host's UTC-TZ pin makes the *read-time* `Text(date, style:)` cases deterministic too. NO new clock source-touch (the only two `TimelineView` sites already carry `now:`).
5. **`.contextMenu{}` / `.popover{}` content is NOT descended** by ViewInspector's synchronous `findAll`. The named menu/popover views (`TerminalRowContextMenu`, `WorkspaceRowContextMenu`, `WorkspaceTabContextMenu`, `AutonomyStatusPopover`, `BossAgentNamePopover`) are ALREADY standalone `View` structs → snapshot them STANDALONE (`TerminalRowContextMenu(entry:model:)` directly), never by descending a parent's `.contextMenu{}`. (Confirmed first-hand: all five are top-level structs.)
6. **Non-injectable / shell (→ allowlist-candidate list, do NOT force-snapshot)** — see the dossiers below. The live-terminal ARMS of `SessionDetailView`/`DetailSplitContainer` are carved (snapshot the inactive/empty/inspector states; allowlist the `if let session` arm).

## Honest-allowlist candidate list (for the operator's eventual allowlist decision — NOT planned/snapshotted in U4)

Each carries a VERIFIED justification (P1 allowlist requires the untestability claim itself be checked, not asserted). Dossiers land in `./U4-logic-bearing-coverage/allowlist-candidates.md` as each cluster confirms the carve-out.

| View | Why untestable in-process | Justification (verified) | Disposition |
|---|---|---|---|
| `WorkbenchRootView` (`:131`) | `@StateObject WorkbenchViewModel` + `NavigationSplitView(columnVisibility:)` + `@Environment(\.scenePhase)` + menu-command dispatch + dockTile/window shell. | The root window/scene shell; no data-state seam — its body is the split + menu wiring. C0 SPIKES whether the harness can host it at all; if the synchronous `inspect()` can't traverse a `NavigationSplitView` root deterministically → allowlist. | **Allowlist-candidate** (spike-gated). |
| `MachineRuntimeView` (`:10170`) | `@StateObject private var loginItem = LoginItemController()` — no injection seam; its `isEnabled`/`isUpdating`/`lastError` rows are driven by the live login-item service. | The login-item rows are non-injectable (the `@StateObject` is constructed in-place, no `paths`/init seam). Only the `model.supportDiagnostics*` rows are model-driven — but they live in the SAME `body` as the login-item `@StateObject`, which taints the whole view's determinism. | **Allowlist-candidate** (login-item arm); a future seam (`LoginItemController` protocol-injection) would reclaim it — recorded as a possible source-fix, NOT done in U4. |
| `SessionDetailView` LIVE arm (`if let session`, `:8499`) | `TerminalPane(session:)` embeds the live PTY (`@main`-allowlisted; lives outside coverage). | The `if let session = model.activeSession(for:)` arm constructs `TerminalPane` (a live-terminal view). U4 snapshots the `else` (INACTIVE) arm + inspector/banner/empty states through the real seam (no `activeSession`); the LIVE arm is allowlisted. | **Partial — snapshot inactive states; allowlist the live arm.** |
| `DetailSplitContainer` LIVE arms (`:8612`) | Each pane is a `SessionDetailView` whose live arm embeds `TerminalPane`. | Same as above — snapshot the split chrome + `EmptyPanePicker` (the inactive/empty arms) via the real seam; allowlist the live-pane arm. | **Partial — snapshot inactive/empty; allowlist live arm.** |

## Deferred — the 29 branchless-presentational views (a SEPARATE later allowlist decision, NOT U4)

Single-static-node-tree views (no data-driven branch changes the serialized tree; the harness whitelist drops the geometry/color/font that varies). Listed for completeness; the operator decides snapshot-anyway-for-coverage vs allowlist when the final gate step lands. Full list in `view-classification.md`. Representatives: `HarnessSection`, `HarnessDetailRow`, `SettingsSection`, `AboutSheet`, `WorkspaceTabContextMenu`, `SidebarActionRow`, `SidebarCountBadge`, `StatusDot`, `DashboardStatusLine`, `InboxDoorPill`, `DashboardMetricsStrip`, `WorkbenchVisibilityStrip`, `MailboxWarningView`, `AgentLanesCard`, `AgentActionsCard`, `TerminalSearchToggleButton`, `SessionNotesView`, `TranscriptRehydrationPreview`, `TerminalFocusView`, `NewTerminalGroupSheet`, `EditTerminalGroupSheet`, `EditTerminalSessionSheet`, `SessionNotesEditor`, `ReleaseUpdateView`, `WorkbenchReleaseUpdateControls`, `OnboardingProgressDots`, `ProviderModelPill`, `DetailPaneChrome`, `TranscriptHistoryView` *(some attribute-only-variant; re-confirmed per cluster — a few may flip to logic-bearing and join a cluster)*.

## Completion Criteria

- [ ] All 66 logic-bearing views have their COMPLETE enumerated state-set committed as non-redundant references (P4c/P4e).
- [ ] Every fixture provenance-built via the real seam (P2); NEVER hand-assembled serializer output / model state.
- [ ] ≥1 MUTATION-VERIFIED negative control per SURFACE (break a real guard → RED; restore → green).
- [ ] Determinism (P3): fixed clock/locale/UTC-TZ; zero machine paths; twice-run byte-identical; no `/Users/…`, `Date()`, `.now`, `UUID()`, or `NSFullUserName()` in any committed reference. AN-001 temp `agentBundlesURL` injected in EVERY VM fixture; path-leak views use fixed/relative paths.
- [ ] Each enumerated state that CANNOT be provenance-built via a real seam is moved to a standalone leaf OR recorded as an unreachable observation — NEVER fabricated (the C1/AN-006 discipline).
- [ ] The 4 honest-allowlist candidates carry a VERIFIED justification dossier; the live-arm carve-outs snapshot the inactive states.
- [ ] a11y-identifier decision recorded per surface; access-widenings (`private`→`internal`) listed + surfaced to the operator.
- [ ] Running views-lib coverage % recorded per cluster (artifact, input to the final gate step).
- [ ] 100% test coverage on all NEW code (any harness-side helpers). The views lib is NOT gated in U4.
- [ ] Gates per cluster: strict build/test `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` 0 warn/0 fail (our products); `--uisurfacetest` green; `Scripts/check-coverage.sh` green with `COVERAGE_DIRS` + allowlist UNCHANGED; ~269 grep-guards green/unchanged; guards green.
- [ ] One commit per sub-unit; a PR per cluster; NO AI attribution; `SerpentGuide.ouro/` never staged.
- [ ] All tests pass; no warnings.
- [ ] Fresh unbiased sub-agent review gate run; zero surviving CRITICAL/HIGH (P5) before READY, and per-cluster pre-merge.

## Code Coverage Requirements
**MANDATORY: 100% coverage on all NEW code (the harness-side helpers / any new fixture-builder utilities).** The views-lib itself is NOT gated in U4 (the gate is the final campaign step). No `[ExcludeFromCodeCoverage]`-equivalent on new code; all branches/error-paths of any new helper covered; edge cases (null/empty/boundary) tested. Per-cluster the views-lib coverage % is RECORDED (progress), not gated.

## TDD Requirements
**Strict TDD — no exceptions.** Per surface: (1) write the failing enumerated state-set test (the `assertViewSnapshot` calls + provenance assertions) → (2) run, confirm RED (missing reference / failing provenance assertion) → (3) build the provenance fixture + (if needed) the `private`→`internal` widening → (4) run, confirm GREEN + the reference records → (5) add + MUTATION-VERIFY the negative control (break a real guard → RED → restore → green) → (6) coverage check + refactor, tests still green. No reference committed without its provenance assertion + the surface's negative control.

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

**Every unit header starts with a status emoji.**

### ⬜ Unit C0: Edge-case spike pack (de-risk every flagged pattern ONCE)
**What**: For each of the 6 edge-case recipes (real-target chip · AN-001 fixed-record · path-leak fixed-path · fixed-timestamp clock · standalone menu/popover · live-arm carve-out + the `WorkbenchRootView` host spike + the `ProviderConfigSheet` `@State NSFullUserName()` leak spike Q3), prove the fixture recipe on ONE cheap representative; widen `AgentInspectorPanel` private→internal; commit each proven representative into its home cluster.
**Output**: `./U4-logic-bearing-coverage/edge-case-spikes.md` (per-recipe GO/NO-GO + the proven fixture snippet); the `WorkbenchRootView`/`MachineRuntimeView` allowlist GO/NO-GO; the Q3 determinism resolution.
**Acceptance**: each recipe has a committed, deterministic, provenance-built, mutation-verified representative reference; every allowlist-candidate has a verified dossier; Q3 resolved (reversible default recorded). Gates green.

### ⬜ Unit C1: Sidebar tail (chips/rows/filter/context-menus)
**What**: snapshot the 8 C1 views (the `SessionChip`/`GitBranchChip` real-target gap; the standalone context-menus; the filter/agent rows) at their enumerated state-sets via the C0-proven recipes.
**Output**: per-view references + `views-coverage-after-C1.txt`.
**Acceptance**: real-target chips render their content (not the false-covered illusion); ≥1 mutation-verified negative control; a11y-id audit recorded; gates green; one commit per sub-unit; a C1 PR.

### ⬜ Unit C2: `BossDashboardView` + dashboard strip (high-fan-out sheet #1, own PR)
**What**: snapshot `BossDashboardView` + the ~8 dashboard-strip views at the enumerated dashboard states (inbox-door present/absent · boss-watch error · check-in running · dashboard present/absent · availability issues · advanced expanded).
**Output**: references + `views-coverage-after-C2.txt`.
**Acceptance**: dashboard model provenance-built via the real producer seam; ≥1 mutation-verified negative control; gates green; own PR.

### ⬜ Unit C3: Header / boss-selector / autonomy popovers
**What**: snapshot the ~8 header/boss/autonomy views; popovers STANDALONE; AN-001 name pinning.
**Output**: references + `views-coverage-after-C3.txt`.
**Acceptance**: standalone popovers render; AN-001 hermetic; ≥1 mutation-verified negative control; gates green; own PR.

### ⬜ Unit C4: Decision log / inbox + command palette
**What**: snapshot the ~5 decision/palette views; `DecisionInboxSheet` with injected `now:`; `DecisionLogRow` initial `@State`.
**Output**: references + `views-coverage-after-C4.txt`.
**Acceptance**: clock deterministic (injected `now:`); `DecisionLogRow` widened private→internal; ≥1 mutation-verified negative control; gates green; own PR.

### ⬜ Unit C5: `ReportBugSheet` (high-fan-out sheet #2, own PR)
**What**: snapshot `ReportBugSheet` at {empty / typed / error / success-with-issue-URL / collecting}.
**Output**: references + `views-coverage-after-C5.txt`.
**Acceptance**: states provenance-built via `model.bugReport*` `@Published`; no machine path in the issue-URL/error; ≥1 mutation-verified negative control; gates green; own PR.

### ⬜ Unit C6: `ProviderConfigSheet` + install/onboarding-sheet forms (high-fan-out sheet #3, own PR(s))
**What**: snapshot the ~5 form/router views; resolve the `@State NSFullUserName()` leak per Q3.
**Output**: references + `views-coverage-after-C6.txt`; the Q3 determinism resolution applied.
**Acceptance**: NO `NSFullUserName()` / machine name in any reference (Q3 default applied); `WorkbenchOnboardingSheet` re-confirmed not a shell-allowlist; ≥1 mutation-verified negative control; gates green; own PR (split if oversized).

### ⬜ Unit C7: Agent-detail family (path-leak cluster, own PR)
**What**: snapshot the ~7 agent-detail views with fixed/relative paths (the path-leak fix) + AN-001.
**Output**: references + `views-coverage-after-C7.txt`.
**Acceptance**: NO `/Users/…` in any reference (path-leak defended by assertion); 4 private→internal widenings listed/surfaced; ≥1 mutation-verified negative control; gates green; own PR.

### ⬜ Unit C8: Agent manager / inventory (AN-001 cluster, own PR)
**What**: snapshot the ~4 manager/inventory/markdown views via direct `model.ouroAgents` injection + AN-001.
**Output**: references + `views-coverage-after-C8.txt`.
**Acceptance**: empty/one/many ouroAgents states; AN-001 hermetic; ≥1 mutation-verified negative control; gates green; own PR.

### ⬜ Unit C9: Session-detail family (live-terminal-arm carve-out, own PR)
**What**: snapshot the ~12 session-detail views at their INACTIVE/inspector/banner/empty states (live `TerminalPane` arm allowlisted); fixed/relative transcript paths.
**Output**: references + `views-coverage-after-C9.txt`; the live-arm allowlist dossier.
**Acceptance**: inactive arm renders via the real `activeSession == nil` seam; live arm allowlisted with a verified dossier; 3 private→internal widenings; ≥1 mutation-verified negative control; gates green; own PR (split if oversized).

### ⬜ Unit C10: Session-status list + transcript/action logs (own PR)
**What**: snapshot the ~8 status/log views; fixed-timestamp fixtures for timestamped rows.
**Output**: references + `views-coverage-after-C10.txt`.
**Acceptance**: timestamps deterministic (fixed `Date`); 3 private→internal widenings; ≥1 mutation-verified negative control; gates green; own PR.

### ⬜ Unit C11: Harness-status + settings + import-summary sheets (high-fan-out sheet #4 incl. `HarnessStatusSheet`, own PR)
**What**: snapshot the ~7 harness/settings/import views; fixed `observedAt` + fixed entry-id UUID.
**Output**: references + `views-coverage-after-C11.txt`; the FINAL views-lib coverage % (input to the campaign's final gate step).
**Acceptance**: clock/UUID deterministic; 4 private→internal widenings; ≥1 mutation-verified negative control; gates green; own PR. **Update the CAMPAIGN journal + backlog: append the U4-COMPLETE iteration entry** (final coverage %; the deferred branchless-29 + 4 allowlist-candidates handed to the operator; any new AN-00x).

## Execution
- **TDD strictly enforced** per surface (red → provenance fixture + widening → green → mutation-verify control → coverage/refactor).
- One commit per sub-unit; a PR per cluster; serialized merges onto the latest main (each cluster branches off the latest `origin/main`, which churns).
- Run the full strict suite + `--uisurfacetest` + `check-coverage.sh` (COVERAGE_DIRS/allowlist UNCHANGED) before marking a cluster done.
- **All artifacts**: per-cluster coverage snapshots, the classification, the allowlist dossiers, spike + gate + review logs → `./U4-logic-bearing-coverage/`.
- **Fixes/blockers**: spawn a sub-agent immediately (never two build-lock holders in one checkout — worktree-isolate / static-only / stagger).
- **Decisions made**: update this doc + the campaign journal immediately, commit right away (`docs(doing):`).
- **NEVER** gate the views lib or touch `COVERAGE_DIRS`/the allowlist in U4 — that is the campaign's FINAL step.

## Open Questions (forks — each resolved with a reversible default, recorded)
- [ ] **Q1 — `WorkbenchRootView` host viability (spike, C0).** Can the synchronous `inspect()` traverse a `NavigationSplitView`-rooted `@StateObject` view deterministically? **Reversible default: ALLOWLIST it** (it's the window/scene shell, no data-state seam) unless the C0 spike proves a clean hostable subtree. Recorded either way.
- [ ] **Q2 — branchless-29 snapshot-anyway vs allowlist (operator, FINAL step — NOT U4).** Default for U4: **DEFER** (out of scope); the final gate step asks the operator. A handful may re-classify to logic-bearing per cluster (snapshot them then).
- [ ] **Q3 — `ProviderConfigSheet` `@State private var humanName = NSFullUserName()` determinism (spike, C0).** The `@State` default reads the machine user name → a P3 leak if the *initial* state is snapshotted. **Reversible default: drive the rendered value through a binding/model seam (or carve the `humanName` row from the asserted subtree) and assert `!tree.contains(NSFullUserName())`**; if no binding seam exists, record the initial-`@State` arm as a determinism constraint and snapshot the model-driven (non-initial) states only. The genuinely-new landmine the audit's edge-case list didn't enumerate — surfaced.
- [ ] **Q4 — cluster split threshold.** C6 (form trio) and C9 (12-view session family) may exceed a single reviewable PR. **Reversible default: the doer SPLITS at execution** (C9a inactive-arm core / C9b inspector+status; C6a ProviderConfig / C6b install+onboarding-sheet) and records the split — PR count lands 12–16.
- [ ] **Q5 — `SessionChip`/`GitBranchChip` standalone vs on-row.** **Reversible default: STANDALONE** (the cleanest hermetic seam, the SU3r-leaf pattern), AND on the real `TerminalAgentRow(activity:gitStatus:)` path where it accepts the fixtures (defense-in-depth). Recorded.

## Decisions Made (reversible/auditable)
- **D-U4-1** — Cluster by AREA/file-locality, sequence high-value/high-fan-out first; the 5 named high-fan-out sheets each own a PR. (The brief.)
- **D-U4-2** — Reuse the LIVE U1–U3 harness UNCHANGED (AN-002 `input()` + AN-004 `.help`-drop + UTC-TZ + AN-001 hermetic inventory). No new harness mechanism expected; a harness change is allowed ONLY if a C0 spike proves a surface needs it (must be 100%-covered, test-only).
- **D-U4-3** — Do NOT gate the views lib / touch `COVERAGE_DIRS`/the allowlist in U4 (the final campaign step owns the gate, after the branchless-29 + allowlist decision lands with the operator).
- **D-U4-4** — `private`→`internal` access-widenings are zero-behavior (the SU-E precedent) but NOT strictly test-only → listed per cluster + surfaced to the operator.
- **D-U4-5** — The 4 non-injectable/shell/live-arm views are honest-allowlist CANDIDATES with verified dossiers (P1 allowlist discipline), handed to the operator at the final step — NEVER force-snapshotted.
- **D-U4-6** — Fully autonomous: a fresh unbiased sub-agent review gate (no inherited context) substitutes for human signoff before READY and per-cluster pre-merge.

## Context / References
- **Harness (LIVE on main)**: `Tests/OuroWorkbenchAppViewsTests/{AssertViewSnapshot,ViewSnapshotHost,ViewTreeSerializer,ViewSnapshotNode,ViewSnapshotStore}.swift`; the proven surface tests `{SidebarSurfaceStateSet,TabStripSurfaceStateSet,BossProposalCardStateSet,RecoverySurfaceStateSet,InlineRenameEditorStateSet,OnboardingBossChoiceView,OnboardingReadinessView,OnboardingRepairStepRow,FirstRunBootstrapView,TerminalAgentRowRunningLeaf}Tests.swift`.
- **Source**: `Sources/OuroWorkbenchAppViews/WorkbenchViewsAndModel.swift` (21,285 lines, 123 `View` structs). Key edge-case refs validated first-hand @ `7a65601`: `TerminalAgentRow`/`SessionChip`/`GitBranchChip` `:3640/:3898/:3770`; `AgentInspectorPanel` (path-leak) `:8170`; `MachineRuntimeView` (login-item `@StateObject`) `:10170`; `WorkbenchRootView` (shell) `:131`; `SessionDetailView` (live arm) `:8499`; `DetailSplitContainer` `:8612`; `BossWatchStatusView` (clock) `:7854`; `DecisionInboxSheet` (injected `now:`) `:2181`; `OuroAgentManagerView` (AN-001) `:5836`; `TerminalRowContextMenu`/`AutonomyStatusPopover`/`BossAgentNamePopover` (standalone) `:3538/:4594/:4405`; `ProviderConfigSheet` (`@State NSFullUserName()`) `:6071`.
- **Classification**: `./U4-logic-bearing-coverage/view-classification.md` (the 127-view audit, reconciled).
- **Baselines @ `7a65601`**: views-lib coverage **16.02% region / 13.02% line** (TOTAL 2678 regions / 5823 lines); **59 committed `__Snapshots__`**; **269 grep-guard sites**; **23 AppViews test files**.
- **Rubric**: `~/.claude/skills/anneal/SKILL.md` (P1 coverage / P2 mutation-non-vacuity / P3 determinism / P4 snapshot-quality / P5 ≥2-reviewer gate / P6 CI). Mutation-as-P2 is LIVE.
- **Audit prior surfaces + rubric P1/P2/P3**: `../2026-06-24-anneal-visual-testing.md` (the campaign journal; surfaces A/B/C/D/E/F + the SU3r leaf done; AN-001 open, AN-002/004/005 fixed, AN-003/006 observations).

## Notes
- The 66/29/2-3 split is the campaign's audit headline; `view-classification.md` carries the per-struct evidence and the reconciliation (raw 74-conditional sweep → 66 logic-bearing after binning attribute-only-variant views with the branchless-29 and carving the 2 shells). Each cluster RE-CONFIRMS its members at execution.
- Fixed-`Date` constant, fixed `OuroAgentRecord` (relative paths), temp `agentBundlesURL`, and STANDALONE menu/popover instantiation are the four reusable fixture primitives the C0 spike pack proves once and every later cluster imports.
- `NSFullUserName()` in `ProviderConfigSheet`'s `@State` default is the ONE determinism landmine beyond the audit's enumerated edge-cases (Q3) — flagged as a genuine fork.

## Progress Log
- 2026-06-25 13:04 **Pass 1 (first draft) committed** (`3b0359f`). Created from the campaign journal (U4 intake). The 127-view classification (`view-classification.md`) built from two parallel structural reads; the 6 flagged edge-cases validated first-hand @ `7a65601`; the 12-cluster (C0–C11) area-locality decomposition sequenced high-value-first; the 4 honest-allowlist candidates + the deferred branchless-29 listed; Q1–Q5 forks recorded with reversible defaults. Status: drafting → conversion passes next.
- 2026-06-25 13:04 **Pass 2 (granularity) — no structural changes needed.** Each cluster C0–C11 is atomic (one reviewable PR-batch of file-local related views), testable (its enumerated state-set + ≥1 mutation-verified control), one session-sized; each unit carries What/Output/Acceptance. C6/C9 carry explicit split-at-execution notes (Q4) so an oversized cluster splits into a 1x/1y pair (PR count 12–16). Per-unit TDD phases (red → provenance fixture+widening → green → mutation-verify control → coverage/refactor) are stated in TDD Requirements + Execution. No large unit to break down further; the high-fan-out sheets are already isolated to their own PR.
- 2026-06-25 13:05 **Pass 4 (quality) — clean, no fixes needed.** 12/12 work-unit headers carry the `### ⬜ Unit Cx:` status emoji; 0 TBD/TODO/FIXME; every unit has What/Output/Acceptance; Completion Criteria are testable checkboxes; Code Coverage Requirements + TDD Requirements present; coverage-gate explicitly deferred to the final campaign step (not U4). The C0–C11 decomposition sub-headers (the cluster catalogue) are descriptive, distinct from the emoji'd work units.
- 2026-06-25 13:05 **Pass 3 (validation) — all refs/claims verified against source @ `7a65601`; no corrections needed.** 24/24 struct line-refs OK (`TerminalAgentRow`:3640 … `InactiveTerminalSurface`:9276). Load-bearing claims confirmed first-hand: `AgentInspectorPanel` renders `Text(agent.bundlePath)`+`Text(agent.configPath)` (path-leak real); `ProviderConfigSheet` `@State private var humanName = NSFullUserName()` (Q3 landmine real); `SessionDetailView` `if let session = model.activeSession(for:)` → `TerminalPane(session:)` (live-arm carve real); `BossWatchStatusView` `Text(change.occurredAt.formatted(date:.omitted,time:.standard))` (baked-at-construction clock → fixed-Date fixture); `DecisionInboxSheet var now: Date? = nil` (injectable clock ALREADY wired U2 → no new source touch). Baselines re-measured: **59 `__Snapshots__`, 269 guard sites, 23 AppViews test files, 123 view structs** — all match the doc. No source drift; the doc's reality is current.
