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
