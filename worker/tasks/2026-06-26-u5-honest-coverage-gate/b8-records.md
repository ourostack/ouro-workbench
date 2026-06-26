# U5 Unit 2 — batch B8 (boss-dashboard cluster) records

**Branch:** `u5-b8-boss-dashboard` off `origin/main @ ae46227` (post-B5 #325 + batch plan).
**Recipe (CONFIRMED ViewInspector 0.10.3):** DRIVE interactions via `.find(ViewType.Button.self).tap()`
(invokes the action closure) → ASSERT side-effect (`model.@Published` / recording closure flag / re-render)
→ MUTATION-VERIFY (mutate the action/arm body → RED → revert → GREEN). `@State` expanded arms driven via a
minimal `init(initialExpanded:)` seam (prod default UNCHANGED = false). Carve ONLY `.task {}`
(no ViewInspector 0.10.3 driver) + `@State`/var default-autoclosure llvm artifacts.

## B8 baseline (origin/main @ ae46227, full suite `swift test --enable-code-coverage`)

Measured: `xcrun llvm-cov export … WorkbenchViews.swift` segments with `isRegionEntry && hasCount &&
count==0`, scoped to each view's decl line range. Script: `b8-measure.py` (this dir).

| view | L-range | uncovered BEFORE | region locs |
|---|---|---|---|
| InboxDoorPill | 5396-5443 | 1 | 5407 (`.low` switch arm) |
| BossNeedsMeCodingColumns | 5443-5534 | 3 | 5477,5497,5514 |
| HabitHistoryPanelView | 5534-5589 | 1 | 5543 (`?? "No habit runs yet"` default) |
| MetricStateChip | 5677-5719 | 1 | 5697 (retry Button action) |
| BossConversationView | 5868-5912 | 6 | 5880,5881,5885,5886,5898,5899 |
| BossProposalCardList | 7473-7491 | 1 | 7484 (`.task`) |
| BossProposalCard | 7491-7535 | 2 | 7517,7523 (Dismiss/Approve) |
| BossProposalItemRow | 7536-7617 | 4 | 7552,7558,7583,7605 |
| ActionLogView | 7782-7902 | 14 | 7789,7790,7791,7793,7794,7812,7813,7814,7823,7832,7835,7835,7839 |
| BossActionReceiptStrip | 7908-7984 | 6 | 7915,7923,7924,7948,7956,7966 |
| BossWatchStatusView | 7985-8034 | 2 | 7992,7993 (timeZone/locale defaults) |
| BossWorkbenchMCPSetupView | 8103-8138 | 3 | 8113,8123,8133 (.task) |
| **TOTAL** | | **44** | |

> NOTE: `BossProposalCardList` (7473) is the list shell; the plan's "7 regions for BossProposalCardList"
> covers the whole proposal-card family (List + Card + ItemRow = 1+2+4 = 7 measured here). The list shell's
> own residual is just its `.task` (1).

---

## Per-view records (filled in as each view lands)

### InboxDoorPill (L5396-5443) — 1 → 1 driven, 0 carved
BEFORE: 1 uncovered (`5407:9` — `case .low: return .secondary`, the `.low` arm of the total
`static color(for:)` switch; existing C2 tests drove `.normal`/`.elevated`/`.critical` only).
DRIVEN: a real `.hold` decision floors the door to `DecisionSeverity.low` (`needsHuman(.hold)==true`,
`DecisionSeverity.of(.hold)==.low`) through the REAL `InboxDoorPresentation.resolve` seam; rendering the
pill evaluates `tint` → `Self.color(for: .low)` → the `.low` arm. The resolved tint is a DROPPED node
(host whitelist drops `Color`), so — like the existing `.critical` test — the arm is asserted via the
producer directly: `testDoor_colorForSeverity_lowArmReturnsSecondary` pins all 4 arms + their distinctness.
ASSERT: `presentation.topSeverity == .low` (provenance) + `color(for: .low) == .secondary` (producer).
MUTATION: `case .low: return .secondary` → `return .red` → `testDoor_colorForSeverity…` RED
(`"red" != "secondary"`) → revert → GREEN. Snapshot ref `InboxDoorPill.lowOne` recorded.
CARVED: none.

### MetricStateChip (L5677-5719) — 1 → 1 driven, 0 carved
BEFORE: 1 uncovered (`5697:28` — `Button { onRetry() }` action closure; existing C2 test renders
the retry glyph with `onRetry: {}` but never taps it).
DRIVEN via INVOCATION: an unavailable+retryable `MetricValuePresentation` (`resolve(value:nil,
isAvailable:false,issue:)` → `canRetry`) renders the retry button; `find(ViewType.Button.self).tap()`
executes `{ onRetry() }`. ASSERT: a recording closure `{ retried += 1 }` → `retried == 1`. Negative
control `testMetricStateChip_value_noRetryButton`: an available chip renders NO button (the
`if presentation.isUnavailable` / `if let onRetry, canRetry` gate is load-bearing → button search throws).
MUTATION: `onRetry()` → `_ = onRetry` → retry-tap test RED (`0 != 1`) → revert → GREEN.
CARVED: none.

### BossWorkbenchMCPSetupView (L8103-8138) — 3 → 2 driven, 1 carved
BEFORE: 3 uncovered (`8113` Refresh Button action, `8123` Install Button action, `8133` `.task{}`).
DRIVEN via INVOCATION:
- `8113` Refresh: seed a SENTINEL `.registered` registration the hermetic empty registrar can't
  reproduce; `find(ViewType.Button.self).tap()` runs `refreshWorkbenchMCPRegistration()` → the registrar
  re-read OVERWRITES the sentinel. ASSERT `bossWorkbenchMCPRegistration?.detail != "SENTINEL"`.
  MUTATION: `model.refreshWorkbenchMCPRegistration()` → `_ = model` → RED (sentinel survives) → revert → GREEN.
- `8123` Install: a `.notRegistered` (`isActionable`) registration renders Refresh+Install (2 buttons);
  `findAll(ViewType.Button.self)[1].tap()` runs `installWorkbenchMCPForBoss()` → the empty-bundle install
  throws → the `catch` sets `errorMessage`. ASSERT `errorMessage != nil` (was nil). MUTATION:
  `model.installWorkbenchMCPForBoss()` → `_ = model` → RED (errorMessage stays nil) → revert → GREEN.
CARVED (1): `8133` `.task { model.refreshWorkbenchMCPRegistration() }` — ViewInspector 0.10.3 has NO
`.task` driver (`callOnAppear`/`tap`/`callOnSubmit`/`callOnChange` only; `.task`'s async modifier is not
descended), so the `.task` closure is structurally undrivable through the synchronous `inspect()` seam.
--show-regions justified: the region's body (`refreshWorkbenchMCPRegistration()`) is the SAME call the
Refresh button drives (so its LOGIC is covered) — only the `.task`-modifier hook itself is uncolorable.
→ Unit-3 allowlist carve candidate.

### BossNeedsMeCodingColumns (L5443-5534) — 3 → 3 driven, 0 carved
BEFORE: 3 uncovered (`5477` coding key fallback autoclosure, `5497` View-all Button action,
`5514` itemButton Button action). Existing C2 tests RENDER the columns but never TAP a row/overflow.
DRIVEN via INVOCATION:
- `5514` itemButton: a needsMe row whose nav-key matches no process entry → `find(Button).tap()` runs
  `selectSession(byNavigationKey:)` → false → `presentDecisionInbox()` → `isDecisionLogPresented == true`.
  MUTATION: `model.selectSession(byNavigationKey: key)` → `_ = key` → RED → revert → GREEN.
- `5497` View-all: 5 needsMe items render the overflow control; start `bossPaneCollapsed == true`;
  `findAll(Button)[3].tap()` (last = overflow) runs `setBossPaneCollapsed(false)` → `state.bossPaneCollapsed
  == false`. MUTATION: `model.setBossPaneCollapsed(false)` → `_ = model` → RED → revert → GREEN.
- `5477` coding key `item.taskRef ?? item.runner`: a coding item with `taskRef==nil` + a REAL seeded
  process entry named "codex" → the `?? "codex"` fallback key MATCHES → `selectSession` true →
  `selectedEntryID == entryId` (inbox NOT opened). MUTATION: `item.taskRef ?? item.runner` →
  `item.taskRef ?? ""` → no match → `selectedEntryID == nil` → RED → revert → GREEN.
CARVED: none.

### HabitHistoryPanelView (L5534-5589) — 1 → 0 driven, 1 carved (proven-dead)
BEFORE: 1 uncovered (`5543:45` — the `?? "No habit runs yet"` RHS autoclosure of
`Text(model.statusMessage ?? "No habit runs yet")`, rendered only inside `if model.rows.isEmpty`).
CARVED (1) — PROVEN-DEAD via the real producer: the `?? "No habit runs yet"` fallback fires ONLY when
`statusMessage == nil` AND `rows.isEmpty`. But `HabitHistoryPanelModel.init` (the ONLY production
producer — `BossDashboardBuilder.build` + the default) sets:
  • `!isAvailable` → statusMessage = "Habit history unavailable…" (non-nil)
  • `isAvailable && summaries.isEmpty` → statusMessage = "No habit runs yet" (non-nil)
  • `isAvailable && !summaries.isEmpty` → statusMessage = nil **but rows is NON-empty** (the `if
    rows.isEmpty` view gate is then FALSE, so this `Text` is never rendered).
So `rows.isEmpty ⟹ statusMessage != nil` is an INVARIANT of the real init — the `?? "No habit runs
yet"` fallback is structurally unreachable through any production seam. Driving it would require a
fixture (`rows=[]`+`statusMessage=nil`) the real code path cannot produce → a P2 provenance violation.
--show-regions justified: the LHS `Text(model.statusMessage` is COVERED (the empty + unavailable C2
tests render it); only the dead `??`-RHS default autoclosure is `^0`. Verified no other producer sets
`statusMessage=nil`+empty-rows (grep over Sources/). → Unit-3 allowlist carve candidate.

### BossWatchStatusView (L7985-8034) — 2 → 2 driven, 0 carved
BEFORE: 2 uncovered (`7992`/`7993` — `var timeZone: TimeZone = .autoupdatingCurrent` /
`var locale: Locale = .autoupdatingCurrent` DEFAULT-ARGUMENT autoclosures). Every existing C0 clock
test INJECTS explicit `.gmt`/`en_GB` (for snapshot determinism), so the PRODUCTION default autoclosures
— the ones the real call site `BossWatchStatusView(model:)` (`:5347`) evaluates — were never executed.
DRIVEN: `testWatch_productionDefaults_noTimeZoneOrLocaleArg` constructs the view EXACTLY as production
does (OMITTING both args → the `.autoupdatingCurrent` default autoclosures run, coloring `7992`/`7993`).
With NO change summaries the body renders no timestamp `Text`, so the captured tree is TZ/locale-
independent + deterministic. ASSERT the rendered status line ("watching") + "Boss Watch" label + eye.fill.
P2 note: these are default-VALUE autoclosures (presentation constants, not behavioral guards) — they are
now EXECUTED (P1 satisfied); their value produces no observable difference in the no-rows tree (the
rubric's "presentation constants OUT of P2 scope"). The change-row timestamp's BEHAVIOR (the
`workbenchTimeText` seam) is already mutation-covered by the existing C0 clock tests + cross-TZ proof.
CARVED: none (driven to execution).

### BossConversationView (L5868-5912) — 6 → 6 driven, 0 carved
BEFORE: 6 uncovered (`5880` .onSubmit closure, `5881` its Task{}, `5885` Ask Button action, `5886` its
Task{}, `5898` quick-question Button action, `5899` its Task{}). Existing C3 tests RENDER the field +
quick-question titles but never INVOKE any action. Recipe: the `RunningSessionHeaderControlsDriveTests`
async-tap precedent — tap/callOnSubmit → the `Task {}` runs the async fn whose FIRST pre-await statement
is an observable synchronous effect; `await Task.yield()` loop lets it run, then assert.
DRIVEN via INVOCATION (async tests):
- `5885`/`5886` Ask: `find(button:"Ask").tap()` → `Task { await runBossQuestion() }`; `runBossQuestion`'s
  pre-await `setBossPaneCollapsed(false)` flips `state.bossPaneCollapsed` (started true). 
- `5880`/`5881` onSubmit: `find(TextField).callOnSubmit()` → same `runBossQuestion()` → same flip.
- `5898`/`5899` quick-question: `find(button:"What's Going On?").tap()` → `Task { await
  runBossQuickQuestion(item.question) }`; its pre-await `bossQuestion = resolved` overwrites the SENTINEL.
MUTATION: each inner `await model.run…()` → `_ = model` → ALL 3 tests RED (effects never fire) → revert
→ GREEN. (One mutation pass covered the 2 runBossQuestion callers + the quick-question caller.)
CARVED: none.

### BossProposalCardList + BossProposalCard + BossProposalItemRow (L7473-7617) — 7 → 6 driven, 1 carved
The plan's "BossProposalCardList: 7" = the whole proposal-card family (List 1 + Card 2 + ItemRow 4).
BEFORE: 7 uncovered (`7484` List `.task`; `7517` Dismiss, `7523` Approve; `7552` fieldBinding setter,
`7558` checkbox toggle, `7583` editable nil-detail `?? ""`, `7605` editable nil-cwd `?? ""`).
DRIVEN via INVOCATION (extends `BossProposalCardStateSetTests`):
- `7517` Dismiss: `find(button:"Dismiss").tap()` → `dismissProposal` → reload → `pendingProposals.isEmpty`.
  MUTATION: `model.dismissProposal(…)` → `_ = model` → RED → revert → GREEN.
- `7523` Approve: `find(button:"Approve").tap()` → `approveProposal` → reload → `pendingProposals.isEmpty`.
  MUTATION: `model.approveProposal(…)` → `_ = model` → RED → revert → GREEN.
- `7558` checkbox: `findAll(Button)[0].tap()` (the row checkbox is first) → `toggleProposalItem` flips
  `pendingProposals[0].items[0].selected` false→true. MUTATION: `model.toggleProposalItem(…)` → `_ = model`
  → RED → revert → GREEN.
- `7552` fieldBinding SETTER: an editable `.label` `TextField`; `setInput("Edited via binding")` routes
  through the binding `set:` → `editProposalItem` → `pendingProposals[0].items[0].label` changes.
  MUTATION: `set: { model.editProposalItem(…) }` → `set: { _ = $0 }` → RED → revert → GREEN.
- `7583`/`7605` editable nil detail/cwd `?? ""`: an item with `detail:nil, cwd:nil` + `editableFields:
  [.detail,.cwd]` → both bound TextFields built with the `?? ""` fallback → two EMPTY editable fields
  render (`kind=editable text=""` ≥2) + snapshot `F.fields.editableNilDetailCwd`. MUTATION: `?? ""` →
  `?? "MUT_DETAIL"`/`"MUT_CWD"` → empty-count drops to 0 + snapshot mismatch → RED → revert → GREEN.
CARVED (1): `7484` `BossProposalCardList` `.task { model.loadPendingProposals() }` — ViewInspector 0.10.3
has NO `.task` driver. --show-regions justified: `loadPendingProposals()` LOGIC is covered (every
`makeVM`/fixture calls it); only the `.task`-modifier hook is uncolorable. → Unit-3 allowlist carve.

### ActionLogView (L7782-7902, +init seam) — 14 → 14 driven, 0 carved
BEFORE: 14 uncovered (`7789`/`7790` timeZone/locale default-arg autoclosures, `7791` @State default,
`7793`/`7794` displayedEntries + `prefix(isExpanded?6:1)`, `7812`/`7813`/`7814`/`7823` the `else`
expanded VStack+ForEach, `7832` toggle Button action, `7835` `Label(isExpanded?…)`, `7839`
`.help(isExpanded?…)`). Existing C10 tests recorded the expanded arm as "structurally unreachable" — but
ViewInspector 0.10.3 + an `init(initialExpanded:)` @State seam DRIVE it.
SEAM ADDED (prod-default UNCHANGED): `init(entries:timeZone:locale:initialExpanded: Bool = false)`
(`_isExpanded = State(initialValue: initialExpanded)`). Every prod call site omits `initialExpanded` →
still starts collapsed, byte-identical. (C6 `ProviderConfigSheet(initialHumanName:)` precedent.)
DRIVEN:
- `7791` @State: replaced inline `= false` default with the init seam (the inline default's autoclosure
  region is GONE — preferred per brief over carving it).
- `7793`/`7794`/`7812`/`7813`/`7814`/`7823`/`7835`/`7839`: `initialExpanded: true` renders the expanded
  arm → chevron.up + all 6 `result*` rows + the `displayedEntries` computed var + `prefix(...?6...)` true
  branch + the `else` VStack/ForEach + the `Label`/`.help` `isExpanded` true ternaries. Snapshot
  `ActionLogView.expanded`. MUTATION: `prefix(isExpanded ? 6 : 1)` → `? 1 : 1` → expanded test + neg
  control RED (entries 1-5 missing + snapshot mismatch) → revert → GREEN.
- `7832` toggle Button action `isExpanded.toggle()`: `find(Button).tap()` EXECUTES the action (P1). The
  toggle's BEHAVIOR (collapsed↔expanded rendering) is mutation-verified by the expanded-arm snapshot +
  `testLog_negativeControl_expandedSelectionFlipsTree` (flipping `initialExpanded` flips the tree). The
  `@State` flip is view-internal (not observable via sync inspect) — region executed, behavior verified.
- `7789`/`7790` timeZone/locale default autoclosures: `testLog_productionDefaults_noTimeZoneOrLocaleArg`
  constructs `ActionLogView(entries:)` OMITTING both args (prod call shape) → the `.autoupdatingCurrent`
  defaults run; asserts the non-timestamp "Action Log"/"1 recent" labels render (no snapshot — the
  per-entry timestamp is `.autoupdatingCurrent`-locale, intentionally not pinned here).
CARVED: none.
