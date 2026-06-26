# U5 B6 — decision-log / inbox / command-palette drive-to-100% records

Batch B6 = 4 views / **59 uncovered regions** at `origin/main` (post-Unit-1 split). Every reachable
region is DRIVEN by INVOKING its closure (ViewInspector 0.10.3 `.tap()`/`.callOnAppear()`/
`.callOnDisappear()`/`.callOnChange(oldValue:newValue:)`/`.callOnSubmit()` + `Menu{}` descent) and
ASSERTING the side-effect; each was mutation-verified RED→GREEN. The only residual is the genuinely-
unreachable carve seed below (10 regions — autoclosure artifacts / @State re-render / no-key-press
driver / vestigial Identifiable).

**Measurement basis:** `xcrun llvm-cov export … WorkbenchViews.swift` segments with
`isRegionEntry && hasCount && count==0`, scoped to each decl's line range, AFTER the full suite
(3481 tests / 1 skip / 0 fail with `--enable-code-coverage`) ran with the B6 tests in place.
Script: `b6-measure.py` (this dir).

| view | decl lines | before | driven | carved | after |
|---|---|---|---|---|---|
| DecisionLogSheet | 2168–2223 | 5 | **5** | 0 | **0** |
| DecisionInboxSheet | 2235–2423 | 21 | **21** | 0 | **0** |
| DecisionLogRow | 2599–2835 | 14 | **11** | 3 | **3 (carve)** |
| CommandPaletteSheet | 5054–5221 | 19 | **12** | 7 | **7 (carve)** |
| **total** | | **59** | **49** | **10** | **10 (carve)** |

> Line numbers below are POST-EDIT (the `DecisionInboxSheet.init` seam shifted everything after
> L2253 by +17). The `before` snapshot used pre-edit lines (the unit2-batch-plan numbers).

---

## DecisionLogSheet (L2168–2223) — 5 → 5 driven, 0 carved

Test: `DecisionLogSheetInteractionTests` (the C4 `DecisionLogSheetTests` covers the render arms).

Driven (each asserted + mutation-verified):
- **timeZone/locale prod-default autoclosures** (`var timeZone = .autoupdatingCurrent` / `locale`):
  constructed the sheet WITHOUT injecting the clock seams → the `.autoupdatingCurrent` default-value
  autoclosures execute. Asserted byte-identical-twice + no path leak under the host TZ/locale pin.
- **`Button("Done") { dismiss() }`**: `find(button:"Done").tap()` → the action region executes;
  asserted the model (`decisionLog`) is untouched (the action is a pure environment `dismiss()`).
- **embedded-row `onTeach` trailing closure** (`{ autoAdvance in Task { await model.teachBoss(…) } }`):
  tapped the embedded row's Teach Menu item ("Do this automatically next time" — the non-current,
  plain-`Text` option) → the closure dispatched `model.teachBoss`, asserted via the synchronous
  `recordActionLog("teachBoss")` entry (awaited the MainActor Task). **Mutation:** neutralizing
  `onResolve()`/`run`/the ternary all went RED (sweep below).

After: `--show-regions` → **0 uncovered** in L2168–2223.

---

## DecisionInboxSheet (L2235–2423) — 21 → 21 driven, 0 carved

Test: `DecisionInboxSheetInteractionTests`. **Source seam added** (minimal, prod default UNCHANGED):
`init(model:now:timeZone:locale:initialShowFullLog:)` seeds `_showFullLog = State(initialValue:)`,
parallel to the existing `now`/`timeZone`/`locale` test seams (precedent: `ProviderConfigSheet`,
`EditTerminalGroupSheet`). The inline `@State … = false` default was removed (now seeded by init),
which ELIMINATED the L2240 default-value autoclosure region entirely (driven-to-0, not carved).

Driven (each asserted + mutation-verified):
- **`showFullLog == true` family** — the header ternary true arms ("Boss Decision Log" + the log
  subtitle), the `if showFullLog` true branch, and the WHOLE `fullLog` `@ViewBuilder` (BOTH the
  `decisionLog.isEmpty` empty-state arm AND the populated `ScrollView { ForEach … }` arm): rendered
  via `initialShowFullLog: true` (a `.tap()` on the in-view Picker/"View full decision log" toggle
  cannot re-render `@State` under inspect, so the init seam is the sanctioned driver). Asserted the
  log title/subtitle/rows render and the inbox title does NOT; negative-control flips the whole tree.
- **`Button("Done") { dismiss() }`**: tapped; model untouched.
- **`Button("View full decision log") { showFullLog = true }`**: present only in inbox-zero +
  non-empty-log; tapped (the action region executes).
