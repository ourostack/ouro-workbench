# U1 Unit 0 — ViewInspector ④-walk spike: **GO** (both Mirror failures cleared)

**Toolchain:** Swift 6.3.2 (swiftlang-6.3.2.1.108), macOS 26.x, `arm64-apple-macosx26.0`.
**ViewInspector:** resolved at **`0.10.3`** (exact pin held; `Package.resolved` revision
`e9a06346499a3a889165647e3f23f8a7b2609a1c`). 0.10.4 fallback NOT needed — 0.10.3 compiles strict-clean
on 6.3.2.

## Verdict: **GO.** ViewInspector deterministically descends the private composed ④ views via the
`@ObservedObject` / **no-`ViewHosting`** / synchronous `inspect()`+`findAll()` path, with **no source
`Inspection` hook**, and leaks **no machine path**. Both reasons Mirror was NOT VIABLE are cleared.

---

## 1. Dep add — test-only, exact, strict-clean

- `Package.swift` `dependencies:` += `.package(url: "…/nalexn/ViewInspector.git", exact: "0.10.3")`.
- `OuroWorkbenchAppViewsTests.dependencies` += `.product(name: "ViewInspector", package: "ViewInspector")`.
- `swift package resolve` → "Computed …ViewInspector… at 0.10.3"; `Package.resolved` gains the entry.
- **Test-only confirmed.** `swift package describe --type json` → ViewInspector appears under
  **`OuroWorkbenchAppViewsTests` ONLY**. Every product target (`OuroWorkbenchApp`, `…MCP`,
  `…ScenarioVerifier`, `OuroWorkbenchAppViews`, `…Core`, `…ShellAdapter`) = `ViewInspector=no`.
  Zero `.app` / runtime / distribution impact.
- **Strict compile:** `swift build --build-tests -Xswiftc -warnings-as-errors
  -Xswiftc -strict-concurrency=complete` compiles ViewInspector + the test target with **0 warnings**
  (the only build error during the spike was a typo in my throwaway scratch — `KnownViewType` is
  ViewInspector-internal; the public generic constraint is **`BaseViewType`** — fixed, then clean).

## 2. F-1 packaging fix — `exclude: ["__Snapshots__"]` (verified before/after)

- WITHOUT the exclude (probe `__Snapshots__/_probe.txt` present): SwiftPM emits
  `warning: 'ouro-workbench': found 1 file(s) which are unhandled; explicitly declare them as
  resources or exclude from the target … __Snapshots__/_probe.txt`. (Build still exits 0 — it's a
  SwiftPM build-PLAN warning, NOT promoted by `-warnings-as-errors`, confirming D-U1-2.)
- WITH `exclude: ["__Snapshots__"]`: the warning is **absent**. References under `__Snapshots__/`
  stay on disk, read by `#filePath`-relative path (not bundled). `exclude:` (not `resources:`) is
  correct.

## 3. The COMPLEX ④ walk — child bodies invoked + the `kind=` flip (GATE-A, the Mirror fatal #1)

