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
