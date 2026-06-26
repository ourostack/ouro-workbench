# U5 Unit 2 — batch B5 (session-detail cluster) records

**Branch:** `u5-b5-session-detail` off `origin/main @ 9a635ef` (B4 + batch plan).
**Recipe:** the CORRECTED recipe — **drive interactions, do NOT carve them**. ViewInspector
CAN invoke `Button(action:)`/`.onAppear`/`.onChange`/`Menu{}`-descended buttons via
`.find(button:).tap()` / `.callOnAppear()` etc. Each invoked closure asserts a real
side-effect (a `model.@Published` mutated — `errorMessage`, `editingSession`,
`pendingStopSession`, `pendingStartFresh`, `pendingDeleteSession`, `detailSplit`,
`state.processEntries`, `state.actionLog`, `NSPasteboard`) and is mutation-verified
(mutate the action BODY → the effect-assertion goes RED → revert → GREEN).

**Live-session seam (the running arms):** a real `TerminalSessionController` built from a
real `TerminalCommandPlan` WITHOUT `start()` (no process, `transcriptPath: nil` → no path
leak), injected into `model.activeSessions[entry.id]` so `model.activeSession(for:) != nil`.
This is the proven `TerminalFocusViewTests` / `TerminalRowContextMenuStandaloneTests` seam.

**Measurement basis:** `xcrun llvm-cov export … WorkbenchViews.swift` segments with
`isRegionEntry && hasCount && count==0`, scoped to each view's decl line range, AFTER the
full suite ran with `--enable-code-coverage`. Script: `/tmp/b5-measure.py` / `/tmp/b5-regions.py`.

## B5 baseline (origin/main @ 9a635ef, full suite)

