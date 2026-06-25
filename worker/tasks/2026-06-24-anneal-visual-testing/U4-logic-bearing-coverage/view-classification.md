# The 127-view audit classification (reconciled @ `7a65601`)

Built from two parallel structural reads of every uncovered `View` body in
`Sources/OuroWorkbenchAppViews/WorkbenchViewsAndModel.swift` (123 `View` structs;
the campaign's "127" includes a few counted-differently pre-extraction). Each line:
`StructName | bucket | line | reason`.

- **LOGIC-BEARING** = a data-driven branch (`if`/`else`/`switch`/ternary-on-data/`ForEach`-over-model) changes the **serialized node tree** → needs a multi-state snapshot set. → **U4 scope.**
- **BRANCHLESS** = single static node tree (the only variance is attribute-only — geometry/color/font — which the harness whitelist drops). → DEFERRED (separate allowlist decision).
- **COVERED** = already snapshotted in U0–U3 (surfaces A/B/C/D/E/F + the SU3r leaf).

## Covered (30 — NOT in U4 scope)

BossProposalCardList, BossProposalCard, BossProposalItemRow, WorkbenchSidebarView,
WorkspaceSidebarRow, SidebarWorkspaceEmptyRow, InlineRenameEditor, WorkspaceTabStrip,
TerminalAgentRow (+ the running-leaf), ElapsedTimePill, StatusPill, RecoverySheet,
RecoverySheetSection, NeedsYouEntryRow, RecoverableEntryRow, OnboardingBossChoiceView,
OnboardingBossChoiceRow, OnboardingReadinessView, FirstRunBootstrapView, FirstRunStepRow,
FirstRunNarrationRow, OnboardingRepairStepRow, OnboardingStatusRow, RetryButton (proof),
DashboardRowLabel (importability proof). (30 incl. the families' covered members.)

## Logic-bearing uncovered (66 — U4 scope)

GitBranchChip | LOGIC | 3770 | if let label / if dirty / if let aheadBehind
SessionChip | LOGIC | 3898 | if let activity (gate: !archived, activity != nil || isStalled)
SidebarFilterField | LOGIC | 2869 | if !sidebarFilter.isEmpty
SidebarAgentRow | LOGIC | 3411 | if isBoss / if let lane
WorkspaceRowContextMenu | LOGIC | 3157 | if row.nameOverride != nil
TerminalRowContextMenu | LOGIC | 3538 | activeSession ?: Launch/Restart, if active, if archived, ForEach projects
HarnessStatusSheet | LOGIC | 1150 | if let result / if let observedAt
HarnessAgentRow | LOGIC | 1420 | if isBoss / if let mcpStatus  [private→internal]
HarnessActionRow | LOGIC | 1500 | if isUrgent / if isBusy  [private→internal]
HarnessActionResultBanner | LOGIC | 1540 | ternary on result.succeeded  [private→internal]
ShortcutHelpSheet | LOGIC | 1652 | ForEach(groups) / ForEach(shortcuts)
SettingsSheet | LOGIC | 1755 | computed section composition
ImportSummaryBanner | LOGIC | 1963 | if let summary / if !persisted / if let detail / if let entryID
DecisionLogSheet | LOGIC | 2119 | if decisionLog.isEmpty else ForEach
DecisionInboxSheet | LOGIC | 2181 | if showFullLog / ForEach(groups)  [injected now:]
ReportBugSheet | LOGIC | 2345 | if note.isEmpty / if let error / if let url / if let issueURL
DecisionLogRow | LOGIC | 2515 | @State taught / if let friend / if let proposed / mode==.inbox  [private→internal]
AgentHomeEmptyState | LOGIC | 2740 | if !ouroAgents.isEmpty / ForEach(ouroAgents)
HeaderView | LOGIC | 3965 | if statusLine.shouldShow / if let badge / if bossPaneCollapsed / ForEach(recentWorkspacePaths)
BossWatchHeaderToggle | LOGIC | 4212 | if presentation.isVisible
BossSelectorView | LOGIC | 4255 | if !bossAgentChoices.isEmpty / if bossShowsMissingPill
BossAgentNamePopover | LOGIC | 4405 | if !trimmedAgentName.isEmpty && !canApply  [standalone]
AutonomyStatusButton | LOGIC | 4495 | switch ttfaStyle / switch loginItem.status
AutonomyStatusPopover | LOGIC | 4594 | ForEach(checks) / if isActionable / if !loginItem.isEnabled  [standalone]
AutonomyStatusCheckRow | LOGIC | 4736 | if check.state == .blocker
CommandPaletteSheet | LOGIC | 4955 | if filtered.isEmpty / ForEach(sectionedRows)
BossDashboardView | LOGIC | 5130 | if let door / if bossWatchLastError / if checkInRunning / if let dashboard / if showsAdvanced
BossNeedsMeCodingColumns | LOGIC | 5366 | if !needsMeItems.isEmpty / if !codingItems.isEmpty
HabitHistoryPanelView | LOGIC | 5457 | if rows.isEmpty / ForEach(rows.prefix(5))
MetricStateChip | LOGIC | 5600 | if presentation.isUnavailable
MetricChip | LOGIC | 5700 | if let tap
BossConversationView | LOGIC | 5791 | ForEach(bossQuickQuestions)
OuroAgentManagerView | LOGIC | 5836 | if ouroAgents.isEmpty else ForEach  [AN-001]
OuroAgentRowView | LOGIC | 5905 | if isBoss / if let registration / if isActionable  [AN-001 / path-leak]
ProviderConfigSheet | LOGIC | 6071 | if isNewAgent / ForEach(credentials)  [@State NSFullUserName() — Q3]
OuroAgentInstallSheet | LOGIC | 6230 | if validation / if message states
WorkbenchOnboardingSheet | LOGIC | 6335 | switch page / if showsInspector  [re-confirm: router shell?]
OnboardingFlowHeader | LOGIC | 6544 | ternary on hasBeenCompleted  [private→internal]
OnboardingPageContent | LOGIC | 6577 | switch page  [private→internal]
MarkdownMessageView | LOGIC | 6621 | ForEach(blocks) switch block type
OnboardingAgentProviderSummary | LOGIC | 7088 | if agent / if lanesShareOneConnection  [private→internal]
OnboardingBossReconstructView | LOGIC | 7274 | if/else-if/else state machine  [private→internal]
SessionStatusListView | LOGIC | 7509 | if !list.isEmpty / bucket sections
SessionStatusBucketSection | LOGIC | 7567 | if !rows.isEmpty / ForEach(rows)  [private→internal]
SessionStatusRowView | LOGIC | 7596 | if let group / switch detailLine  [private→internal]
ActionLogView | LOGIC | 7663 | if isExpanded / ForEach(entries)
BossActionReceiptStrip | LOGIC | 7782 | if !summary.isEmpty / if isExpanded / if hasFailures ForEach
BossWatchStatusView | LOGIC | 7854 | if !changeSummaries.isEmpty ForEach  [clock: occurredAt.formatted]
TranscriptSearchView | LOGIC | 7897 | if !results.isEmpty ForEach / if empty query
BossWorkbenchMCPSetupView | LOGIC | 7965 | if registration?.isActionable  [AN-001]
AgentDetailView | LOGIC | 8007 | if showsInspector
AgentTitleStrip | LOGIC | 8048 | if isBoss / button-state ternaries  [private→internal]
AgentInspectorPanel | LOGIC | 8170 | if let registration  [private→internal / PATH-LEAK bundlePath+configPath]
AgentStatusCard | LOGIC | 8229 | if isActionable / if let registration / if boss blocked  [private→internal / AN-001]
LanePanel | LOGIC | 8377 | if let lane (nested provider/model)  [private→internal]
SessionDetailView | LOGIC | 8477 | if showsInspector / if let session / if let banner / else inactive  [LIVE-ARM carve]
SessionAttentionBanner | LOGIC | 8559 | if offersJumpToPrompt / switch state  [private→internal]
DetailSplitContainer | LOGIC | 8612 | if let split switch axis / secondaryPane if/else  [LIVE-ARM carve]
EmptyPanePicker | LOGIC | 8731 | if candidates.isEmpty else ForEach  [private→internal]
TerminalSearchBar | LOGIC | 8825 | if !hasResult / conditional toggles
SessionTitleStrip | LOGIC | 8917 | if let attention / if let cliName / if archived / switch statusDot  [private→internal]
SessionInspectorPanel | LOGIC | 9042 | multiple if-let pills / if let notes / if transcriptTail  [private→internal]
SessionTranscriptSheet | LOGIC | 9110 | if let tail  [private→internal]
SessionStatusBar | LOGIC | 9158 | ternary archived / if/else-if buttons / if !archived health
CustomSessionManagementBar | LOGIC | 9206 | if archived else / ForEach projects
InactiveTerminalSurface | LOGIC | 9276 | if archived / if manualRecoveryNeeded / if canRecover / if transcript
RunningSessionHeaderControls | LOGIC | 9494 | ForEach(primaryActions) / ForEach(sections) / switch menuButton
NewTerminalSessionSheet | RECONFIRM (attribute-only-leaning) | 9931 | only `.disabled(!canCreate)` + an `onChange`/`guard` — NO node-tree branch; likely drops to branchless at the C11 reconfirm
RecoveryDrillView | LOGIC | 10288 | if let result ForEach(items)
TranscriptHistoryView | LOGIC | 9767 | if tail.truncated + Text(tail.path) PATH-LEAK [moved from branchless by the review gate; C9]

(**69 confirmed-LOGIC + 1 RECONFIRM** above; see reconciliation. The review gate added
`TranscriptHistoryView` here from the branchless list.)
`MachineRuntimeView` (`:10170`, login-item `@StateObject`) and `WorkbenchRootView` (`:131`, shell)
are NOT in the 69 — they are allowlist-candidates.

**The 3 RECONFIRM (attribute-only-leaning) entries** — re-checked per cluster; each either confirms a
real serialized-tree flip (stays LOGIC, counted in the 66) or drops to branchless-29:
- `NewTerminalSessionSheet` (`:9931`) — `.disabled(!canCreate)` is attribute-only (the harness whitelist
  drops it); the `onChange`/`guard` is not a render branch → LIKELY branchless. **HarnessActionResultBanner
  stays LOGIC** (its `Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")`
  flips the SF-SYMBOL NAME, which the harness DOES capture via `image().actualImage().name()` → real tree flip).
- 2 more marginal entries (`ProviderModelPill`-shaped attribute-only ternaries already binned in branchless;
  re-checked at the owning cluster). The doer reconfirms each against `ViewSnapshotHost.mapNode`'s whitelist
  (Text string / TextField bound value / Image symbol name / a11y label-value-id) — if the only variance is
  geometry/color/font/disabled, it's branchless (deferred); if it flips a captured node, it's LOGIC (snapshot it).

## Branchless-presentational (29 — DEFERRED, separate allowlist decision)

HarnessSection (1357), HarnessDetailRow (1398), SettingsSection (1946), AboutSheet (2072),
WorkspaceTabContextMenu (3369), SidebarActionRow (3382), SidebarCountBadge (3521),
StatusDot (3878), DashboardStatusLine (4866), InboxDoorPill (5319), DashboardMetricsStrip (5512),
WorkbenchVisibilityStrip (5643), MailboxWarningView (5740), OnboardingProgressDots (6602),
ProviderModelPill (7128), AgentLanesCard (8338), AgentActionsCard (8416), DetailPaneChrome (8671),
TerminalSearchToggleButton (8803), SessionNotesView (9144), TranscriptRehydrationPreview (9428),
TerminalFocusView (9681), NewTerminalGroupSheet (9798),
EditTerminalGroupSheet (9866), EditTerminalSessionSheet (10042), SessionNotesEditor (10150),
ReleaseUpdateView (10249), WorkbenchReleaseUpdateControls (10261).

(**28 branchless** — `TranscriptHistoryView` was MOVED OUT to LOGIC/C9 by the fresh review gate:
it has `if tail.truncated` (`:9775`) AND renders `Text(tail.path)` (`:9781`, a path-leak) → genuinely
logic-bearing, not branchless.) *A few remaining are attribute-only-variant (OnboardingProgressDots,
ProviderModelPill, DetailPaneChrome, TerminalSearchToggleButton) — re-confirmed per cluster; if one
flips a real captured node it JOINS its cluster.*

**C1 starred-candidate RECONFIRM (resolved at execution against `ViewSnapshotHost.mapNode`'s whitelist):**
- `SidebarCountBadge` (`:3558`) — **MOVED OUT to LOGIC (C1, covered)**: body `Text("\(count)")` +
  `.accessibilityLabel("\(count) active terminals")` flips a CAPTURED Text value AND a captured a11y
  label with `count` → a value-flip in a captured node (the `GitBranchChip` class), NOT branchless.
  Snapshotted in `SidebarCountBadgeTests` (3 refs, mutation-verified). Branchless count is now **27**.
- `WorkspaceTabContextMenu` (`:3406`) — **STAYS BRANCHLESS / DEFERRED**: re-confirmed genuinely branchless —
  its only content is the CONSTANT `Label("Rename Tab…  ⌘R", systemImage: "pencil")`; `tab` feeds ONLY the
  (non-rendered) `beginRename` action closure, never a captured node. NOT forced (per the C1 cluster note).

## Genuinely-untestable / shell (2–3 — DEFERRED, honest-allowlist)

WorkbenchRootView (131) — NavigationSplitView/scenePhase/dockTile/menu shell.
MachineRuntimeView (10170) — LoginItemController @StateObject, no injection seam.
(+ the LIVE arms of SessionDetailView / DetailSplitContainer — TerminalPane PTY — PARTIAL carve, not whole-view.)

## Reconciliation

The campaign's audit ESTIMATE was "~66 logic-bearing." The first-hand structural reclassification
here (two parallel reads + the fresh review gate's corrections) finds, after excluding the 2 full
shells (`WorkbenchRootView`/`MachineRuntimeView` → allowlist) and binning the attribute-only views
with branchless: **69 confirmed-LOGIC + 1 RECONFIRM** (`NewTerminalSessionSheet`, attribute-only-leaning
`.disabled(!canCreate)` → likely branchless). The logic-bearing test: a branch must change the
**SERIALIZED node tree** the harness captures (`ViewSnapshotHost.mapNode`'s whitelist — Text string /
TextField bound value / Image SF-symbol name / a11y label-value-id; geometry/color/font/`.disabled`
dropped). The review gate's corrections: `SessionTranscriptSheet`+`RunningSessionHeaderControls` were
correctly LOGIC but UNASSIGNED to a cluster (now → C9); `TranscriptHistoryView` was wrongly binned
branchless (now → LOGIC/C9, path-leak). **Net U4 plan target: ~69 logic-bearing views (slightly above
the audit's ~66 estimate — the reclassification is MORE complete, not a regression), ~215+ enumerated
states; 28 branchless deferred; 2 shells + 2 live-arm carves allowlisted.** The 1 RECONFIRM
(`NewTerminalSessionSheet`) is a bounded, recorded uncertainty resolved at its C11 cluster (a captured-node
flip → stays LOGIC; only dropped-attribute variance → branchless). The "~66 → ~69" delta is the audit
estimate sharpening under first-hand reads + the review gate — exactly the anneal "measure-method-improving"
case (read→reclassify), NOT new scope.
