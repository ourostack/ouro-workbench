# Doing: U2 — Per-Surface Snapshots (F ④ proposal card · A sidebar · B tab-strip)

**Status**: READY_FOR_EXECUTION
**Execution Mode**: spawn (one work-doer sub-agent per sub-unit; serialized merges into the branch; one commit per sub-unit)
**Created**: 2026-06-25 04:46
**Campaign / Planning**: ../2026-06-24-anneal-visual-testing.md  (the authoritative anneal journal — this doc is its U2 execution plan)
**U1 harness (the proven pattern to follow)**: Tests/OuroWorkbenchAppViewsTests/{AssertViewSnapshot,ViewSnapshotHost,ViewTreeSerializer,ViewSnapshotNode,ViewSnapshotStore}.swift + ViewSnapshotProofTests.swift
**Artifacts**: ./U2-surface-snapshots/
**Branch**: feat/anneal-u2-surface-snapshots (off origin/main @ 8e71619; journal+backlog @ b588b78). No PR (per brief).

---

## Execution Mode

- **spawn** — each sub-unit (PR-scoped) is driven by its own work-doer pass, strict TDD, one commit. The TimelineView source touch (SU0) is a real product-source change → it gets ≥2 adversarial reviewers (P5). Merges are serialized onto this branch (no PR; the campaign merges the branch later). NEVER run two build-lock-holding agents in one checkout (anneal SKILL §4: worktree-isolate / static-only / stagger).
- Why not `direct`: SU0 (product-source change, behavior-preservation proof) and SU1 (serializer/host hardening, AN-002) each warrant an isolated, individually-reviewable, revertible commit. Anneal demands "every fix is its own PR, independently revertible."

---

## Objective

Use the LIVE ViewInspector view-snapshot harness (`assertViewSnapshot(of:named:)`, on `main` @ 8e71619) to snapshot the REAL surfaces — F (④ proposal card), A (sidebar), B (tab-strip) — at their COMPLETE enumerated state-sets, each fixture provenance-built via the real seam, each surface with ≥1 negative control. This EXERCISES the real view bodies (growing coverage of `OuroWorkbenchAppViews`, toward the final coverage-gating unit U4 — but does NOT gate it this unit). Prerequisite: make the two `TimelineView`-embedded clock reads deterministic-in-tests without changing production behavior. Fold in the AN-002 serializer/host hardening. Resolve fork F1 (`.accessibilityIdentifier` strategy).

---

## Completion Criteria

