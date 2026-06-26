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