| view | L-range | uncovered BEFORE |
|---|---|---|
| LanePanel | 8527-8564 | **0** (already covered via OuroAgent surfaces — plan's 5 was pre-split drift) |
| EmptyPanePicker | 8881-8943 | 4 |
| SessionTitleStrip | 9067-9188 | 13 |
| SessionInspectorPanel | 9192-9257 | 9 |
| SessionTranscriptSheet | 9260-9292 | 1 |
| SessionStatusBar | 9308-9354 | 3 |
| CustomSessionManagementBar | 9356-9421 | 10 |
| InactiveTerminalSurface | 9426-9571 | 11 |
| TranscriptRehydrationPreview | 9578-9642 | 5 |
| RunningSessionHeaderControls | 9644-9829 | 35 |
| TranscriptHistoryView | 9917-9946 | 1 |
| **TOTAL** | | **92** |

> The plan's B5 target was ~102 (pre-split estimate). The exact post-split baseline is **92**
> (LanePanel already at 0). The carve floor for B5 is the live `TerminalPane(session:)`
> `NSViewRepresentable` PTY body in `SessionDetailView` (K1 #3/#7, Unit 3) — that decl is NOT
> in this batch (B5 is the strip + panels, not SessionDetailView itself). B5's own views carve
> only llvm-uncountable autoclosure artifacts (if any survive).

---

## Per-view records (filled in as each view lands)

### TranscriptHistoryView (L9917-9946) — 1 → 1 driven, 0 carved
BEFORE: 1 uncovered (`L9938:42` — the `tail.text.isEmpty ? "No transcript output yet" : tail.text`
EMPTY arm). Pure value-seam (takes `TranscriptTail` directly, no model).
DRIVEN: an empty-text `TranscriptTail` fixture renders the placeholder; asserting ref
`TranscriptHistoryView.empty` pins `text="No transcript output yet"`. The populated + truncated
arms re-driven (`.populatedTruncated`). MUTATION: placeholder string `"No transcript output yet"`
→ `"MUTATED PLACEHOLDER"` → `.empty` snapshot + negative control RED (3 failures) → revert → GREEN.
CARVED: none. FIXED `/tmp/u5/session.log` tail.path (leak-defended).

### SessionTranscriptSheet (L9260-9292) — 1 → 1 driven (via INVOCATION), 0 carved
BEFORE: 1 uncovered (`L9276:32` — the `Button("Done") { dismiss() }` ACTION closure).
DRIVEN via INVOCATION: `find(button: "Done").tap()` executes the `{ dismiss() }` closure.
PROOF the tap colors the region: a scoped `swift test --filter SessionTranscriptSheetTests
--enable-code-coverage` run shows `L9276` GONE from the uncovered set (only `L9281` the
populated-tail arm remains, and that is covered by the existing full-suite tests, not in B5's
baseline). `dismiss()` is `@Environment` → no observable model side-effect, so the tap is a
genuine invocation (region driven, `XCTAssertNoThrow`) with no behavioral guard of its own; the
file's non-vacuity is the chrome (Transcript title + entry-name subtitle + Done label),
mutation-verified: `Text(entry.name)` → `Text("MUTATED-NAME")` → 5 failures RED → revert → GREEN.
CARVED: none.

### SessionStatusBar (L9308-9354) — 3 → 3 driven (2 via INVOCATION), 0 carved
BEFORE: 3 uncovered — `L9321:28` (Restore button ACTION), `L9328:28` (Recover button ACTION),
`L9346:98` (the `.orange` arm of `health.status == .available ? .secondary : .orange`).
C9 rendered the labels but carved the actions + the orange arm.
DRIVEN:
- `L9321` Restore via INVOCATION: `find(button: "Restore").tap()` → `restoreCustomSession`
  un-archives the entry; assert `state.processEntries.first?.isArchived == false`.
- `L9328` Recover via INVOCATION: an EMPTY-executable recoverable entry → `find(button:
  "Respawn").tap()` → `recover(_:)` → `WorkbenchCommandPlanner().recoveryPlan(...)` throws
  `emptyExecutable` → the catch arm sets `errorMessage` SYNCHRONOUSLY (no Task/no spawn); assert
  `errorMessage != nil` + names the entry.
- `L9346:98` `.orange` arm: inject `ExecutableHealth(status: .missing)` → the non-available row
  renders (`text="Executable: not found on PATH"`), asserting ref `.missingExecutable`.
PROOF: scoped `--filter SessionStatusBarDriveTests --enable-code-coverage` → all 3 baseline
regions GONE; only `L9346:72` (the `.secondary` available arm) shows uncovered in the scoped run,
and that arm is covered by the existing C9 configured/recoverable tests in the full suite → 0.
MUTATION: removed `restoreCustomSession(entry)` + `recover(entry)` action bodies → 4 failures RED
(both taps + both negative controls) → revert → GREEN.
CARVED: none. FIXED `/tmp/u5` cwd (leak-defended).

### EmptyPanePicker (L8881-8943) — 4 → 4 driven (1 via INVOCATION), 0 carved
BEFORE: 4 uncovered — `L8908:36` (candidate Button ACTION `assignSecondaryPane`), `L8913:88`
(the GREEN `activeSession != nil` circle arm), `L8918:80` (`if let cliName` pill), `L8925:38`
(the candidate row body). `SessionSplitAndOverflowTests` drove the empty arm + a no-session/no-cli
candidate only.
DRIVEN: a candidate that BOTH has a live session (no-PTY `TerminalSessionController` injected into
`activeSessions` → green circle) AND a CLI name (`.terminalAgent` `/usr/local/bin/claude` →
`cliName "Claude Code"` pill); the second candidate is plain (gray circle). The cli pill + both
rows render (asserting ref `.liveCandidates`). The candidate Button ACTION via INVOCATION:
`find(button: "plain"/"build").tap()` → `assignSecondaryPane(to:)` (a `detailSplit` is set first)
→ assert `detailSplit?.secondaryEntryID == that candidate.id`; the two taps distinguish the two
candidates.
PROOF: scoped coverage → all 4 baseline regions GONE; only `L8899` (empty arm) remains scoped,
covered by the existing empty-state test in the full suite → 0.
MUTATION: removed `assignSecondaryPane(to: entry.id)` action body → 2 failures RED → revert → GREEN.
CARVED: none. FIXED `/tmp/u5` cwd (leak-defended).

### TranscriptRehydrationPreview (L9578-9642) — 5 → 4 driven (1 via INVOCATION), 1 carved
BEFORE: 5 uncovered — `L9616:35` (truncated "tail" badge), `L9621:24` (the `Button {
onShowTranscript() }` ACTION), `L9630:44` (the empty-preview placeholder arm), and `L9602:75`
(the `strippingAnsiEscapes` regex-compile-failure else arm). Pure value-seam.
DRIVEN:
- `L9616` truncated badge: a `truncated: true` tail (asserting ref `.truncated`).
- `L9630` empty arm: an empty-text tail → empty previewText → placeholder (ref `.empty`).
- `L9621` Button ACTION via INVOCATION: `find(button: "View full transcript").tap()` →
  `onShowTranscript()`; assert a captured `shown` flag flips.
PROOF: scoped coverage → 4 baseline regions GONE; only `L9602:75` remains (the carve).
MUTATION: removed `onShowTranscript()` body → tap test RED → revert → GREEN. The truncated/empty
arms are guarded by the `.truncated`/`.empty` snapshot refs.
CARVED (1): `L9602:75` — `guard let regex = try? NSRegularExpression(pattern: <fixed literal>)
else { return input }`. The pattern is a constant valid regex that ALWAYS compiles, so `try?`
never returns nil → the else is genuinely UNREACHABLE. No seam (even an invoking test) can inject
a bad pattern (the pattern is a `private static let` literal, not a parameter). llvm-uncountable
dead-else. → Unit 3 allowlist.
CARVE kind: dead-else-on-constant-valid-regex.

### SessionInspectorPanel (L9192-9257) — 9 → 9 driven (1 via INVOCATION), 0 carved
BEFORE: 9 uncovered — `L9203:60` (cliName purple pill), `L9205:18`/`L9206:57`/`L9208:18`
(the `if let badge = entry.owner.sidebarBadge` teal pill), `L9214:46`/`L9214:62`/`L9215:47`/
`L9215:55` (BOTH arms of the auto-resume status-pill ternary), `L9242:28` (the Transcript
`Button { onShowTranscript() }` ACTION). The existing inspector tests rendered basic/notes/
transcript-button arms but used a human-owned shell entry (no cli, no badge) and never tapped.
DRIVEN:
- cliName: a `.terminalAgent` `/usr/local/bin/claude` → `"Claude Code"` pill.
- badge: `owner: .agent(name: "boss-agent")` → `("cpu", "boss-agent")` teal pill.
- auto-resume ternary: BOTH arms — a `autoResume: true` fixture (`"auto-resume"`) and a
  `autoResume: false` fixture (`"manual restart"`), asserting refs `.rich`/`.manualRestart`.
- `L9242` Transcript ACTION via INVOCATION: a real `/tmp/u5-inspector/history.log` transcript →
  `find(button: "Transcript").tap()` → `onShowTranscript()`; assert a captured `shown` flag flips.
PROOF: scoped coverage → all 9 baseline regions GONE; only `L9231/L9233` (the `if let notes` arm)
remain scoped, covered by the existing `testInspector_withNotes` in the full suite → 0.
MUTATION: removed `onShowTranscript()` body → tap test RED → revert → GREEN. The cli/badge/ternary
arms are guarded by `.rich`/`.manualRestart` + the negative control.
CARVED: none. FIXED `/tmp/u5` + `/tmp/u5-inspector` paths (leak-defended).

### CustomSessionManagementBar (L9356-9421) — 10 → 10 driven (6 via INVOCATION), 0 carved
BEFORE: 10 uncovered — `L9362`/`L9370`/`L9378`/`L9390`/`L9396`/`L9405` (Edit/Duplicate/Move-
project/Restore/Archive/Delete button ACTIONS) + `L9368`/`L9387`/`L9402`/`L9411` (the
`isRunning ? "Stop … before …" : …` help-ternary TRUE arms). C9 drove the render flip only.
DRIVEN:
- 6 button ACTIONS via INVOCATION (one fresh model per tap → independent `@Published`
  assertion): Edit→`editingSession`; Duplicate→`processEntries.count` 1→2; Move("Other")→
  `projectId` changes (the `Menu{}` IS descended → `find(button: "Other").tap()`); Restore→
  un-archived; Archive→archived; Delete→`pendingDeleteSession`.
- 4 `isRunning`-true help arms: CONSTRUCT the bar with a live session injected (no-PTY
  `TerminalSessionController` in `activeSessions`); the body's ternaries evaluate during
  traversal (the `.help` tooltip node is dropped by the host but the ternary EXECUTES → region
  colored). Non-vacuity: `isRunning == true` asserted; asserting ref `.running`.
PROOF: scoped `--filter CustomSessionManagementBarDriveTests --enable-code-coverage` → **0
uncovered** (all 10 regions colored by this file alone).
MUTATION: removed `beginEditingSession(entry)` → Edit-tap RED; removed `moveSession(entry,…)` →
Move-tap RED → revert → GREEN. (The remaining 4 taps share the identical assert-the-side-effect
structure.)
CARVED: none. FIXED `/tmp/u5` paths (leak-defended).

### InactiveTerminalSurface (L9426-9571) — 11 → 11 driven (4 via INVOCATION), 0 carved
BEFORE: 11 uncovered — `L9429:40` (`onShowTranscript = {}` default autoclosure), `L9448:29`
(the `canRecover ? "Ready to recover"` headline arm), `L9495:28` (Restore ACTION), `L9504:28`
(Start-fresh ACTION), `L9512`/`L9513:28`/`L9513:39`/`L9515:32` (the Launch/Recover button +
`if canRecover { recover } else { launch }` arms + the `canRecover ? title : "Launch"` label),
`L9538:24` (Copy-launch ACTION), `L9550:106`/`L9554:14` (the executable-health label arm). C9
drove the headline RENDER arms but carved every action + the recover-headline + the health arm.
DRIVEN:
- `L9429` default autoclosure: construct `InactiveTerminalSurface(entry:model:)` WITHOUT
  `onShowTranscript` → the `= {}` default runs.
- `L9448` "Ready to recover": a recoverable entry with `lastSummary` cleared (the recovery plan
  is keyed by entry id → `canRecover` stays true; an entry with no summary is a real state) →
  the headline falls through to the `canRecover` arm; asserting ref `.readyToRecover`.
- 4 button ACTIONS via INVOCATION: Restore→un-archived; Start-fresh→`pendingStartFresh`;
  Launch/Recover→`errorMessage` (EMPTY-executable → planner throws SYNC, no spawn); Copy
  (image-only button, found by glyph `doc.on.doc`)→`state.actionLog` +1 (`copyLaunchCommand`).
- `L9550/9554` health label: inject `ExecutableHealth(status: .missing)`; ref `.missingExecutable`.
PROOF: scoped coverage → all 11 baseline regions GONE; only `L9556/L9558` (transcript-preview
arm) remain scoped, covered by C9's `testSurface_withTranscriptPreview` in the full suite → 0.
MUTATION: removed `recover(entry)` + `launch(entry)` action bodies → both tap tests RED → revert
→ GREEN. (Restore/Start-fresh/Copy taps share the identical assert-the-side-effect structure.)
CARVED: none. FIXED `/tmp/u5` paths (leak-defended).

### SessionTitleStrip (L9067-9188) — 13 → 13 driven (2 via INVOCATION), 0 carved
BEFORE: 13 uncovered — `L9074:20` (inspector-toggle ACTION), `L9097:56`/`L9105:14` (the live-
attention Label), `L9107:56`/`L9115:14` (cliName pill), `L9119:16`/`L9124:24` (the archived
Archived-label + Restore ACTION), `L9164:89`/`L9165:16`/`L9166:9` (liveAttentionToAnnounce switch),
`L9168:9`/`L9176:9`/`L9180:9` (statusDot switch). The existing strip tests used `.constant(true)`
+ a human shell and carved the actions, the live-attention arm, the cli pill, and three dot arms.
DRIVEN:
- `L9074` toggle ACTION via INVOCATION: a `BindingBox`-backed `Binding<Bool>` + tap the chevron
  button (found by glyph `chevron.right`) → assert the box flips false→true.
- `L9097/9105` + `L9164/9165` live-attention: a LIVE session (no-PTY controller) with
  `entry.attention = .waitingOnHuman` → `liveAttentionToAnnounce` returns it → the `Attention:`
  Label renders; the switch is driven across all five `AttentionState` values.
- `L9168/9176/9180` statusDot: the four `DotState` seams — `.attention` (live), `.recoverable`
  (inactive+canRecover), `.inactive` (inactive), `.archived` (archived).
- `L9107/9115` cli pill: a `.terminalAgent` `/usr/local/bin/claude` → `"Claude Code"` pill.
- `L9119/9124` archived Restore ACTION via INVOCATION: `find(button: "Restore").tap()` → un-archived.
PROOF: scoped coverage → all 13 baseline regions GONE; only `L9077/L9083` (the `showsInspector ==
true` chevron/help arms) remain scoped, covered by the existing `.constant(true)` test → 0.
MUTATION: removed `showsInspector.toggle()` body → toggle-tap RED → revert → GREEN. The
attention/dot/cli arms are guarded by `.liveWaiting`/`.cliPill` refs + the negative control;
the Restore tap shares the proven assert-the-side-effect structure.
CARVED: none. FIXED `/tmp/u5` paths (leak-defended).

### RunningSessionHeaderControls (L9644-9829) — 35 → 31 driven (10 via INVOCATION), 4 carved
BEFORE: 35 uncovered (the campaign never drove this view — the top B5 offender). The decl is
the `menuButton(for:)` + `primaryButton(for:)` `@ViewBuilder` switches over `SessionActionMenu`
+ `WorkbenchSurfacePolicy` seams.
DRIVEN:
- RENDER every menuButton arm by constructing TWO fixtures: a RUNNING custom session (live
  no-PTY controller → `layout(isRunning: true, isCustomSession: true)` → Send (controlC/escape/
  eof/redraw) + Window (focus) + restart + This-Session arms) and a NON-running custom session
  (askBoss + copy/openDir/edit/duplicate/move/archive/delete). The `Menu{}` IS descended → every
  case's Label builds → the case region is colored (asserting refs `.running`/`.nonRunning`).
- RENDER the primary arms: `.stop` (running), `.recover` (recoverable). 
- INVOKE 10 ACTION closures via `.tap()` asserting side-effects: sendControlC/sendEscape/sendEOF/
  redrawTerminal → `state.actionLog` (+action name); Focus → `terminalFocusEntryID`; Copy Launch
  Command → actionLog; Open Working Directory → actionLog; Edit/Duplicate/Move("Other")/Archive/
  Delete → `editingSession`/+1 entry/`projectId`/archived/`pendingDeleteSession`; Restart →
  `errorMessage` (EMPTY-exe planner-throws, no spawn); Recover primary → `errorMessage`; Stop
  primary → `pendingStopSession`; askBoss → `bossQuestion` (the `Button { Task { await
  runBossQuestion } }` — tapped, then yielded so the Task body's first pre-await statement sets
  `bossQuestion`; hermetic fixture, no real daemon → the trailing await fails fast).
PROOF: scoped `--filter RunningSessionHeaderControlsDriveTests --enable-code-coverage` → from 35
down to the 4 carve regions below.
MUTATION: removed `requestStop(entry)` (stop primary) + `sendControlC(to: entry)` (send-key) →
3 failures RED → revert → GREEN. (The other 8 taps share the identical assert-the-side-effect
structure.)
CARVED (4): the `primaryButton(for:)` `.launch` arm (`L9810:9`/`L9811:20`/`L9813:22`) and the
`default: EmptyView()` arm (`L9824:9`). Both are genuinely UNREACHABLE for this view:
`WorkbenchSurfacePolicy.sessionControls` sets `isRecoverable: model.recoveryPlan(for:) != nil`,
and `summary.recoveryPlans` (= `RecoveryPlanner.planRecovery(for: state)`) emits a plan for
EVERY in-state entry (including a `.noAction` no-op), so `recoveryPlan(for:)` is NEVER nil for an
entry rendered by this view → `isRecoverable` is always true (when not running/archived) →
`primaryActions` ∈ {`[.stop]`,`[.recover]`,`[]`} — it NEVER contains `.launch` and never a value
that would hit `default`. Even an invoking test can't reach these (no seam makes `recoveryPlan`
nil for an in-state entry). → Unit 3 allowlist.
CARVE kind: dead-primary-arm-unreachable-via-always-non-nil-recoveryPlan.