- **`onAcknowledge: { model.acknowledgeDecision(decision) }`**: tapped Ack → asserted the
  `inbox:acknowledge` audit entry AND the decision left `openInboxGroups(now:)`.
- **`onResolve: { model.resolveDecision(decision) }`**: tapped Resolve → `inbox:resolve` + queue exit.
- **`onSnooze: { model.snoozeDecision(decision, for: $0) }`**: tapped the "1 hour" Snooze item →
  `inbox:snooze…` + queue exit.
- **inbox-row `onTeach` closure** + **fullLog-row `onTeach` closure** (two DISTINCT trailing
  closures): tapped each Teach Menu item → `model.teachBoss` (asserted via the `teachBoss` audit
  entry, MainActor-awaited).

After: **0 uncovered** in L2235–2423.

---

## DecisionLogRow (L2599–2835) — 14 → 11 driven, 3 carved

Test: `DecisionLogRowInteractionTests` (standalone leaf seam; C4 `DecisionLogRowStateSetTests`
covers the render arms).

Driven (each asserted + mutation-verified):
- **timeZone/locale prod-default autoclosures** (L2625/L2626 pre-shift L2595/2596): row constructed
  without the clock seams → defaults execute; byte-identical-twice asserted.
- **`sessionName ?? "unknown session"`** RHS: `sessionName: nil` fixture → "unknown session" renders.
- **Resolve `Button { onResolve() }`**: `find(button:"Resolve").tap()` → onResolve fired (captured).
- **Snooze Menu** `Button("1 hour"){onSnooze(3600)}` / `Button("Until end of day"){onSnooze(…)}` /
  `Button("1 day"){onSnooze(86_400)}`: tapped each → asserted the EXACT interval (end-of-day via the
  REAL `WorkbenchTriageInterval.untilEndOfDay()`, asserted bounded `[60, 86_400]`).
- **Ack `Button { onAcknowledge() }`**: tapped → onAcknowledge fired.
- **Teach Menu `Button { onTeach(option.reinforces); taught = true }`**: tapped both the reinforce
  ("Do this automatically next time" → `onTeach(true)`) and correct ("Always ask me" → `onTeach(false)`)
  options; asserted the captured polarity (the action body runs BOTH statements).
- **`severityColor` `.normal → .blue` / `.low → .secondary`** switch arms: inbox-mode rows whose REAL
  `DecisionSeverity.of` lands on `.normal` (safe autoAdvance) / `.low` (hold) — provenance-asserted.

Carved (3 regions — recorded for Unit 3):
| line:col | region | carve kind |
|---|---|---|
| L2627:33 | `@State private var taught = false` | @State default-value `State(wrappedValue:)` autoclosure — llvm-cov does not count it (the documented @State-default artifact; the property IS used). |
| L2632:30 | `private let phrasebook = DecisionLogPhrasebook()` | stored-property default-value autoclosure — llvm-cov-stored-default artifact (the phrasebook IS used: `teachOptions`/`statusPhrase`/`decidedBy` are covered; only the init-region counter is not incremented). |
| L2735:27 | `if taught {` TRUE arm ("Sent to boss") | @State-rerender-after-tap — tapping a Teach Menu item EXECUTES `taught = true` (the setter region L2735’s sibling assign at the Teach button is covered), but ViewInspector’s no-host synchronous `inspect()` re-seeds `@State` from `false` on the next read, so the *rendered* `taught == true` branch never re-evaluates. Only a live SwiftUI host re-running the body after the @State write reaches it. |

After: **3 uncovered** (the 3 carves above) in L2599–2835.

---

## CommandPaletteSheet (L5054–5221) — 19 → 12 driven, 7 carved

Test: `CommandPaletteSheetInteractionTests` (C4 `CommandPaletteSheetTests` covers the render arms).

Driven (each asserted + mutation-verified):
- **`.onAppear { model.commandPaletteQuery = ""; selectedIndex = 0; searchFocused = true }`**:
  `vStack().callOnAppear()` → asserted `commandPaletteQuery == ""` (was a stale query).
- **`.onDisappear { model.performPendingPaletteCommand() }`**: `vStack().callOnDisappear()` with a
  pending command → asserted it was consumed (`pendingPaletteCommand == nil`); negative control: no
  pending → clean no-op (the `guard let pending` early-return).
- **`.onChange(of: model.commandPaletteQuery)`**: `vStack().callOnChange(oldValue:"",newValue:"boss")`.
- **`.onChange(of: selectedIndex)` + its `withAnimation { proxy.scrollTo }`**:
  `find(ScrollView).callOnChange(oldValue:0,newValue:1)`.
- **palette-row `Button { run(command) }`** (L5151 area): `find(button: <title>).tap()` → asserted
  `model.pendingPaletteCommand?.id == command.id`.