- [ ] **SU0** — `TimelineView` injectable-clock source touch landed: both sites (`ElapsedTimePill` @ `WorkbenchViewsAndModel.swift:3775`, `DecisionInboxSheet` @ `:2166`) AND the `TerminalAgentRow` accessibility-label elapsed read (`:3718`) are deterministic-in-tests; **production behavior unchanged** (live app still ticks periodically), proven via a behavior test + the retained-`TimelineView` grep + a reviewer negative-control (NOTE: `--uisurfacetest` is a render-smoke control only — it asserts `fittingSize > 0`, NOT that prod still ticks; the ticking guarantee rests on the grep + negative-control — see H2). ≥2 adversarial reviewers, zero surviving CRITICAL/HIGH. **The elapsed seam (`ElapsedTimePill`/`:3718`) is EXERCISED + asserted deterministic by the standalone running-row leaf in SU3 (SU3r), NOT by the `WorkbenchSidebarView` surface — see C1 below.**
- [ ] **SU1** — AN-002 fixed in the host/serializer: editable `TextField` nodes serialize the BOUND VALUE (not the placeholder literal), and the `findAll` placeholder re-emission is de-duped. The existing ④ references re-recorded; a negative control proves an editable field's DATA-value regression is now caught.
- [ ] **SU2** — Surface F (④ proposal card) full enumerated state-set committed (list none/one/many; card 0/one/many items + counter none/some/all; itemRow selected×editable/static/absent per field). ≥1 negative control. Built via `AgentProposalQueue.enqueue`→VM.
- [ ] **SU3** — Surface A (sidebar) full enumerated state-set committed (empty / one / many / pinned-first / active-vs-inactive / empty-workspace-marker / summary idle-vs-needs-you / rename-in-progress; boundary pinned+active; custom-override). ≥1 negative control. Built via `WorkbenchStore.save`→VM. PLUS **SU3r** — a standalone `TerminalAgentRow(runningSince:)` LEAF snapshot (constructed directly, mirroring U1's `SidebarWorkspaceEmptyRow` leaf) that exercises the `ElapsedTimePill` + the `:3718` elapsed accessibility read with a fixed `startDate`/`runningSince` + injected `now`. **C1: the `WorkbenchSidebarView` surface itself does NOT render `ElapsedTimePill` — `TerminalAgentRow` is constructed in exactly one place (`:3010`) WITHOUT `runningSince:`, so via the sidebar seam `runningSince` is always nil. The elapsed substring is therefore asserted on the SU3r LEAF, not on the sidebar surface.** SU3r depends on **SU0** (the elapsed seam). The non-running sidebar states (SU3) do NOT depend on SU0.
- [ ] **SU4** — Surface B (tab-strip) full enumerated state-set committed (no-active-ws-nil / empty-ws "— no tabs yet" / filtered-to-empty "No sessions match…"+Clear / one / many / selected-vs-not / tab-rename). ≥1 negative control. Built via `WorkbenchStore.save`→VM. Independent of SU0 (no tab embeds an elapsed/clock read — VERIFIED) and of SU1; serialized after for merge order only.
- [ ] **F1 decision recorded**: `.accessibilityIdentifier` strategy = SELECTIVE, not a broad 121-view rollout (rationale below; recorded in Decisions Made + the campaign Decisions list).
- [ ] Every fixture provenance-built via the REAL seam (P2); NEVER hand-assembled. Each surface ≥1 negative control (P2).
- [ ] Determinism: fixed clock/locale/UUID; zero machine paths (P3). Twice-run byte-identical. No `/Users/…`, no `Date()`/`.now`/`UUID()` in any committed reference.
- [ ] AN-001 mitigation in EVERY VM fixture: inject a temp `agentBundlesURL` (via `BossWorkbenchMCPRegistrar(agentBundlesURL:)`) so tests never touch real `~/AgentBundles`.
- [ ] Snapshots non-redundant (P4e): no two committed references byte-identical.
- [ ] 100% test coverage on all NEW code (the harness-side helpers + the SU0 product seam). (Note: the VIEWS LIB is NOT added to `COVERAGE_DIRS` this unit — that is U4. SU0's new product source code, however, IS in the views lib and so is NOT gated yet; its coverage is exercised by the new snapshot tests + behavior test and will be picked up at U4. Record the running views-lib coverage % as surfaces land.)
- [ ] Gates: strict build/test `swift test -Xswiftc -warnings-as-errors -Xswiftc -strict-concurrency=complete` 0 warn / 0 fail (our products); `--uisurfacetest` green; `Scripts/check-coverage.sh` green (allowlist + `COVERAGE_DIRS` UNCHANGED this unit).
- [ ] One commit per sub-unit. NO AI attribution. `SerpentGuide.ouro/` never staged.
- [ ] All tests pass; no warnings.

## Code Coverage Requirements

**MANDATORY: 100% coverage on all NEW code** (harness-side helpers + any SU0 product seam logic, as exercised by the new tests).
- No `[ExcludeFromCodeCoverage]`-equivalent on new code.
- All branches covered (the `kind=editable/static` flip; nil/present field branches; each enumerated surface state).
- All error paths tested (ViewInspector traversal throw → reported as failure, not crash).
- Edge cases: empty list / single / many; nil vs present field; whitespace draft; filter-empty vs genuinely-empty.
- **Scope note (do NOT gate the views lib yet):** `COVERAGE_DIRS` stays `{OuroWorkbenchCore, OuroWorkbenchShellAdapter}`. The views lib joins it at U4 once enough surfaces are covered + the honest `@main`/`App`/`AppDelegate`/`TerminalPane` allowlist is built. U2 GROWS the snapshot coverage; record the running views-lib coverage % per surface (artifact: `./U2-surface-snapshots/views-coverage-after-SU<n>.txt`).

## TDD Requirements

**Strict TDD — no exceptions:**
1. **Tests first**: write the failing snapshot test / behavior test BEFORE any implementation (for snapshots: write the test asserting against a not-yet-recorded reference; confirm it FAILS to compile or RED before the view/serializer change; for SU0/SU1: classic red→green).
2. **Verify failure** (red).
3. **Minimal implementation** (green) — for snapshots, RECORD the reference (`OURO_SNAPSHOT_RECORD=1`) ONLY after eyeballing the tree is correct (provenance + no leak), then re-run in COMPARE mode.
4. **Verify pass** (green) + twice-run byte-identical + no machine-path scan.
5. **Refactor**, keep green.
6. **No skipping**: never record a reference without first verifying the tree is honest (provenance P2 + determinism P3); never implement without a failing test.

**Snapshot-record discipline (the P2 trap):** a recorded reference that asserts a state the real seam can't produce is a vacuous test. EVERY fixture goes through `AgentProposalQueue.enqueue`→VM (F) or `WorkbenchStore.save`→VM (A/B). Reviewer re-checks provenance (P2) + determinism (P3) per anneal P5.

---

## Pre-execution facts (validated against the codebase @ b588b78 — Validation Pass)

### The two `TimelineView` sites (re-located in the NEW file)
- `ElapsedTimePill` — **`Sources/OuroWorkbenchAppViews/WorkbenchViewsAndModel.swift:3771`** (struct), body `TimelineView(.periodic(from: .now, by: 30))` @ **`:3775`**, reads `context.date` → `WorkbenchElapsedFormatter.coarseDescription(since: startDate, now: context.date)` @ `:3776`. `var startDate: Date`. Internal. One call site: `TerminalAgentRow` @ `:3686` (`ElapsedTimePill(startDate: runningSince)`).
- `DecisionInboxSheet` — **`:2156`** (struct), body `TimelineView(.periodic(from: .now, by: 30))` @ **`:2166`** → `content(now: context.date)` @ `:2167` → `model.state.openInboxGroups(now: now)`. `@ObservedObject var model`. One call site @ `:441`.
- (The U1 `:2166`/`:3775` refs were said to be "in the OLD file"; in the CURRENT file at `b588b78` they coincide — re-validated above. The original campaign baseline `:3883` was the pre-extraction file.)

### THIRD wall-clock leak (NEW FORK — see Open Questions F-U2-CLOCK)
- **`TerminalAgentRow.accessibilityLabel` @ `:3718`** calls `ElapsedTimePill.coarseDescription(since: runningSince)` with the DEFAULT `now = Date()` (the static shim @ `:3791`, default `now: Date()`). Because `TerminalAgentRow` uses `.accessibilityElement(children: .ignore)` @ `:3696` + this computed `.accessibilityLabel(...)` @ `:3697`, ViewInspector reads THIS label string — which embeds a live-`Date()` elapsed substring (only when `runningSince != nil`). SU0's injectable clock MUST cover this site too.
- **C1 reachability correction (review gate):** this leak (and the `ElapsedTimePill` body) is ONLY reachable when `TerminalAgentRow` is built with a non-nil `runningSince`. But `TerminalAgentRow(` is constructed in EXACTLY ONE place — `:3010`, the sidebar Archived section — and that call does NOT pass `runningSince:` (it defaults nil @ `:3624`). `grep "runningSince:"` over the whole tree returns ONLY the property declaration: there is NO call site that assigns it. The VM's `runningStartDate(for:)` helper (`:14733`) that would derive it is DEAD (zero callers). **Therefore the `WorkbenchSidebarView` surface NEVER renders `ElapsedTimePill` and never takes the `:3718` elapsed branch.** Snapshotting the elapsed substring on the sidebar SURFACE would assert a state the real seam can't produce (a P2 §2b violation). Resolution: SU0's elapsed seam is exercised + asserted deterministic on a **standalone `TerminalAgentRow(runningSince:)` LEAF (SU3r)** — directly constructed, exactly as U1 snapshotted the `SidebarWorkspaceEmptyRow` leaf. (Directly instantiating a `View` via its own initializer is a legitimate seam — what P2 forbids is hand-assembling the serializer OUTPUT / model STATE, not instantiating a `View`. The `runningSince: Date` passed to the leaf is a fixed fixture value, the view's own input.)

### AN-002 bug locus (validated against the committed ④ references)
- Editable reference (`__Snapshots__/BossProposalCardList.editable.txt`) line 5-6:
  ```
  TextField kind=editable text="Label"   ← placeholder literal "Label", NOT the bound value "Restore terminal A"
  Text kind=static text="Label"          ← findAll RE-EMITS the placeholder as a separate Text node (the de-dup target)
  ```
  vs static line 5: `Text kind=static text="Restore terminal A"` (correct bound value).
- Root cause in **`ViewSnapshotHost.mapNode`** (`Tests/OuroWorkbenchAppViewsTests/ViewSnapshotHost.swift:72-80`): for a `TextField` it reads `textField.labelView().text().string(...)` (the PLACEHOLDER), not the bound value. And `extractNodes` uses `findAll(where:{true})` (`:47`) which enumerates the placeholder's inner `Text` AS A SEPARATE NODE → the duplicate emission. The view: `TextField("Label", text: fieldBinding(.label, current: item.label))` @ `:7395` — placeholder "Label", bound value `item.label`.
- **Consequence (the P4 gap):** a regression to an EDITABLE field's data value (`item.label` → wrong) does NOT change the snapshot (only "Label" + "Label" show). Static fields ARE caught. This is exactly AN-002.

### Surface F (④ proposal card) — view map
- `BossProposalCardList` @ `:7299` — **internal**, `@ObservedObject var model`. `.task { model.loadPendingProposals() }`. Renders `ForEach(model.pendingProposals, id: \.id) { BossProposalCard(...) }`; empty list → nothing. STATE DRIVER: `model.pendingProposals` cardinality (none/one/many).
- `BossProposalCard` @ `:7317` — **private**. `var proposal`, `@ObservedObject var model`, computed `selectedCount = proposal.items.filter(\.selected).count`. Nodes: `Image("checklist")`; `Text(proposal.title)`; `Text("\(selectedCount)/\(proposal.items.count)")` (COUNTER — none/some/all); `ForEach(proposal.items) { BossProposalItemRow }` (0/one/many); Buttons "Dismiss"/"Approve" with `.help(...)`.
- `BossProposalItemRow` @ `:7362` — **private**. `var proposalID`, `var item`, `@ObservedObject var model`, `isEditable(_:)`/`fieldBinding(_:current:)`. Checkbox `Image(item.selected ? "checkmark.circle.fill" : "circle")` + `.accessibilityLabel(item.selected ? "Selected" : "Not selected")`. Per field {label/detail/command/cwd}: `if isEditable(.X) { TextField("Placeholder", text: fieldBinding(.X, current: item.X)) } else if present { Text(item.X) }`. `.label` always renders (TextField or Text); detail/command/cwd are nil-skippable when static.
- Model: `AgentProposal{id,title,items}` + `AgentProposalItem{id,label,detail?,command?,cwd?,harness?,selected,editableFields:[Field]}`, `Field ∈ {label,detail,command,cwd}` (`Sources/OuroWorkbenchCore/AgentProposal.swift`). **`editableFields` defaults to `Field.allCases`** (all editable) in the memberwise init — so a default-constructed item is FULLY editable; pass `editableFields: []` for fully-static. Seam: `AgentProposalQueue.enqueue(_ proposal) throws` (`AgentProposalQueue.swift:46`).

### Surface A (sidebar) — view map
- `WorkbenchSidebarView` @ `:2917` — **public**, `init(model:)`. Reads `model.workspaceSidebarModel.rows`, `model.archivedSessionEntries`, `model.recoveryDigest`, `model.ouroAgents`, filter state. Sections: Agents (empty→"Create Your First Agent" / non-empty→rows+"Create Agent"+"Clone from Git…"), Workspaces (rows→`WorkspaceSidebarRow` + "New Terminal"), Archived (gated `!archivedSessionEntries.isEmpty`→`TerminalAgentRow`s), Recovery (policy-gated).
- `WorkspaceSidebarRow` @ `:3061` — **internal**, `var row`, `@ObservedObject var model`. Rename mode → `InlineRenameEditor`; else `rowButton`: `Image(pin.fill / square.stack.3d.up[.fill])`, `Text(row.effectiveName)`, health `Image(summary.healthSymbol)` when `summary != .idle`, `.accessibilityElement(children: .ignore)` + computed `.accessibilityLabel` (name, active/workspace, [pinned], N tabs, [health/needs you]).
- `SidebarWorkspaceEmptyRow` @ `:3183` — **internal**, no props. `Text("No tabs yet")` + `.accessibilityLabel("No tabs yet")`. **NOTE:** NOT referenced inside `WorkbenchSidebarView` (the U1 proof snapshotted it standalone). The sidebar's empty markers come from the seam rows; keep it as a standalone leaf snapshot (already proven in U1) — do NOT claim it covers the sidebar empty-state.
- `TerminalAgentRow` @ `:3609` — **internal**. Embeds `ElapsedTimePill(startDate: runningSince)` @ `:3686` when `runningSince != nil`. `.accessibilityElement(children: .ignore)` @ `:3696` + computed `.accessibilityLabel` @ `:3697` (which reads the elapsed via `:3718` — the THIRD leak). **BUT (C1): the sole construction at `:3010` omits `runningSince:` → nil via the sidebar; the elapsed pill/branch is unreachable through the surface and is exercised only by the SU3r standalone leaf.**
- `ElapsedTimePill` @ `:3771` — the clock site (above).

### Surface B (tab-strip) — view map
- `WorkspaceTabStrip` @ `:3201` — **public**, `init(model:)`. `model.activeWorkspaceRow` nil → renders NOTHING. Else: `filterHidAll` (Core `stripFilterHidAllTabs`) → `stripFilterEmptyState` (Label `SidebarFilterPresentation.emptyStateTitle(query:)` + Button "Clear"); `filtered.isEmpty` → `Text("\(active.effectiveName) — no tabs yet")`; else `ForEach(filtered) { tabButton }`. Container `.accessibilityElement(children: .contain)` + `.accessibilityLabel("Tabs in \(active.effectiveName)")`.
- `tabButton` @ `:3290` — rename mode → `InlineRenameEditor`; else Button: `Image(tab.attention.healthSymbol)`, `Text(tab.effectiveTabName)`, `.help(tab.attention.healthLabel)`, `.accessibilityLabel("\(tab.effectiveTabName), \(tab.attention.healthLabel)\(isSelected ? ", selected" : "")")`.
- `InlineRenameEditor` @ `:3163` — **internal**, `@ObservedObject var model`. `TextField("Name", text: $model.inlineRename.draft)`, `Text("Press Enter to rename, Escape to cancel.")`, `.accessibilityLabel("Rename")`. **NOTE: NO elapsed/clock read → tab-strip does NOT depend on SU0** for determinism (no `runningSince`/`Date()` leak). It still serializes after SU0 in the merge order, but it is technically parallelizable.

### Accessibility convention (fork F1 evidence)
- **0** `.accessibilityIdentifier(` in the entire views lib. **25** `.accessibilityLabel(` MODIFIER calls (hardcoded affordances + computed multi-facet descriptions + interpolated container labels), plus 3 `var accessibilityLabel` computed-property declarations (an earlier "26" count conflated these — L1). The codebase has a strong, consistent `accessibilityLabel` convention and ZERO identifier precedent. Each repeated row (workspace rows, tabs, sessions) ALREADY carries a semantically-distinct computed `accessibilityLabel` (name/active/pinned/tab-count/health), so node identity is NOT ambiguous in the serialized tree without identifiers.

### Determinism + provenance facts
- VM seam: `WorkbenchViewModel.init(paths:…, bossWorkbenchMCPRegistrar:…)` (`:11082`). AN-001 mitigation: pass `BossWorkbenchMCPRegistrar(agentBundlesURL: tmp/AgentBundles)` (the `:11129` `sweepStaleWorkbenchBundlesOnLaunch`→detached `cleanupAllAgents()` @ `:14145` runs against the registrar's `agentBundlesURL`, default home `BossAgentBridge.swift:173`).
- A/B provenance: `WorkbenchStore.save(_ state)` (`WorkbenchStore.swift:207`) → write a `WorkspaceState` (with `ProcessRun{startedAt: <fixed Date>}`, `WorkspaceModels.swift:379`) → new VM loads it. (`latestRun(for:)` @ `:14722` resolves a session's latest run; the `runningStartDate(for:)` helper @ `:14733` that would derive a row's `runningSince` is DEAD — zero callers — so the sidebar surface does NOT surface elapsed; SU3r uses a directly-constructed leaf with a fixed `runningSince` instead.)
- SU3r leaf provenance note: `TerminalAgentRow(entry:isSelected:runningSince:…)` is constructed directly with a provenance-built `ProcessEntry` (or a minimal fixed `entry`) + a fixed `runningSince: Date` + injected `now`. This is the view's own initializer seam (legitimate — like the U1 `SidebarWorkspaceEmptyRow`/`DashboardRowLabel` leaves); no serializer output or model state is hand-assembled.
- Locale: host reads through `Locale(identifier: "en_US_POSIX")` via `Text.string(locale:)` (`ViewSnapshotHost.swift:31,38`). Store resolves `__Snapshots__/` relative to `#filePath` (no machine path baked in).
- `--uisurfacetest`: `Sources/OuroWorkbenchApp/UISurfaceTest.swift` renders `WorkbenchSidebarView` + `WorkspaceTabStrip` (the surfaces that embed `ElapsedTimePill`) via `fittingSize(...)` → a real behavior-preservation surface for SU0.

---

## Decisions Made

- **D-U2-1 — Injectable clock seam, defaulting to live `.now`/`TimelineView`-fed; fixed in tests. Two candidate mechanisms, resolved empirically in SU0a.** Prod behavior is preserved either way: in the app the `TimelineView` keeps driving `context.date`; in tests a fixed `Date` is injected. Must cover ALL THREE leak sites (pill body, inbox body, `TerminalAgentRow` accessibility-label elapsed read `:3718`). **Candidate A — `@Environment` date-source**: one seam, reaches `body`-evaluated views; BUT (M1, important) the `:3718` site is a plain computed-property `String` read (`accessibilityLabel` var calls the static shim with `now: Date()` default) evaluated OUTSIDE SwiftUI `body` resolution, so an `@Environment` value almost certainly CANNOT reach it (and ViewInspector #317/L7 — env may not reach `find()`-descended nodes). **Candidate B — init-param `now: Date? = nil`** threaded from `TerminalAgentRow` into both `ElapsedTimePill(startDate:now:)` AND the `accessibilityLabel` shim call. **Pre-bias: Candidate B (init-param) is the likely survivor BECAUSE of the `:3718` computed-label site** — `@Environment` cannot deterministically pin a computed-property `Date()` read. SU0a confirms empirically; either way prod default = live clock. (The one design fork SU0's planner resolves in its spike; see Open Questions.)
- **D-U2-2 (F1 RESOLVED) — `.accessibilityIdentifier` = SELECTIVE, NOT a broad 121-view rollout.** Rationale: (a) the harness already captures `Text`/`Image` content + structure + `accessibilityLabel`, so copy edits SHOULD change snapshots (those are real regressions to catch — an identifier-only tree would MASK copy regressions); (b) the codebase has 0 identifiers and 25 semantic-label modifier calls — a 121-view identifier rollout is a giant brittle source change against zero precedent; (c) every repeated row already carries a distinct computed `accessibilityLabel` → node identity is unambiguous WITHOUT identifiers. **Policy: add `.accessibilityIdentifier` ONLY where two serialized nodes would otherwise be byte-identical AND that ambiguity defeats a negative control** (genuinely-identical repeated rows with no distinguishing label/content). Audit each surface during its sub-unit; if NO ambiguity is found, add ZERO identifiers and record "none needed." Supersedes the campaign's earlier "broad `.accessibilityIdentifier` rollout" intake phrasing.
- **D-U2-3 — AN-002 fix lives in `ViewSnapshotHost` (+ `ViewSnapshotNode` if a new field is needed), NOT the product views.** The bound value is read from the `TextField`'s `text` binding via ViewInspector's `textField().input()` (the bound `Binding<String>` content), and the `findAll` placeholder re-emission is de-duped by NOT mapping a `Text` that is the inner label-view of an already-mapped `TextField` (track placeholder-Text identities and skip them; or switch the `TextField` mapping to read `input()` and drop `labelView().text()` mapping for that node's child). Test-only blast radius (P4 fidelity), no product touch.
- **D-U2-4 — Fixtures via the real seam, hermetic.** F via `AgentProposalQueue.enqueue`→VM (the U1 proof pattern). A/B via `WorkbenchStore.save(state)`→fresh VM. EVERY VM gets a temp `agentBundlesURL` (AN-001). Fixed `ProcessRun.startedAt`, fixed injected `now`, `en_US_POSIX`, no `UUID()` in serialized content.
- **D-U2-5 — Coverage NOT gated this unit.** `COVERAGE_DIRS` + allowlist UNCHANGED. SU0's new product source is in the (ungated) views lib; its coverage is exercised by the new tests and folded into the U4 gate. Record running views-lib coverage % per surface as an artifact.
- **D-U2-6 — `SidebarWorkspaceEmptyRow` standalone snapshot is NOT the sidebar empty-state.** It is a VM-free leaf already proven in U1; the real sidebar empty-state is an enumerated state of `WorkbenchSidebarView` (SU3). Do not double-count.

---

## Sub-unit decomposition (PR-scoped) + dependency graph

```
SU0 (TimelineView injectable clock — PRODUCT SOURCE; ≥2 reviewers)
 └─► SU3r (standalone TerminalAgentRow leaf — the ONLY place the elapsed seam
            is exercised+asserted; the sidebar surface never renders it)  ── DEPENDS ON SU0
      (SU0 ALSO forward-serves U3's DecisionInboxSheet surface — out of U2 scope)
SU3 (Sidebar A surface — NON-running states only; NO ElapsedTimePill via the seam) ── independent of SU0
SU1 (AN-002 host/serializer hardening — TEST-ONLY)
 └─► SU2 (Surface F ④ — editable fields are where AN-002 matters)        ── DEPENDS ON SU1
SU4 (Tab-strip B)  ── independent of SU0/SU1 (no clock, no editable-field value) ; serialized last for merge order
```

Critical path: **SU0 → SU3r** (the product-source change gates ONLY the standalone running-row leaf — NOT the whole sidebar; the `WorkbenchSidebarView` surface renders no `ElapsedTimePill` via the real seam, C1) and **SU1 → SU2** (the fidelity fix gates the ④ value-bearing snapshots). The sidebar non-running states (SU3) and the tab-strip (SU4) are independent of SU0. Merge order on-branch: SU0, SU1, SU2, SU3 (incl. SU3r), SU4 (SU0/SU1 first because the dependent units build on them; reviewers staggered, never two build-lock holders in one checkout).

---

## SU0 — TimelineView injectable clock (PRODUCT SOURCE; the named prerequisite)

The injectable-clock design (D-U2-1). Goal: make `context.date`/elapsed reads deterministic in tests at ALL THREE leak sites WITHOUT changing production behavior. Its own commit; ≥2 adversarial reviewers (first product-source change).

### ⬜ Unit SU0a: Clock-seam spike (make-or-break design resolution)
**What**: Empirically resolve the D-U2-1 fork. **Pre-bias toward Candidate B (init-param `now: Date? = nil`)** because the `:3718` site is a computed-property `String` read of `Date()` evaluated outside SwiftUI `body` resolution — an `@Environment` value cannot deterministically pin it (M1). In a throwaway test, confirm: (i) does Candidate A (`@Environment` date-source) reach the `TimelineView`-closure-rendered pill `Text` under ViewInspector `findAll()`? (ii) Can ANY mechanism deterministically pin the `:3718` computed `accessibilityLabel` elapsed read EXCEPT threading an init-param `now` into the shim call? (Almost certainly not — so the label site forces Candidate B regardless of what the pill body allows.) Adopt the mechanism that pins BOTH sites with one consistent seam — expected: init-param `now` threaded `TerminalAgentRow → ElapsedTimePill(startDate:now:)` + the `accessibilityLabel` shim call. Either way the PROD default is the live clock (`nil`/default → `Date()`/`TimelineView`).
**Output**: `./U2-surface-snapshots/clock-seam-spike.md` recording the chosen seam + evidence (which site forced which choice); the throwaway test deleted.
**Acceptance**: A documented GO with the chosen mechanism; the chosen mechanism demonstrably yields a deterministic elapsed string for BOTH the pill body AND the `:3718` computed label, for a fixed `startDate` + injected `now`, under `inspect()`/`findAll()` against a standalone `TerminalAgentRow(runningSince:)` leaf.

### ⬜ Unit SU0b: Behavior-preservation tests — FIRST (red)
**What**: Write FAILING tests proving (1) production default still uses the live clock (the source-default path is unchanged: `ElapsedTimePill` with no injected now formats against "now"; `DecisionInboxSheet` groups against "now"); (2) the injected-now path yields the fixed elapsed string. **H2 note:** the ticking guarantee does NOT come from `--uisurfacetest` (it only asserts `fittingSize > 0` = render-without-crash; it never constructs a running session, never reads `ElapsedTimePill`, asserts nothing about periodic ticking). The ticking guarantee = (a) the SU0c grep that `TimelineView(.periodic(from:.now,…))` is RETAINED at both sites + (b) the SU0d reviewer negative-control ("revert the default to a fixed date ⇒ the live app would stop ticking"). Still include a render-smoke assertion that `WorkbenchSidebarView`/`WorkspaceTabStrip` fit positively — as a regression control ONLY, not the ticking proof.
**Acceptance**: Tests exist and FAIL (red) — the seam doesn't exist yet.

### ⬜ Unit SU0c: Implement the injectable seam (green) — minimal product touch
**What**: Add the date-source seam (env-value with a default that reads the live `.now`/`TimelineView` `context.date`, OR the init-param fallback per SU0a). Thread it to ALL THREE sites: `ElapsedTimePill` body (`:3775`), `DecisionInboxSheet` body (`:2166`), `TerminalAgentRow.accessibilityLabel` elapsed read (`:3718`). PROD behavior identical: the `TimelineView` still drives periodic updates; the default source = live clock. Make the smallest possible change; do NOT refactor unrelated code.
**Acceptance**: SU0b tests PASS (green); `--uisurfacetest` green; strict build/test 0 warn/fail; `grep` confirms the `TimelineView(.periodic(from: .now,…))` periodic driver is RETAINED at both sites (prod still ticks).

### ⬜ Unit SU0d: Coverage + commit + review
**What**: Verify 100% coverage on the new seam code paths (both default-live and injected branches exercised). Capture running views-lib coverage % (`./U2-surface-snapshots/views-coverage-after-SU0.txt`). Commit `feat(views): SU0 injectable test-clock at ElapsedTimePill/DecisionInboxSheet/TerminalAgentRow (prod default = live clock)` — NO AI attribution. Stage NOTHING else (`SerpentGuide.ouro/` untouched). Run ≥2 adversarial reviewers (one may be static-only to avoid build-lock contention); zero surviving CRITICAL/HIGH (esp. "does prod behavior actually change?" — the negative-control is: revert the default to a fixed date and prove the live app would stop ticking → confirms the default is genuinely live).
**Acceptance**: Commit landed; both reviewers SAFE; all gates green.

---

## SU1 — AN-002 host/serializer hardening (TEST-ONLY)

Fix the editable-field fidelity gap (D-U2-3). Its own commit. Test-only blast radius.

### ⬜ Unit SU1a: AN-002 negative-control test — FIRST (red)
**What**: Write a FAILING test: a provenance-built ④ fixture with `editableFields: [.label]` and TWO DIFFERENT `item.label` values must produce DIFFERENT serialized trees (today they don't — both show placeholder "Label"). Also assert NO duplicate placeholder `Text` node is emitted for an editable field.
**Acceptance**: Test exists and FAILS (red) — proves AN-002 is real (editable data-value regression currently uncaught + duplicate emission present).

### ⬜ Unit SU1b: Fix the host (green)
**What**: In `ViewSnapshotHost.mapNode`/`extractNodes`: read the `TextField`'s BOUND VALUE (via ViewInspector `textField().input()` — VALIDATED present at `.build/checkouts/ViewInspector/Sources/ViewInspector/SwiftUI/TextField.swift:96`, returns `inputBinding().wrappedValue` = the `Binding<String>` value, e.g. `item.label`) as the editable node's `text` (keep the placeholder available only if needed as a distinct, clearly-named field — prefer bound value as `text`), and DE-DUP the `findAll` placeholder re-emission (do not map the placeholder's inner label `Text` as a separate node). Keep `kind=editable` for the `TextField`. Note: the existing `try? view.textField()` narrows the `ClassifiedView` to `InspectableView<ViewType.TextField>`, which is exactly where `.input()` is available. Minimal change; no product touch.
**Acceptance**: SU1a test PASSES (green); editable trees now carry the bound value; no duplicate node; the existing `kind=editable`↔`kind=static` flip still works.

### ⬜ Unit SU1c: Re-record ④ references + coverage + commit
**What**: Re-record `__Snapshots__/BossProposalCardList.editable.txt` (now showing `text="Restore terminal A"` not "Label", no dup) after eyeballing correctness; re-run COMPARE green + twice-run byte-identical + no `/Users/` leak. Verify 100% coverage on the changed host paths. Update the U1 `ViewSnapshotProofTests` negative control if its assertion text (`kind=static text="Restore terminal A"`) needs the editable analogue. Commit `fix(test-harness): AN-002 — serialize TextField bound value + de-dup placeholder re-emission`. NO AI attribution.
**Acceptance**: All ④ snapshot tests green; references reflect bound values; commit landed; AN-002 marked fixed in the campaign backlog.

---

## SU2 — Surface F (④ proposal card) full enumerated state-set

DEPENDS ON SU1 (editable fields are where AN-002 matters). Builds on the U1 ④ proof pattern. Provenance via `AgentProposalQueue.enqueue`→VM; hermetic registrar (AN-001).

### ⬜ Unit SU2a: F state-set tests — FIRST (red)
**What**: Write FAILING `assertViewSnapshot` tests for the COMPLETE F state-set (each a provenance-built fixture):
- LIST: `none` (no proposals → empty tree); `one`; `many` (≥2 cards).
- CARD items: `0` (empty `items`); `one`; `many`.
- COUNTER: `none` selected (0/N); `some` (k/N); `all` (N/N).
- ITEMROW selected: `selected` vs `not`.
- ITEMROW per-field × editable/static/absent: for each of label/detail/command/cwd → `editable` (in `editableFields`), `static` (present, not editable), `absent` (nil + not editable). (`.label` is never absent.)
- Choose the MINIMAL non-redundant set that covers every enumerated state (P4c) with NO two byte-identical references (P4e) — e.g. fold several field-states into a few rich fixtures rather than one-snapshot-per-cell, documenting the coverage mapping.
**Acceptance**: Tests exist and FAIL (no references yet, red).

### ⬜ Unit SU2b: Record + verify F references (green)
**What**: Record each reference (`OURO_SNAPSHOT_RECORD=1`) ONLY after eyeballing provenance + no leak; re-run COMPARE green. Add the F NEGATIVE CONTROL: a fixture mutation (e.g. flip `selected`, change a bound editable value now that AN-002 is fixed, drop an item) flips the asserted tree. Twice-run byte-identical; no `/Users/`.
**Acceptance**: All F references committed + COMPARE green; ≥1 negative control flips; no two F references byte-identical.

### ⬜ Unit SU2c: F a11y-id audit + coverage + commit
**What**: Audit F for node-identity ambiguity (D-U2-2): do any two serialized nodes collide such that a negative control is defeated? If yes, add the MINIMAL `.accessibilityIdentifier`(s); if no, record "none needed." Capture views-lib coverage % (`views-coverage-after-SU2.txt`). Commit `test(views): SU2 surface F (④ proposal card) enumerated snapshots + negative control`. NO AI attribution.
**Acceptance**: Coverage % recorded; a11y-id decision recorded; commit landed; gates green.

---

## SU3 — Surface A (sidebar) full enumerated state-set

SU3 (the `WorkbenchSidebarView` SURFACE) is INDEPENDENT of SU0 — via the real seam the sidebar never renders `ElapsedTimePill` (C1: `runningSince` is always nil through `:3010`), so its tree carries no clock substring. The elapsed seam is exercised separately by **SU3r** (the standalone leaf), which DEPENDS ON SU0. Provenance via `WorkbenchStore.save`→VM; hermetic registrar (AN-001).

### ⬜ Unit SU3a: A SURFACE state-set tests — FIRST (red)
**What**: Write FAILING `assertViewSnapshot` tests for the COMPLETE A state-set on `WorkbenchSidebarView` (each provenance-built via `WorkbenchStore.save`):
- empty (no agents, no workspaces); one workspace; many workspaces.
- pinned-first ordering (pinned row sorts above unpinned); active-vs-inactive (icon/label differ).
- empty-workspace marker; summary idle-vs-needs-you (health glyph + "needs you" label).
- rename-in-progress (`InlineRenameEditor` swapped in for a row).
- BOUNDARY: pinned+active (both flags); custom-override present — the driver is `WorkspaceRow.nameOverride != nil` (it enables "Remove Custom Workspace Name" in `WorkspaceRowContextMenu` @ `:3127`). Context menus are NOT in the ViewInspector inspected tree, so assert the ROW STATE via the saved `WorkspaceState`'s name-override field (NOT the menu item); do NOT attempt to snapshot the menu.
- (NO running-session bullet here — the sidebar surface cannot produce an elapsed substring via the seam; that state lives in SU3r.)
**Acceptance**: Tests exist and FAIL (red).

### ⬜ Unit SU3b: Record + verify A SURFACE references (green)
**What**: Record after eyeballing; COMPARE green. NEGATIVE CONTROL: mutate the saved `WorkspaceState` (rename a workspace, toggle pin, set/clear `nameOverride`) → the tree flips. Twice-run byte-identical; **assert NO `Date()`-derived non-fixed substring anywhere in the sidebar reference** (the sidebar should carry none — a defense-in-depth check that the surface is genuinely clock-free); no `/Users/`.
**Acceptance**: All A surface references committed + COMPARE green; ≥1 negative control flips; sidebar references are clock-free.

### ⬜ Unit SU3r: Standalone `TerminalAgentRow(runningSince:)` LEAF — the elapsed-seam snapshot (DEPENDS ON SU0)
**What**: TDD a standalone leaf snapshot of `TerminalAgentRow` constructed DIRECTLY (mirroring U1's `SidebarWorkspaceEmptyRow`/`DashboardRowLabel` leaves) with a fixed `runningSince: Date` + the SU0 injected `now`, so the `ElapsedTimePill` body AND the `:3718` `accessibilityLabel` elapsed substring render. Write the FAILING test first (no reference yet), then record after eyeballing the elapsed string is the FIXED expected value (e.g. "5m") and there is NO live-`Date()` drift. NEGATIVE CONTROL: change the injected `now` (or `runningSince`) → the elapsed substring flips deterministically; and INVERT the SU0 seam (default-live instead of injected) → the elapsed substring becomes a live wall-clock value (proving the seam is load-bearing and SU0 actually closed the leak). Use a minimal fixed `ProcessEntry` fixture (the row's own input; a `View` initializer is a legitimate seam — P2 forbids hand-assembling serializer output/model state, not instantiating a `View`). Twice-run byte-identical; no `/Users/`.
**Output**: `__Snapshots__/TerminalAgentRow.running.txt` (+ a second injected-`now` variant for the negative control if non-redundant).
**Acceptance**: Leaf reference committed + COMPARE green; the elapsed substring is the fixed expected value (no `Date()` drift); the SU0-seam-inversion negative control flips to a live value; twice-run byte-identical.

### ⬜ Unit SU3c: A a11y-id audit + coverage + commit
**What**: Audit A (surface + SU3r leaf) for node-identity ambiguity (repeated workspace/session rows) — verify the existing computed `accessibilityLabel` disambiguates; add MINIMAL identifiers only if a negative control is defeated, else "none needed." Capture views-lib coverage % (`views-coverage-after-SU3.txt`). Commit `test(views): SU3 surface A (sidebar) + SU3r running-row leaf snapshots + negative controls`. NO AI attribution.
**Acceptance**: Coverage % recorded; a11y-id decision recorded; commit landed; gates green.

---

## SU4 — Surface B (tab-strip) full enumerated state-set

Independent of SU0/SU1 (no clock read, no editable-field bound value); serialized last for merge order. Provenance via `WorkbenchStore.save`→VM; hermetic registrar (AN-001).

### ⬜ Unit SU4a: B state-set tests — FIRST (red)
**What**: Write FAILING `assertViewSnapshot` tests for the COMPLETE B state-set on `WorkspaceTabStrip`:
- no-active-ws (`activeWorkspaceRow == nil` → renders nothing → empty tree).
- empty-ws "— no tabs yet" (`active.effectiveName — no tabs yet`).
- filtered-to-empty "No sessions match…" + "Clear" (`filterHidAll` true: active filter hides all of a non-empty workspace — the FP4 boundary, DISTINCT from genuinely-empty).
- one tab; many tabs.
- selected-vs-not (label gains ", selected").
- tab-rename (`InlineRenameEditor` swapped for a tab).
- BOUNDARY (FP4): filter-empty vs genuinely-empty are two DISTINCT references (not byte-identical).
**Acceptance**: Tests exist and FAIL (red).

### ⬜ Unit SU4b: Record + verify B references (green)
**What**: Record after eyeballing; COMPARE green. NEGATIVE CONTROL: change the filter so `filterHidAll` flips, or select a different tab → tree flips. Assert filter-empty ≠ genuinely-empty (P4e). Twice-run byte-identical; no `/Users/`.
**Acceptance**: All B references committed + COMPARE green; ≥1 negative control flips; the two empty-states are distinct.

### ⬜ Unit SU4c: B a11y-id audit + coverage + commit + unit close
**What**: Audit B for node-identity ambiguity (repeated tabs) — verify the per-tab `accessibilityLabel` disambiguates; minimal identifiers only if needed, else "none needed." Capture FINAL views-lib coverage % (`views-coverage-after-SU4.txt`). Commit `test(views): SU4 surface B (tab-strip) enumerated snapshots + negative control`. Update the campaign journal + backlog (AN-002 → fixed; note running coverage %; surface any new fork). NO AI attribution.
**Acceptance**: Coverage % recorded; a11y-id decision recorded; commit landed; gates green; campaign doc updated.

---

## Execution

- **TDD strictly enforced**: tests → red → implement/record → green → refactor. For snapshots, RECORD a reference only after eyeballing provenance (P2) + no machine-path/clock/UUID leak (P3).
- Commit after each sub-unit's final phase (SU0d, SU1c, SU2c, SU3c, SU4c). One commit per sub-unit (the intermediate a/b/c phases of a sub-unit may co-commit at the sub-unit boundary, but never batch across sub-units).
- No PR (per brief); the branch is merged later by the campaign.
- Run the full strict suite + `--uisurfacetest` + `check-coverage.sh` before marking each sub-unit done.
- **All artifacts** → `./U2-surface-snapshots/` (spikes, coverage snapshots, review records).
- **Fixes/blockers**: spawn a sub-agent immediately — don't ask, just do it (operator asleep). Record the decision in this doc + the campaign journal, commit right away.
- **Reviewer discipline (anneal §4)**: never run two build-lock-holding agents in one checkout — worktree-isolate, or make all-but-one reviewer static-only, or stagger.
- **AN-001 in EVERY VM fixture**: temp `agentBundlesURL` via `BossWorkbenchMCPRegistrar(agentBundlesURL:)`.
- **SerpentGuide.ouro/ stays unstaged. NO AI attribution anywhere.**

---

## Open Questions

- [ ] **F-U2-CLOCK (resolved-by-SU0a; pre-biased to init-param)** — `@Environment` date-source vs init-param `now`. **Pre-bias: init-param `now`** — the `:3718` site is a computed-property `String` read of `Date()` outside SwiftUI `body` resolution, which an `@Environment` value cannot deterministically pin (M1); the label site forces the init-param seam regardless of what the pill body allows. SU0a confirms empirically. Either way prod default = live clock. **TWO NEW FORKS surfaced to the campaign**: (1) the THIRD leak (`TerminalAgentRow.accessibilityLabel` @ `:3718`, NOT inside a `TimelineView`) — SU0 is broader than the campaign's "two-site" intake; (2) **C1 — that leak (and the `ElapsedTimePill` body) is UNREACHABLE through the `WorkbenchSidebarView` real seam** (`runningSince` never assigned at the sole `TerminalAgentRow` call site `:3010`; the `runningStartDate(for:)` derivation helper `:14733` is DEAD) → the elapsed snapshot lives on a standalone `TerminalAgentRow` leaf (SU3r), NOT the sidebar surface. (Possible product-cleanup backlog item for the campaign: the dead `runningStartDate(for:)` helper + the unwired `runningSince` — i.e. the sidebar may have been INTENDED to show elapsed pills but never wired it. NOT a U2 rubric violation; surface to the campaign as an observation, do not fix here.)
- [ ] **F-state-set minimality** — the per-field × editable/static/absent matrix is 4 fields × 3 states = 12 cells; SU2a folds them into a MINIMAL non-redundant fixture set with a documented coverage mapping (avoid 12 near-identical snapshots; P4e + P4b). Resolved within SU2a by the doer (reversible: more fixtures if a cell is uncovered).
- [ ] **Context-menu reachability (L2)** — the "Remove Custom Workspace Name" (custom-override boundary) lives in a `.contextMenu` (`WorkspaceRowContextMenu` @ `:3127`, gated `if row.nameOverride != nil`) which is NOT in the ViewInspector inspected tree. SU3a default: assert the ROW STATE driver (`WorkspaceRow.nameOverride != nil` via the saved `WorkspaceState`) rather than the menu item. Do NOT attempt to snapshot the menu. Reversible.

## Context / References

- Campaign journal + rubric (P1–P7) + surface state-sets + backlog (AN-001/AN-002): `../2026-06-24-anneal-visual-testing.md`.
- anneal SKILL (loop, guardrails, P5 review gate, build-lock lesson): `~/.claude/skills/anneal/SKILL.md`.
- U1 harness (the proven ViewInspector pattern): `Tests/OuroWorkbenchAppViewsTests/{AssertViewSnapshot,ViewSnapshotHost,ViewTreeSerializer,ViewSnapshotNode,ViewSnapshotStore}.swift`; the working ④ proof + negative control: `…/ViewSnapshotProofTests.swift`; committed refs: `…/__Snapshots__/{BossProposalCardList.editable,BossProposalCardList.static,DashboardRowLabel.default,SidebarWorkspaceEmptyRow.default}.txt`.
- U1 records (ViewInspector necessity, #317/L7 env-vs-string, L8/AN-001): `…/U1-ax-snapshot-harness/{viewinspector-spike,review-gate-viewinspector,mirror-viability-spike}.md`.
- Product source (all line refs validated @ b588b78): `Sources/OuroWorkbenchAppViews/WorkbenchViewsAndModel.swift` (TimelineView `:2166`/`:3775`; elapsed a11y leak `:3718`; F `:7299/:7317/:7362`; A `:2917/:3061/:3183/:3609/:3771`; B `:3163/:3201/:3290`); model `Sources/OuroWorkbenchCore/AgentProposal.swift`; seam `AgentProposalQueue.swift:46`, `WorkbenchStore.swift:207`; registrar default `BossAgentBridge.swift:173`.
- Coverage gate (UNCHANGED this unit): `Scripts/check-coverage.sh` (`COVERAGE_DIRS` = Core + ShellAdapter; allowlist `scripts/coverage-allowlist.txt`). `--uisurfacetest`: `Sources/OuroWorkbenchApp/{main.swift:36,UISurfaceTest.swift}`.
- Package.swift test-target (ViewInspector exact `0.10.3`, `exclude: ["__Snapshots__"]`): `Package.swift:88-100`.

## Notes

- The third wall-clock leak (`TerminalAgentRow.accessibilityLabel` @ `:3718`) is a key U2 discovery beyond the brief: the campaign's "two TimelineView sites" intake undercounts it. SU0 is scoped to cover all three (the init-param seam threads `now` from `TerminalAgentRow` to both the pill and the label, live-by-default).
- **C1 (review-gate correction): that elapsed leak is UNREACHABLE through the `WorkbenchSidebarView` real seam.** `TerminalAgentRow` is constructed in exactly one place (`:3010`) WITHOUT `runningSince:`; the only `runningSince:` occurrence is the property declaration (`:3624`); the `runningStartDate(for:)` helper (`:14733`) that would derive it has ZERO callers (dead). So the sidebar SURFACE never renders `ElapsedTimePill` — asserting the elapsed substring on the surface would assert a state the real seam can't produce (P2 §2b). The elapsed seam is therefore exercised + asserted deterministic on a STANDALONE `TerminalAgentRow(runningSince:)` leaf (SU3r), exactly as U1 snapshotted the `SidebarWorkspaceEmptyRow` leaf. Observation for the campaign (not a U2 fix): the unwired `runningSince` + dead helper suggest the sidebar elapsed-pill was intended but never wired.
- `editableFields` defaults to `Field.allCases` — a default-constructed `AgentProposalItem` is FULLY editable. SU2 fixtures must be explicit about `editableFields` to hit the static/absent cells.
- `SidebarWorkspaceEmptyRow` (U1 leaf) ≠ the sidebar's empty-state; do not double-count (D-U2-6).
- Grep-guard baseline (P7, for the eventual retirement at later units): 268 `source.contains`/`sourceSlice` sites. U2 does not retire guards (that tracks coverage at U4+); recorded for continuity.
- Running views-lib coverage % is captured per sub-unit as an artifact — the input the U4 coverage-gate + allowlist will consume.

## Progress Log
- 2026-06-25 04:46 Created from the campaign journal (U2 intake). Surfaces F/A/B mapped first-hand (two Explore fan-outs + direct reads); TimelineView sites re-located + validated @ b588b78; the THIRD (accessibility-label) clock leak discovered; AN-002 locus pinned against the committed ④ references; fork F1 resolved (selective, not broad) on the 0-identifier/25-label evidence. Status: drafting → review gate.
- 2026-06-25 04:50–04:52 Five conversion passes committed (first-draft, granularity, validation [ViewInspector `input()` API confirmed], quality [16 emoji headers, no TBDs], planning-coverage-check [full coverage confirmed]).
- 2026-06-25 (review gate) Fresh unbiased sub-agent adversarial review (no inherited context). Verdict: NOT READY — 1 CRITICAL, 2 HIGH, 1 MED, 2 LOW; all line refs verified exact; AN-002 diagnosis+fix confirmed correct/feasible; provenance/determinism sound. **All findings RESOLVED:** C1 (sidebar can't produce the elapsed substring — `runningSince` never wired) → split out the standalone `TerminalAgentRow` leaf **SU3r** as the elapsed-seam snapshot; reworded SU3 surface to be clock-free + SU0-independent. H1 (SU0 payoff unreachable in U2) → SU3r exercises the seam; SU0→SU3 downgraded (SU0 gates only SU3r; also forward-serves U3's inbox). H2 (`--uisurfacetest` is render-smoke only, not a ticking proof) → reworded SU0b; ticking rests on retained-`TimelineView` grep + reviewer negative-control. M1 (`@Environment` can't pin the `:3718` computed-label `Date()`) → pre-biased SU0a/D-U2-1 to the init-param seam. L1 (label count) → 26→25 modifier calls (3 are computed-var decls). L2 (custom-override driver) → assert `WorkspaceRow.nameOverride`, not the context menu. New campaign observations surfaced (dead `runningStartDate` helper + unwired `runningSince`). Status: READY_FOR_EXECUTION.