Real fixture via the seam: `AgentProposalQueue(paths: tempRoot).enqueue(proposal)` →
`WorkbenchViewModel(paths: tempRoot)` → `model.loadPendingProposals()` →
`model.pendingProposals` (count == 1) → `BossProposalCardList(model:).inspect()`. The private
`BossProposalCard` (`:7317`) and `BossProposalItemRow` (`:7362`) are reached purely by **descent**
(direct construction is impossible — they're `private struct`s).

**`editableFields: [.label]` (EDITABLE) — the item's label node is a `TextField`:**
```
node=… IMAGE.name="checklist"
node=… TEXT.string="Bring back your work"
node=… TEXT.string="1/1"
node=… IMAGE.name="checkmark.circle.fill" AXLABEL="Selected"
node=… TEXTFIELD label="Label"        ← the label renders editably
node=… TEXT.string="the detail"
node=… TEXT.string="echo hi"
node=… TEXT.string="/work/dir"
node=… TEXT.string="Dismiss"   …   TEXT.string="Approve"   …
```
`#TextField = 1`, `#Text = 12`.

**`editableFields: []` (STATIC) — the SAME label node is a `Text`:**
```
node=… IMAGE.name="checklist"
node=… TEXT.string="Bring back your work"
node=… TEXT.string="1/1"
node=… IMAGE.name="checkmark.circle.fill" AXLABEL="Selected"
node=… TEXT.string="Restore terminal A"   ← the label renders statically
node=… TEXT.string="the detail"   …
```
`#TextField = 0`, `#Text = 12`.

**This is the rendered-control diff Mirror could NOT produce.** The editable→static flip is at the
RENDERED `TextField`↔`Text` node (driven by `editableFields` through the private `isEditable()`
predicate's branch), not in the data array. ViewInspector **invokes the child bodies** of the private
subviews; the `BossProposalItemRow` is NOT an opaque leaf.

## 4. NO machine-path leak (GATE-B, the Mirror fatal #2)

Neither the editable nor the static dump contains any `/Users/…` absolute path. The only path-shaped
string (`/work/dir`) is the **declared fixture content** (`item.cwd`), not a VM-graph leak.
ViewInspector extracts DECLARED content; it does NOT recurse the `@ObservedObject` `WorkbenchViewModel`
graph (the unbounded 25-path Mirror leak). L5 satisfied.

## 5. The accessor recipe (for the serializer + host)

- **Full-tree depth-first enumeration:** `findAll(where: { _ in true })` →
  `[InspectableView<ViewType.ClassifiedView>]` in depth-first (top-to-bottom code) order.
- **Per-node typed reads (best-effort, `try?`):**
  - Text content: `node.text().string(locale: posix)` — **explicit `Locale(identifier: "en_US_POSIX")`**.
  - TextField (editable signal): `node.textField()` succeeds ⇒ `kind=editable`; its placeholder via
    `node.textField().labelView().text().string(locale: posix)` (e.g. `"Label"`).
  - Image name (SF Symbol): `node.image().actualImage().name()` → `"checklist"`,
    `"checkmark.circle.fill"`, `"infinity"`.
  - Accessibility label: `node.accessibilityLabel().string(locale: posix)` → `"Selected"`,
    `"No tabs yet"`. (`accessibilityValue()`/`accessibilityIdentifier()` analogous.)
- **`kind` classification:** `textField()` ok → `editable`; else `text()` ok → `static`; else absent.

## 6. (c) Locale determinism — `string(locale:)`, NOT environment (L7 / #317)

`string(locale: Locale("en_US_POSIX"))` returns stable content for the descended ④ nodes. `.string()`
with no arg defaults to ViewInspector's `.testsDefault` (`en`) — for the plain ASCII proof strings it
HAPPENS to match POSIX here, but per L7 the explicit `Locale` is **mandatory** (a locale-formatted
number/date would diverge). The serializer/host pass the fixed POSIX locale to EVERY content
extraction; the host's `.environment(\.locale,…)` forcing is kept only as a SECONDARY belt (it does
NOT reach `find()`-descended nodes — #317). **Decision stands: `string(locale:)` is the guarantee.**

## 7. (d) Swift-6 `AnyView` + `@MainActor`

Structural `findAll`/`find` by view-type descends THROUGH the implicit-`AnyView` wrappers Swift 6.3.2
inserts — `"1/1"`, `"Bring back your work"`, the per-item `TextField`/`Text` are all found by TYPE,
never by positional `AnyView` index. ViewInspector's `find*` are `@MainActor`-isolated
(`MainActor.assumeIsolated`), so the harness runs `@MainActor`. No manual `.anyView()` unwrap was
needed for structural search (L6 satisfied: structural, not positional).

## 8. (e) `TimelineView` re-check — **IT LEAKS `context.date`** → U2 source-touch prerequisite (CONFIRMED)

Inspecting the VM-free `ElapsedTimePill(startDate: fixed)` DOES evaluate the
`TimelineView(.periodic(from: .now, by: 30))` content closure, and `context.date` resolves to the
schedule's `.now` (≈ wall clock at inspection):
```
TIMELINEVIEW-RECHECK: texts=["22884h 22m", "Running since Nov 14, 2023 at 14:13", …]
TIMELINEVIEW formatter(now=Date())="22884h 22m"   ← identical ⇒ context.date == ~Date()
```
The leading `"22884h 22m"` == `coarseDescription(since: fixedStart, now: ≈Date())` — i.e. the asserted
Text **leaks the wall clock**. (The `"Running since Nov 14, 2023 …"` strings are the `.help` tooltip
off the FIXED `startDate` — deterministic, and the serializer whitelist drops `.help` regardless.)

**Consequence (L1 / D-U1-5 confirmed):** freezing the periodic `TimelineView` genuinely needs a
**view-source touch** (swap the periodic schedule for an injectable clock) at the **two sites**
`ElapsedTimePill` (`:3775`) and `DecisionInboxSheet` (`:2166`). This is a **NAMED U2 PREREQUISITE**
(U2 snapshots the sidebar pill + inbox sheet that embed them), **NOT U1**. **U1's proof views
(`BossProposalCardList`, `DashboardRowLabel`, `SidebarWorkspaceEmptyRow`) contain no unfrozen periodic
`TimelineView`**, so no clock leaks into any U1 snapshot. Carried to the campaign journal for U2.

## 9. (f) VM-init detached-task hygiene (L8) — **confirmed a real test-isolation DEFECT**

`WorkbenchViewModel.init` calls `sweepStaleWorkbenchBundlesOnLaunch()`, which spawns a
`Task.detached(priority: .utility)` running `bossWorkbenchMCPRegistrar.cleanupAllAgents()`. The default
`BossWorkbenchMCPRegistrar()` resolves `agentBundlesURL = ~/AgentBundles`
(`BossAgentBridge.swift:173`, home-relative) — **independent of the injected temp `WorkbenchPaths`**.
So a `makeVM(paths: tempDir)` fixture STILL spawns a detached task that scans/`git`-touches the REAL
`~/AgentBundles`. It does NOT appear in serialized output (declared content only) and is idempotent
(no-write on a clean entry), so it does **not** break snapshot determinism — but it's a flake/hygiene
hazard.

- **Backlog item (anneal U2/cleanup, NOT fixed here):** the injected `paths` does not redirect the
  bundle-cleanup path; the default VM init mutates the real home regardless of `paths`. A real
  test-isolation defect — should route bundle cleanup through `paths` (or skip in a test mode).
- **U1 mitigation (trivial, in the harness fixture):** `makeVM` injects
  `BossWorkbenchMCPRegistrar(agentBundlesURL: <tempRoot>/AgentBundles)` (a non-existent temp dir →
  `contentsOfDirectory` returns nil → empty list → zero writes). Keeps U1 fixtures hermetic without a
  source touch.

## 10. Simpler proof views — reachable + inspectable

- `DashboardRowLabel(title:"Workbench MCP", systemImage:"infinity")` (public): texts=`["Workbench MCP"]`,
  images=`["infinity"]`.
- `SidebarWorkspaceEmptyRow()` (internal, VM-free): texts=`["No tabs yet"]`, axLabels=`["No tabs yet"]`
  (its explicit `.accessibilityLabel("No tabs yet")` `:3190` is read via `accessibilityLabel()`).

## Spike hygiene

Scratch test (`Tests/OuroWorkbenchAppViewsTests/_SpikeScratch.swift`) and probe
(`__Snapshots__/_probe.txt`) REMOVED before commit. The dep add (`Package.swift` + `Package.resolved`)
and the `exclude:` STAY. No `SerpentGuide.ouro/` staged.

---

## Unit 4 PROOF — the editable-vs-static committed trees side-by-side (the Mirror-beating control)

Both fixtures are provenance-built (`AgentProposalQueue.enqueue` → VM → `pendingProposals`); the ONLY
difference is `editableFields` (`[.label]` vs `[]`). The diff is at the RENDERED CONTROL, not the data:

```
--- BossProposalCardList.static.txt        +++ BossProposalCardList.editable.txt
 Image image="checklist"                     Image image="checklist"
 Text kind=static text="Bring back your work" Text kind=static text="Bring back your work"
 Text kind=static text="1/2"                  Text kind=static text="1/2"
 Image image="checkmark.circle.fill" label="Selected"
-Text kind=static text="Restore terminal A"  +TextField kind=editable text="Label"
                                              +Text kind=static text="Label"
 Text kind=static text="agent-a in ~/proj"    Text kind=static text="agent-a in ~/proj"
 …
 Image image="circle" label="Not selected"
-Text kind=static text="Restore terminal B"  +TextField kind=editable text="Label"
                                              +Text kind=static text="Label"
 …
```

**How the render-control flip is induced:** `BossProposalItemRow.isEditable(.label) =
item.editableFields.contains(.label)` (`:7367`) chooses `if isEditable(.label) { TextField(…) } else {
Text(item.label) }` (`:7394`). With `editableFields=[.label]` BOTH items' label nodes render a
`TextField` (`kind=editable`, placeholder `"Label"`); with `editableFields=[]` they render a `Text`
(`kind=static text="Restore terminal A/B"`). The serialized diff therefore changes the CONTROL TYPE
(`TextField`↔`Text`) at the item label — the rendered-control diff **Mirror could not produce** (Mirror
saw only the stored `editableFields` array, never the rendered control, so its snapshot was
byte-identical either way).

**Scope of the control (honesty, per the doc's review finding 2):** this proves (1) the harness SEES the
rendered `TextField` vs `Text` (the Mirror gap — the headline win) and (2) catches a regression in the
`if isEditable(…)` BRANCH WIRING (e.g. the two arms swapped). It does NOT prove a regression INTERNAL to
the private `isEditable` predicate body (that needs a test seam → out of U1 scope). Commit/claim language
is constrained to "catches the editable-vs-static **rendering** regression at the control node."

**Determinism (P3):** RUN1 recorded → RUN2/RUN3 compared GREEN against the on-disk references; byte-hashes
identical across runs (`determinism-rerun.txt`). The 4 references are pairwise distinct (P4e). No `/Users/…`
in any reference (P4b/L5). `assertViewSnapshot(of:)` view-entry covered 100% by the proof.