- **`runSelectedCommand()` via `.onSubmit`** → `visualOrderedItems` → `run(_:)`:
  `find(TextField).callOnSubmit()` with a non-empty list (guard PASSES → the visual-first command
  pends) AND with an empty `zzqqx…` list (guard FAILS → the `else { return }`, nothing pends).

Carved (7 regions — recorded for Unit 3):
| line:col | region | carve kind |
|---|---|---|
| L5060:40 | `@State private var selectedIndex = 0` | @State default-value autoclosure — llvm-cov-uncounted (the @State-default artifact). |
| L5071:45 | `.onKeyPress(.downArrow) { moveSelection(by: 1); return .handled }` | live-key-press — ViewInspector 0.10.3 has NO `onKeyPress` driver (`^0` confirmed); the closure cannot be invoked in-process. |
| L5072:43 | `.onKeyPress(.upArrow) { moveSelection(by: -1); return .handled }` | live-key-press (same; `^0`). |
| L5142:41 | `var id: WorkbenchCommandSection { section }` (on private `SectionedRows`) | vestigial-Identifiable — `ForEach(sectionedRows, id: \.section)` uses an explicit keypath, so `.id` is never read. |
| L5200:47 | `private func moveSelection(by delta: Int)` entry | unreachable-helper — called ONLY from the two un-invokable `.onKeyPress` closures. |
| L5202:30, :40 | `moveSelection`'s `guard count > 0 else { return }` (both arms) | unreachable-helper (same; reached only via onKeyPress). |

After: **7 uncovered** (the 7 carves above) in L5054–5221.

---

## P2 mutation sweep (non-vacuity — RED→GREEN, all reverted)

Each mutation compiled under `-warnings-as-errors -strict-concurrency=complete` and made the targeted
effect-assertion RED; reverting returned the suite to GREEN.

| # | mutation | tests that went RED |
|---|---|---|
| 1 | DecisionLogRow Resolve action `onResolve()` → `_ = onResolve` (don't call) | `testRow_inbox_resolveButton_firesOnResolve` |
| 2 | palette `run` `pendingPaletteCommand = command` → `= nil` | `testPalette_rowButton_tapSetsPendingCommand`, `testPalette_onSubmit_nonEmpty_runsSelectedCommand` |
| 3 | palette `.onAppear` query reset `"" → "MUTATED"` | `testPalette_onAppear_resetsQuery` |
| 4 | DecisionInboxSheet header ternary → constant `Text("Decision Inbox")` | `testInbox_fullLog_populated_rendersLogTitleAndRows`, `testInbox_negativeControl_showFullLogFlipsTree` |
| 5 | DecisionLogRow Snooze "1 hour" `onSnooze(3600) → onSnooze(7200)` | `testRow_inbox_snoozeMenu_oneHour_fires3600` |

## Determinism (P3)

Cross-TZ proof: the 7 timestamp-bearing decision test classes (`DecisionLogRow*`, `DecisionLogSheet*`,
`DecisionInboxSheet*`) ran byte-identically under `TZ=America/Los_Angeles`, `TZ=America/New_York`,
and `TZ=UTC` (46 tests, 0 failures each) — a TZ leak would RED the committed snapshot refs. Row
timestamps render through the `Date.workbenchTimeText(…)` seam + the host's UTC/POSIX pin.

## Gates (all green)

- Strict build `-warnings-as-errors -strict-concurrency=complete` → 0 errors / 0 warnings.
- `swift test` (strict) → 3481 tests, 1 skip (pre-existing env-gated `RepairAgentKeystoneTests`), 0 fail.
- `--uisurfacetest` → all surfaces ok.
- `scripts/check-coverage.sh` → PASS (Core/ShellAdapter 149/151 at 100%, the 2 PRE-EXISTING allowlist
  exclusions UNCHANGED; `COVERAGE_DIRS` + `coverage-allowlist.txt` UNTOUCHED — `WorkbenchViews.swift`
  is in `OuroWorkbenchAppViews`, not a gated dir; Unit 3 wires the views gate).
- Structural guards (`check-shell-dependency.sh`, `smoke-package-shallow-guard.sh`) → ok.
- No leaks; provenance-checked fixtures; one commit per view.

## Carve budget delta for Unit 3

B6 adds **10** carve regions to the Unit-3 allowlist seed (3 DecisionLogRow + 7 CommandPaletteSheet);
DecisionLogSheet and DecisionInboxSheet contribute **0** (the latter's lone `@State` default was
eliminated by the init seam, not allowlisted). Lowering any of the 10 by 1 would require either a
ViewInspector key-press/host-rerender driver that 0.10.3 lacks or reading a vestigial getter no code
path reaches — i.e. the carve set is minimal.
