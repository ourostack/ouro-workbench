# Doing: U1 — View-Snapshot Harness (deterministic ViewInspector tree serializer + `__Snapshots__` + proof)

**Status**: READY_FOR_EXECUTION
**Execution Mode**: direct
**Created**: 2026-06-25 02:20
**Source pivoted**: 2026-06-25 (AX walk NO-GO + Mirror NOT VIABLE → **ViewInspector**; see history)
**Campaign**: ./../2026-06-24-anneal-visual-testing.md
**Artifacts**: ./U1-ax-snapshot-harness/
**Branch**: `feat/anneal-u1-ax-harness` (off `origin/main` @ `3eecd79`; now @ `a5e17ce`; do NOT branch again)

> **Autonomous run note.** Operator asleep — no interactive signoff. This doc is authored straight
> to `READY_FOR_EXECUTION`. Ambiguities resolved with the **reversible default**, each recorded
> under "Decisions made". A **fresh unbiased sub-agent review gate** runs before READY (see
> "Review gate").
>
> **SOURCE PIVOT (read the history in the Progress Log).** The original AX-role-tree source is a
> verified NO-GO (SwiftUI serves accessibility **out-of-process** in `xctest` → empty AX tree;
> 7 fallbacks exhausted) and the dependency-free `Mirror` fallback is **NOT VIABLE** on the real
> complex surfaces (doesn't invoke child bodies → composed `ForEach`-of-subview surfaces opaque and
> snapshots the MODEL not the VIEW; and recurses `@ObservedObject` → leaks 25 machine paths). Both
> are evidenced (`ax-walk-spike.md`, `mirror-viability-spike.md`) and recorded in the campaign
> journal. **The serialization source is now [ViewInspector](https://github.com/nalexn/ViewInspector)**
> — the only in-process tool that invokes child bodies (composed surfaces visible; real
> negative-control) AND extracts *declared* content (no VM-graph path leak) AND absorbs SwiftUI
> internal renames. **It is a NEW TEST-ONLY package dependency — that Package.swift dep add is the
> ONE operator-ratification item; see D-U1-DEP.** The harness SHAPE (host/store/`assertSnapshot`)
> and the F-1 `exclude:` fix are reused verbatim; only the node SOURCE changes.

---

## Execution Mode

- **direct**: execute units sequentially in this branch. One commit for the whole unit
  (campaign rule: "one commit per unit") — staged at the end, after all gates pass. NO
  Co-Authored-By / AI attribution. Do NOT stage `SerpentGuide.ouro/`. Do NOT open a PR.

---

## Objective

Build the **view-snapshot harness infrastructure** the visual-testing campaign depends on: a
deterministic walk over a SwiftUI view's **rendered tree via ViewInspector** that emits one indented
text line per node (view-type/role + `Text` content + `Image` name + accessibility
`label`/`value`/`identifier` + **the editable-vs-static distinction** — a real `TextField` vs a
`Text`), plus the determinism plumbing (fixed formatter clock / locale / tz / UUID) that makes the
output byte-identical, plus a committed-reference `__Snapshots__` compare-or-fail mechanism with an
artifact-on-failure. **Prove** it end-to-end — including on the **complex ④ surface (via the
internal `BossProposalCardList`, descending into the private `BossProposalCard`/`BossProposalItemRow`)**
— with a committed reference, a determinism re-run, and the **rendered-control flip Mirror FAILED to
produce** (an `editableFields`-driven `TextField`↔`Text` change at the rendered node, not the data).

**This unit builds the MECHANISM and PROVES it (incl. one complex surface). It does NOT enumerate
the full per-surface state-sets (the complete proposal-card / sidebar / tab-strip / recovery /
onboarding checklists) — those are U2/U3.** (Anneal scope discipline; campaign PERT
`U1 ─► U2 ─► U4` / `└► U3 ─┘`.)

---

## Completion Criteria

- [ ] **ViewInspector** added as a **test-only** dependency, **pinned to `.exact("0.10.3")`**, on the
      `OuroWorkbenchAppViewsTests` target ONLY — NOT on any product/runtime target (D-U1-DEP). This
      Package.swift `dependencies:` add is the **operator-ratification item** (flagged prominently).
- [ ] View-tree text serializer exists: walks the ViewInspector-RENDERED tree (child bodies
      invoked), emits one indented line per node with view-type/role + `Text` content + `Image`
      name + accessibility `label`/`value`/`identifier`, **and distinguishes a real `TextField`
      (editable) from a `Text` (static)** — the load-bearing thing Mirror missed.
- [ ] Serializer output is whitelisted to **declared content + structure**: NO machine paths, NO
      VM-graph object recursion, NO geometry/color/font/`.help`-tooltip/pointer-address (P4b/P3).
- [ ] Swift-6 strict-concurrency clean: ViewInspector's implicit-`AnyView`
      (`.anyView()`/`.implicitAnyView()`) handled, `@MainActor` test isolation respected, traversal
      is **structural** (find by type / accessibility), NOT positional `AnyView` unwrap (D-U1-VI).
- [ ] `exclude: ["__Snapshots__"]` on the `OuroWorkbenchAppViewsTests` test target (F-1; D-U1-2);
      SwiftPM emits NO "unhandled file" build-plan warning for `__Snapshots__/`.
- [ ] Determinism plumbing closes the U1-addressable leaks (P3): injectable FORMATTER clock
      (`coarseDescription(since:now:)` with fixed `now`), `Locale(identifier: "en_US_POSIX")`,
      `TimeZone(UTC)`, fixed UUIDs in fixtures (built via the real model seam).
- [ ] `TimelineView(.periodic(from: .now, …))` `context.date` (sites `:2166`, `:3775`): re-checked
      under ViewInspector inspection (does inspecting trigger `context.date`?); if it does, the
      two-site view-source touch stays a **per-surface-unit (U2) prerequisite**, NOT U1 — recorded
      with the re-check result (D-U1-5; L1). U1's proof views are chosen to avoid an unfrozen
      periodic `TimelineView` in the asserted text.
- [ ] `__Snapshots__` mechanism: write-on-record / compare-on-run; on mismatch FAIL and emit the
      actual tree as an artifact (mirrors the repo's `--expect-coverage-digest` artifact discipline).
- [ ] PROOF — beats Mirror's failures: snapshot the **complex ④ surface via the internal
      `BossProposalCardList`** (real fixture via `AgentProposalQueue.enqueue`→VM; private
      `BossProposalCard`/`ItemRow` reached by ViewInspector descent) in **editable vs static** item
      states, plus the 2 simpler proof views, asserting (a) match-committed-reference,
      (b) determinism (serialize twice → byte-identical), (c) the **rendered-control flip Mirror
      FAILED to produce**: an item's label node serializes `kind=editable` (`TextField`) with
      `editableFields=[.label]` and MUST flip to `kind=static` (`Text`) with `editableFields=[]`
      (P2) — the diff is at the RENDERED control, not the data array.
- [ ] Harness code itself is exercised by real tests (it's testable Swift).
- [ ] 100% test coverage on all new harness code (see Code Coverage Requirements).
- [ ] All tests pass under strict flags; no warnings.
- [ ] `swift build` / `swift test` strict (`-warnings-as-errors -strict-concurrency=complete`):
      0 warn / 0 fail on our products (3rd-party `SwiftTermFuzz` excepted).
- [ ] `swift run … OuroWorkbench --uisurfacetest` still green.
- [ ] ViewInspector links into the TEST target only — verify NO product target (`OuroWorkbenchApp`/
      `…MCP`/`…ScenarioVerifier`/`OuroWorkbenchAppViews`) gains a ViewInspector dependency; the
      packaged `.app` bundle and `Package.resolved` runtime graph are unaffected (zero distribution
      impact). `swift package show-dependencies` lists ViewInspector only under the test target.
- [ ] `Scripts/check-coverage.sh` green; `scripts/coverage-allowlist.txt` UNCHANGED; views lib
      still NOT in `COVERAGE_DIRS` (gating is the LAST campaign unit — U4).
- [ ] One commit (`docs(...)`/`feat(...)` as appropriate); no Co-Authored-By / AI attribution;
      `SerpentGuide.ouro/` not staged.

## Code Coverage Requirements
**MANDATORY: 100% coverage on all new harness code.**
- The harness (serializer + clock injection + `__Snapshots__` compare/record + artifact writer)
  lives in the **test target** `OuroWorkbenchAppViewsTests`. Its logic is exercised by the
  harness's own unit tests (Unit 1c/2c/3c) and the proof tests (Unit 4).
- The repo coverage gate (`COVERAGE_DIRS` = `OuroWorkbenchCore` + `OuroWorkbenchShellAdapter`)
  does NOT gate test targets or the views lib — so "100% coverage" here is enforced by
  **TDD + an explicit branch-coverage review of the harness source**, NOT by `check-coverage.sh`.
  Do NOT add the views lib or the test target to `COVERAGE_DIRS` (that is U4 and would fail now).
- No `// swiftlint:disable`-style coverage exclusions on new harness code.
- All branches covered (record-vs-compare, match-vs-mismatch, missing-reference, env var on/off,
  empty-tree edge, nested-children recursion, nil/absent label/value/id, `Text` vs `TextField`
  (static-vs-editable) classification, `Image`-name extraction, the implicit-`AnyView` unwrap path).
- All error paths tested (reference file unreadable, artifact dir creation, ViewInspector
  `InspectionError` from a node-not-found / unsupported node → surfaced as a clear test failure,
  not a crash).
- Edge cases: empty rendered tree, node with nil/absent label/value/identifier, deeply-nested
  composed children, unicode content.

## TDD Requirements
**Strict TDD — no exceptions:**
1. **Tests first**: write failing tests BEFORE any implementation.
2. **Verify failure**: run tests, confirm they FAIL (red).
3. **Minimal implementation**: write just enough to pass.
4. **Verify pass**: run tests, confirm they PASS (green).
5. **Refactor**: clean up, keep green.
6. **No skipping**: never write implementation without a failing test first.

> **TDD note for snapshot tests.** A snapshot test's *first* run legitimately records the
> reference (no prior reference = "fail/record"). The TDD "red" for snapshot units is the
> **determinism + negative-control + serializer-shape** assertions (which CAN fail before the
> code exists), not the reference-match itself. Write those structural assertions first.

---

## Decisions made (autonomous, reversible)

- **D-U1-DEP — ViewInspector is the serialization source; ONE test-only dependency, pinned exact;
  THIS IS THE OPERATOR-RATIFICATION ITEM.** Add to `Package.swift`:
  `.package(url: "https://github.com/nalexn/ViewInspector.git", exact: "0.10.3")` and list
  `.product(name: "ViewInspector", package: "ViewInspector")` in the `OuroWorkbenchAppViewsTests`
  target's `dependencies` **only**. Rationale + why this overrides the prior "no new dep" / D-A3
  "ViewInspector deferred":
  - **The dep is unavoidable for in-process VIEW testing** — AX is out-of-process in `xctest`
    (NO-GO, evidenced), `Mirror` is fatally non-meaningful + non-deterministic on composed surfaces
    (NOT VIABLE, evidenced); ViewInspector is the only in-process tool that invokes child bodies AND
    extracts declared content AND absorbs SwiftUI renames (see history). The dep-free alternative
    (presentation-MODEL snapshots) tests already-100%-covered value seams, NOT the views — it
    abandons the campaign's view-coverage goal. So the choice is "ViewInspector" or "no rendered-view
    coverage," not "ViewInspector vs a dep-free view harness."
  - **Blast radius is minimal + reversible:** test-only (`.testTarget` dep), ZERO product / runtime /
    distribution / security surface (never linked into the `.app`), de-facto standard
    (`nalexn/ViewInspector`), removable in one PR.
  - **Pinned `exact: "0.10.3"`.** `0.10.2` "fixed all compilation issues for Swift 6" and the
    Xcode-16.3 opaque-type-erasure (implicit-`AnyView`) issue; `0.10.3` is on top of that, and Swift
    Package Index lists it supporting Swift 6.1/6.2/6.3 with zero data-race-safety errors. Exact pin
    (not `from:`) = reproducible CI + no surprise minor bumps; a deliberate bump is a later one-line
    PR. The lib declares `swift-tools-version:5.9`, macOS 10.15+ — compatible with our
    `tools-version:6.0` / macOS `.v14` package, on this toolchain (Swift 6.3.2). **NIT (review):**
    `0.10.4` is already published; the exact pin is still correct (reproducible) — if Unit 0's strict
    compile surfaces any 6.3.2-specific issue on 0.10.3, bumping the pin to `exact: "0.10.4"` is the
    sanctioned fallback (still exact, record it). Do NOT switch to a `from:`/range pin.
  - **OPERATOR RATIFICATION:** the `Package.swift` `dependencies:` add is the supply-chain call. The
    campaign journal records the decision as "proceeding, flagged for operator ratification." If the
    operator prefers to revert (a `.app` UI-test target, or dep-free presentation-model snapshots with
    no rendered-view coverage), it's a one-PR revert. **Doer proceeds with ViewInspector** per the
    operator's standing "highest quality / don't return control / nobody's around to unblock"
    directive, but the doc surfaces this as THE one thing to ratify.
- **D-U1-VI — Serializer source = ViewInspector's rendered-tree traversal; Swift-6-safe + structural;
  relies on the `@ObservedObject`-only (no-`ViewHosting`) regime; locale via `string(locale:)`.**
  The serializer walks the ViewInspector view tree (which INVOKES child bodies — the thing Mirror
  could not), emitting per node: **view-type/role**, `Text` content (`.text().string(locale:)` — see
  the locale note below), `Image` name (`.image()` name), accessibility `label`/`value`/`identifier`
  (`.accessibilityLabel()`/`Value()`/`Identifier()`), and **the editable-vs-static distinction** —
  whether the node is a real `TextField` (editable) or a `Text` (static), the load-bearing signal
  for the ④ surface. **Whitelist to declared content + structure**; NEVER recurse stored objects /
  the VM graph (that's the Mirror leak), NEVER emit geometry/color/font/`.help`/pointer.
  - **Property-wrapper regime (HIGH — review finding 1): the proof rests on the `@ObservedObject`-only,
    NO-`ViewHosting`, synchronous `find()` path.** All three ④ structs hold `@ObservedObject var model`
    (`:7300/:7319/:7365`), which ViewInspector's guide documents as the supported case that
    `find()`/`inspect()` can evaluate **without** `ViewHosting` and without a source-side `Inspection`
    hook / `Inspectable` conformance. **U1 adds NO source-side inspection hook and uses NO
    `ViewHosting`** (keeps the views untouched — campaign anti-regress). **If Unit 0's spike finds any
    descended proof node reads `@State`/`@Environment`/`@EnvironmentObject` such that `find()` can't
    evaluate it synchronously, STOP and surface** (a source `Inspection` hook would be a view-source
    touch → out of U1 scope, a new fork). This regime + caveat is named here precisely because the
    whole proof depends on it.
  - **Locale/tz determinism via `string(locale:)`, NOT environment (HIGH — review finding 3a /
    ViewInspector issue #317).** Child views reached via `find()` are NOT installed in a render tree,
    so `@Environment` values forced on a parent (`.environment(\.locale, …)`) **do NOT propagate** to
    the descended ④ item nodes — D-U1-6's environment lever is unreliable for exactly the nodes we
    assert on. **The correct lever is ViewInspector's explicit-argument API:** read `Text` content via
    `.string(locale: Locale(identifier: "en_US_POSIX"))` (and pass the fixed `Locale` wherever
    ViewInspector accepts one). The serializer passes the fixed `Locale` to every content extraction;
    the host's `.environment(...)` forcing is kept as a best-effort SECONDARY belt-and-braces but is
    NOT the determinism guarantee. (Note: `.string()` with no arg defaults to ViewInspector's
    `.testsDefault`, NOT `en_US_POSIX` — so the explicit arg is mandatory, not cosmetic.)
  - **Swift-6 caveats** (under `-strict-concurrency=complete -warnings-as-errors`): handle the
    implicit-`AnyView` (`.anyView()`/`.implicitAnyView()` insertion under Xcode 16+), keep the
    inspection on the `@MainActor`, and traverse **structurally** (find descendants by view-type / by
    accessibility identity) rather than by positional `AnyView` unwrap (positional indices break across
    toolchain `AnyView` insertion).
  Reversible (the serializer is one module; only the node-source differs from the prior AX design).
- **D-U1-1 — Harness lives in the test target, not a shipped product.** All harness code goes in
  `Tests/OuroWorkbenchAppViewsTests/` (new files). Rationale: it's test infrastructure; keeping
  it out of `Sources/` means zero new public surface on the views lib and zero impact on the
  coverage gate / app bundle. Reversible: could be promoted to a `OuroWorkbenchSnapshotKit`
  test-support target later if U2/U3 want to share it across test targets — noted, not done now.
- **D-U1-2 — Reference files located via `#filePath`, read/written with `FileManager`; the
  `__Snapshots__` dir is `exclude:`d from the test target.** `__Snapshots__/` lives next to the
  test source; references are read/written with `FileManager` using a path derived from `#filePath`
  (the standard pointfreeco SnapshotTesting pattern) — NOT via SwiftPM `resources:`. **Empirically
  corrected during the review gate (F-1):** committed `.txt` files anywhere under a target's source
  dir make SwiftPM emit a build-PLAN warning — `"found 1 file(s) which are unhandled; explicitly
  declare them as resources or exclude from the target … __Snapshots__/…"`. Important facts the
  doer must rely on: (i) this is a **SwiftPM build-planning warning, NOT a Swift-compiler warning**,
  so `-Xswiftc -warnings-as-errors` does NOT promote it — the build still exits 0; (ii) `#filePath`
  resolution does nothing to suppress it (the file's mere presence under the target triggers it).
  **Decision: silence it with `exclude: ["__Snapshots__"]` on the `OuroWorkbenchAppViewsTests`
  test target in `Package.swift`.** This is a **deliberate, minimal, reversible Package.swift edit**
  (one array on one test target) — it does NOT touch `dependencies` (so "no new dep" holds), does
  NOT touch `COVERAGE_DIRS` or `scripts/coverage-allowlist.txt`, and does NOT add the views lib to
  the gate. `exclude:` is correct over `resources:`/`.copy` because the references are read by path
  (not bundled), so they must NOT be copied into the test bundle. **This supersedes the earlier
  draft's false "would error / zero Package.swift churn" claim.** Unit 0 verifies the warning is
  gone after the `exclude:` (and that the `#filePath`-derived path still resolves to the in-tree
  references). Reversible.
- **D-U1-3 — Record mode is opt-in via env var, default = compare.** `OURO_SNAPSHOT_RECORD=1`
  (or a missing reference) writes/overwrites the reference; otherwise the test compares and FAILS
  on mismatch. Default in CI = compare (so CI catches drift). Mirrors SnapshotTesting's
  `isRecording`. Rationale: the committed reference is the gate; recording must be a deliberate
  local action. Reversible.
- **D-U1-4 — Artifact-on-failure path.** On mismatch, write the ACTUAL tree to
  `./U1-ax-snapshot-harness/<TestName>.<view>.actual.txt` (under this unit's artifacts dir) AND
  `XCTAttachment` it, then fail with a unified-diff-style message pointing at both the committed
  reference and the actual. Mirrors the `--expect-coverage-digest` "emit on failure" discipline.
  Reversible (path is a constant).
- **D-U1-5 — Clock determinism in U1 = the injectable FORMATTER clock + locale/tz; the
  `TimelineView`-internal freeze is EXPLICITLY DEFERRED to U2 (no host-level seam exists).**
  *Empirically corrected during the review gate (F-3).* There are two distinct clock leaks and
  they have DIFFERENT seams:
  - **(a) The formatter clock — injectable, OWNED BY U1.** `WorkbenchElapsedFormatter
    .coarseDescription(since:now:)` takes an explicit `now: Date`; this is the seam the views' AX
    *label* code path uses (`TerminalAgentRow` → `ElapsedTimePill.coarseDescription(since:now:)`).
    Fixtures pass a FIXED `Date` for `now` (and fixed `since`), so any AX text derived through the
    formatter is byte-stable. U1 proves THIS determinism (compute the expected string by calling
    the real formatter with the fixed `now` — provenance, P2).
  - **(b) The `TimelineView(.periodic(from: .now, by: 30))` `context.date` — re-checked under
    ViewInspector.** Two sites: `ElapsedTimePill` (`WorkbenchViewsAndModel.swift:3775`) and
    `DecisionInboxSheet` (`:2166`). **Unit 0 RE-CHECKS** whether ViewInspector's traversal *triggers*
    `context.date` (i.e. whether inspecting a `TimelineView`-bearing view pulls a wall-clock date
    into the serialized content). Expected: ViewInspector reads the periodic timeline's content for
    a deterministic schedule entry, but if it evaluates against `Date()` the asserted text would
    leak the clock. **If it does leak**, freezing genuinely needs a **view-source touch** (swap the
    periodic `TimelineView` for an injectable clock) at the two sites — which stays a
    **per-surface-unit (U2) prerequisite**, NOT U1, because U2 is the unit that snapshots the
    surfaces embedding these (sidebar `ElapsedTimePill`, the inbox sheet). U1's proof views are
    chosen so no unfrozen periodic `TimelineView` appears in the asserted text.
  **Consequence (kills the earlier contradiction):** U1 does NOT write a red test asserting a
  `TimelineView` freeze it cannot make pass without a U2 source touch. U1's determinism red tests
  assert (a) the formatter clock + locale/tz. The `TimelineView` source touch is a NAMED U2
  prerequisite (recorded here + the campaign journal), gated on Unit 0's re-check result. Reversible.
- **D-U1-6 — Locale/tz determinism = `Text.string(locale:)` (PRIMARY); `.environment(...)` forcing
  is SECONDARY best-effort.** *Corrected by the ViewInspector review (finding 3a / issue #317).* The
  harness still wraps the view in `.environment(\.locale, Locale(identifier: "en_US_POSIX"))` +
  `.environment(\.timeZone, TimeZone(identifier: "UTC")!)` — but because `find()`-descended children
  are not installed in a render tree, that environment does NOT reliably reach the ④ item nodes. So
  the **guarantee** comes from the serializer passing a fixed `Locale(identifier: "en_US_POSIX")` to
  `Text.string(locale:)` (and any other locale-accepting ViewInspector accessor) for EVERY content
  extraction; the environment forcing is kept as a secondary belt only. Needs no view edits.
  Reversible. (See D-U1-VI for the full rationale + the `.testsDefault` gotcha.)
- **D-U1-7 — `.accessibilityIdentifier` on proof views: add only if needed for stable identity.**
  Per brief, U1 may add `.accessibilityIdentifier` to the 1–2 proof views if the AX tree lacks
  stable identity; otherwise leave the broad rollout to U2/U3. Default = **do not add unless a
  proof node is otherwise unidentifiable**; if added, note it in the iteration log. Reversible.
- **D-U1-8 — Serializer line format is fixed: `viewType[/role] kind=<static|editable> text="…"
  image="…" label="…" value="…" id="…"`, children indented +2.** `kind=` is the editable-vs-static
  classification (`TextField`→`editable`, `Text`→`static`, absent for non-text nodes) — the
  load-bearing field that makes the `isEditable()`-inversion negative control flip. Fields that
  don't apply are OMITTED (a node with no `text` shows no `text=`), but a field that *appears or
  disappears* across states is a visible diff (P4e/P2 sensitivity); the doer picks omit-vs-empty
  per field to maximize diff signal and records the choice. Reversible (format is one function).

---

## The harness API shape (what the doer builds)

A test declares a snapshot like this (illustrative target shape, not final code):

```swift
@MainActor
func testBossProposalCardList_editable() throws {
    // Fixture built via the REAL seam (provenance, P2) — never hand-assembled.
    // Enter via the INTERNAL `BossProposalCardList` (the private BossProposalCard/
    // BossProposalItemRow are reached by ViewInspector DESCENT, not construction):
    let model = makeVM(enqueueing: proposalWithEditableItems())   // AgentProposalQueue.enqueue → VM
    let list = BossProposalCardList(model: model)
    try assertViewSnapshot(of: list, named: "BossProposalCardList.editable")
    // ↑ wraps in forced en_US_POSIX/UTC + fixed formatter `now`/UUIDs, walks the ViewInspector
    //   RENDERED tree (child bodies invoked → TextField vs Text visible), serializes to text,
    //   compares to __Snapshots__/BossProposalCardList.editable.txt, records on OURO_SNAPSHOT_RECORD=1
    //   or missing-reference, fails+artifacts on mismatch.
}
```

Pieces (the SHAPE is reused from the prior AX design; only the SOURCE node-walk is ViewInspector):
1. **`ViewTreeSerializer`** — given an inspectable SwiftUI view, walks its ViewInspector RENDERED
   tree (child bodies invoked) → `String`. Per node emits the D-U1-8 line: view-type/role,
   `kind=<static|editable>` (`Text` vs `TextField`), `text="…"` (read via
   `.text().string(locale: en_US_POSIX)` — the explicit `Locale` is the determinism lever; `.string()`
   alone defaults to `.testsDefault`, NOT POSIX), `image="…"` (`.image()` name), accessibility
   `label/value/id`, children indented +2. **Whitelist only** — declared content + structure; never
   recurses stored objects / the VM graph; no geometry/color/font/`.help`/pointer. Stable depth-first;
   no set/dict ordering leakage. Swift-6 safe: structural find-by-type/accessibility, implicit-`AnyView`
   unwrapped, `@MainActor`.
2. **`ViewSnapshotHost`** — `@MainActor`: runs the ViewInspector traversal over the view-under-test
   via the no-`ViewHosting` `@ObservedObject` `find()` path (D-U1-VI), with content read through the
   fixed `Locale` (`string(locale:)` — D-U1-6). Also wraps the root in `.environment(\.locale,
   …en_US_POSIX)` + `.environment(\.timeZone, …UTC)` as a SECONDARY belt (NOT the guarantee — #317
   means it won't reach `find()`-descended nodes). May construct an `NSHostingView` ONLY if Unit 0
   found body evaluation needs a render pass (reusing the `UISurfaceTest.swift` `fittingSize` idiom) —
   but the SOURCE OF TRUTH for the serialized tree is ViewInspector. Does NOT override `TimelineView`
   `context.date` (D-U1-5; Unit-0 re-check → if it leaks, U2 source touch).
3. **`ViewSnapshotStore`** — `#filePath`-relative `__Snapshots__/<name>.txt` read/write; record vs
   compare; missing-reference → record (first run); mismatch → write `.actual.txt` artifact +
   `XCTAttachment` + fail with a readable diff.
4. **`assertViewSnapshot(of:named:file:line:)`** — the one-liner test entry that wires 1→2→3 and
   reports failures at the call site. `throws` (ViewInspector traversal is throwing).

**Determinism is injected** by: (a) fixtures pass a fixed `Date`(formatter `now`)/`UUID` into the
views' real seams (VM/model/formatter); (b) the host forces `Locale`/`TimeZone` in the environment;
(c) the serializer's whitelist emits only DECLARED content (no VM-graph recursion → no machine-path
leak, the Mirror failure mode) and drops `.help`/geometry/address. **Re-checked, not assumed:** the
`TimelineView` `context.date` (Unit 0); if it leaks, the two-site source touch is a U2 prerequisite
(D-U1-5; L1). **References live** in `Tests/OuroWorkbenchAppViewsTests/__Snapshots__/`.

**Proof views (VERIFIED access levels — load-bearing):**
- **`BossProposalCardList`** (`WorkbenchViewsAndModel.swift:7299`, **`internal` → `@testable`-reachable**)
  — **THE acceptance entry point.** It takes `model` and renders
  `ForEach(model.pendingProposals) { BossProposalCard(...) }`. NOTE: `BossProposalCard` (`:7317`) and
  `BossProposalItemRow` (`:7362`) are **`private struct`s — NOT directly constructible across the
  module boundary**, so the proof MUST enter through `BossProposalCardList` and let ViewInspector
  DESCEND into the private children (ViewInspector walks the rendered tree regardless of child access
  level — a strict advantage over direct construction, and exactly why the source pivot helps here).
  Fixture via the real seam: `AgentProposalQueue(paths:).enqueue(proposal)` →
  `WorkbenchViewModel(paths:).loadPendingProposals()` → `model.pendingProposals` →
  `BossProposalCardList(model: model)`. Snapshot **editable** (an item with `editableFields` non-empty
  → its row renders `TextField`s) vs **static** (`editableFields: []` → `Text`) — the serialized trees
  MUST differ in `kind=editable` vs `kind=static` at the item-field nodes. Doer records the exact
  fixture + the descended tree in `viewinspector-spike.md`.
- **`DashboardRowLabel`** (`Sources/OuroWorkbenchAppViews/Views/DashboardRowLabel.swift`, **`public`**)
  — VM-free leaf (importability keystone); `Label(title+symbol)` → deterministic `text`/`image` nodes.
  Trivial-surface sanity proof.
- **`SidebarWorkspaceEmptyRow`** (`WorkbenchViewsAndModel.swift:3183`, **`internal`**, VM-free,
  explicit `.accessibilityLabel("No tabs yet")` `:3190`, NO `TimelineView`) — clean labelled-leaf
  proof. (Caveat: 42 of ~75 lib `View` structs are `private` and NOT `@testable`-reachable — incl.
  `BossProposalCard`/`ItemRow`; that's why we enter via the internal `BossProposalCardList`.)

**Negative controls (P2):**
- **The control Mirror FAILED (primary — the headline P2 acceptance).** The view-logic under test is
  `BossProposalItemRow.isEditable(field) = item.editableFields.contains(field)` deciding `TextField`
  (editable) vs `Text` (static) per field (`:7367`, `:7394`…). Mirror saw the stored `editableFields`
  array but NEVER the rendered `TextField`/`Text`, so its snapshot was byte-identical whether or not
  the rows actually rendered editably — it could not catch a regression in that `if isEditable(…)`
  branch. **The ViewInspector control proves the new source CAN:** snapshot a provenance-built fixture
  whose item has `editableFields = [.label]` and assert the serialized label node is `kind=editable`
  (a `TextField`); then the same item with `editableFields = []` MUST flip that node to `kind=static`
  (a `Text`) — `XCTAssertNotEqual` the two trees AND assert the specific `kind=` flip. This is the
  RENDERED-control diff Mirror could not produce.
  **Honesty note (scope of the control — review finding 2):** `isEditable(field) =
  item.editableFields.contains(field)` (`:7367-7368`) is a pure passthrough of the data, and
  `isEditable()` is a `private func` with no injection seam. So this control PROVES exactly two things:
  (1) the harness SEES the rendered `TextField` vs `Text` (the Mirror gap — the headline win), and
  (2) it catches a regression in the `if isEditable(…)` BRANCH WIRING (e.g. the two arms swapped).
  It does **NOT** prove the harness catches a regression *internal to* the predicate body (e.g.
  `isEditable` hard-coded to `true` with data held constant) — that would need a temporary
  behavior-preserving test seam (a view-source touch → out of U1 scope). **Claim accordingly:** the
  acceptance + any commit message say "catches the editable-vs-static **rendering** regression at the
  control node," NOT the broader "catches all view-logic regressions." Default = the
  `editableFields`-driven render flip, no source edit; record in `viewinspector-spike.md` that the diff
  is at the RENDERED `TextField`/`Text` node (not the data array) — the precise Mirror distinction.
- **Input control (secondary):** a mutated fixture (different label/content/selection) → serialized
  tree `XCTAssertNotEqual` to its committed reference.
- **Determinism control:** serialize each proof fixture twice → `XCTAssertEqual` byte-identical, AND
  `swift test` twice + `git diff --exit-code __Snapshots__/` clean (P3, cross-run).

---

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

> **CRITICAL: every unit header starts with a status emoji (⬜ for new).**

### ⬜ Unit 0: Add the ViewInspector dep + spike the rendered-tree walk on the COMPLEX surface (research)
**What**: This is the make-or-break gate — it must clear the two reasons Mirror failed.
1. **Dep add (operator-ratification item):** add
   `.package(url: "https://github.com/nalexn/ViewInspector.git", exact: "0.10.3")` to `Package.swift`
   `dependencies:` and `.product(name: "ViewInspector", package: "ViewInspector")` to the
   `OuroWorkbenchAppViewsTests` target ONLY. Run `swift package resolve` + `swift build`/`swift test`
   with the strict flags; confirm it resolves, links into the TEST target only, and compiles clean
   under `-strict-concurrency=complete -warnings-as-errors`. Run `swift package show-dependencies`
   and confirm ViewInspector appears ONLY under the test target (no product target).
2. **F-1 packaging fix:** add `exclude: ["__Snapshots__"]` to the same test target; drop a throwaway
   `__Snapshots__/_probe.txt`; confirm the SwiftPM "unhandled file" warning is ABSENT (and was
   present without the `exclude:`); confirm the `#filePath`-derived path resolves to the in-tree
   `__Snapshots__/`.
3. **ViewInspector spike on the COMPLEX ④ surface (the gate that beats Mirror):** in a throwaway
   scratch test, build the real fixture via the seam (`AgentProposalQueue.enqueue` → VM →
   `pendingProposals`) and walk **`BossProposalCardList(model:)`** (the INTERNAL entry; the private
   `BossProposalCard`/`BossProposalItemRow` at `:7317`/`:7362` are reached by ViewInspector DESCENT,
   not construction — confirm this descent works). **Confirm (a) child bodies ARE invoked** —
   `BossProposalItemRow` is NOT an opaque leaf; the per-item `TextField`(editable) / `Text`(static)
   nodes ARE reachable (the thing Mirror couldn't see), and an `editableFields:[.label]` vs `[]` item
   flips that node's `kind=`. **CONFIRM this works via the `@ObservedObject`-only, NO-`ViewHosting`,
   synchronous `find()` path** (no source `Inspection` hook added) — if any descended proof node needs
   `ViewHosting`/a hook to evaluate, STOP + surface (a view-source touch is out of U1 scope). **(b) NO
   machine-path / VM-graph leak** — the serialized text contains NO `/Users/…` absolute paths (the
   Mirror fatal-#2). **(c) Locale determinism via `string(locale:)`, NOT environment** (review 3a /
   ViewInspector #317): verify that `.environment(\.locale,…)` does NOT reach `find()`-descended nodes,
   and that reading `Text` via `.string(locale: en_US_POSIX)` DOES produce stable content — record the
   exact accessor recipe. **(d) Swift-6 `AnyView`** — record how the implicit-`AnyView`
   (`.anyView()`/`.implicitAnyView()`) is unwrapped under THIS toolchain (Swift 6.3.2) and that
   structural find-by-type/accessibility works (not positional). **(e) `TimelineView` re-check** —
   inspect a `TimelineView`-bearing view and record whether `context.date` leaks a wall-clock date
   into the serialized text (decides whether the U2 source-touch prerequisite is real). **(f) VM-init
   hygiene** — `WorkbenchViewModel.init` runs `sweepStaleWorkbenchBundlesOnLaunch()` which spawns a
   DETACHED `Task` (`cleanupAllAgents()`, mutates `~/AgentBundles`, shells `git`) regardless of the
   temp `paths`; record whether this destabilizes the fixture (it must not appear in serialized output
   — declared-content only — but note the detached-task side effect for test hygiene / flake watch).
4. Confirm the simpler proof views (`DashboardRowLabel` public; `SidebarWorkspaceEmptyRow` internal,
   VM-free, AX-labelled) are `@testable`-reachable + inspectable.
**Output**: `./U1-ax-snapshot-harness/viewinspector-spike.md` with: the resolved ViewInspector
version + `show-dependencies` test-only confirmation; the F-1 warning before/after `exclude:`; the
④-surface walk sample proving child-body invocation + `TextField`-vs-`Text` visibility + NO
machine-path leak; **the regime confirmation (`@ObservedObject`/no-`ViewHosting`/no-hook) and the
`string(locale:)`-not-environment recipe**; the `AnyView`/`@MainActor` handling recipe; the
`TimelineView` re-check result; the VM-init detached-task hygiene note; the proof-view
constructors/fixtures.
**Acceptance**: ViewInspector resolves (exact 0.10.3), links test-only, compiles strict-clean;
`exclude:` silences the unhandled-file warning; **the ④ spike shows `BossProposalItemRow`'s
`TextField`/`Text` nodes via the no-`ViewHosting` `find()` path AND no `/Users/…` leak** (both
Mirror failures cleared); **locale determinism proven via `string(locale:)` (environment-only
confirmed NOT sufficient for descended nodes)**; `AnyView`/Swift-6 recipe recorded; `TimelineView`
re-check + VM-init hygiene recorded; proof views reachable. If the ④ walk does NOT clear both Mirror
failures, or needs a source `Inspection` hook / `ViewHosting`, STOP + surface to the operator (do
not proceed on a source that can't beat Mirror without a view-source touch). Scratch spike removed
before commit (findings in the md; the dep + `exclude:` STAY).

### ⬜ Unit 1a: ViewTreeSerializer — Tests
**What**: Write failing tests for `ViewTreeSerializer`. Drive the pure formatting logic with a
**fake node model** (a test double for the per-node fields — view-type/role, `kind`, text, image,
label/value/id, children) so the line-format logic is testable WITHOUT ViewInspector: assert the
D-U1-8 line format + field order, the `kind=static|editable` rendering, indentation, depth-first
child recursion, omit-vs-empty per field, unicode passthrough, and the empty-tree edge. Add the
**whitelist negation** test: a fake node carrying geometry/help/address/raw-object fields → those
MUST NOT appear in output. (The ViewInspector-extraction layer — `.text()`/`.image()`/`.find` →
fake-node — is tested in Unit 2 against a real hosted view.)
**Acceptance**: tests exist and FAIL (red); serializer doesn't exist yet.

### ⬜ Unit 1b: ViewTreeSerializer — Implementation
**What**: Implement `ViewTreeSerializer` (the pure node→text formatter) plus the small
ViewInspector-extraction adapter that maps an inspected node to the fake-node's field model
(view-type/role, `kind` from `TextField`-vs-`Text`, `text()`, `image()` name, accessibility
label/value/id, children). Deterministic depth-first; whitelist-only; NO stored-object/VM-graph
recursion. Make Unit 1a green.
**Acceptance**: all Unit 1a tests PASS (green); no warnings under strict flags.

### ⬜ Unit 1c: ViewTreeSerializer — Coverage & Refactor
**What**: Verify 100% branch coverage of the serializer + extraction adapter (all
nil/empty/nested/unicode/empty-tree branches, `static`-vs-`editable`, image-name, the
`InspectionError`/node-not-found path). Refactor for clarity; keep green.
**Acceptance**: every serializer/adapter branch exercised; tests green; no warnings.

### ⬜ Unit 2a: ViewSnapshotHost (env forcing + ViewInspector traversal + `string(locale:)` determinism) — Tests
**What**: Write failing tests for the host against a REAL inspected view: (i) inspecting
`DashboardRowLabel` yields a serialization containing its title + image; (ii) **determinism via
`string(locale:)`** — content read with a fixed `Locale(identifier: "en_US_POSIX")`, serializing the
same fixture twice → byte-identical; (iii) **formatter-clock determinism (D-U1-5a)** — text derived
through `WorkbenchElapsedFormatter.coarseDescription(since:now:)` with a FIXED `now`/`since` matches
the expected coarse string computed by calling the REAL formatter with that fixed `now` (provenance —
P2); (iv) **NO machine-path leak** — assert the serialized text of a VM-driven view (a descended ④
node) contains no `/Users/…` (the Mirror failure mode the new source must not reproduce); (v)
**`string(locale:)` is load-bearing, NOT environment** — a regression test that proves the descended
content is pinned by the explicit `Locale` arg (per Unit 0's #317 finding), so the serializer must
not fall back to `.string()`'s `.testsDefault`; (vi) **Swift-6 `AnyView`** — the traversal finds
nodes structurally through the implicit-`AnyView` wrapper. **Do NOT assert a host-level `TimelineView`
`context.date` freeze** (D-U1-5; Unit-0 re-check decides if it's a U2 source touch).
**Acceptance**: tests exist and FAIL (red).

### ⬜ Unit 2b: ViewSnapshotHost — Implementation
**What**: Implement `ViewSnapshotHost`: run the ViewInspector traversal via the no-`ViewHosting`
`@ObservedObject` `find()` path (D-U1-VI; Unit-0 recipe), extract `Text` content with the fixed
`Locale` via `.string(locale: en_US_POSIX)` (PRIMARY determinism lever — D-U1-6), apply the
`AnyView`/`@MainActor` + structural-find recipe, feed the serializer. Also wrap the root in
`.environment(\.locale, …en_US_POSIX)` + `.environment(\.timeZone, …UTC)` as a SECONDARY best-effort
(it won't reach `find()`-descended nodes — #317 — so it's belt-and-braces, not the guarantee). Reuse
the `UISurfaceTest.swift` `NSHostingView`/`fittingSize` idiom ONLY if Unit 0 found a render pass is
needed to evaluate bodies — the serialized source of truth is ViewInspector. Make Unit 2a green.
**Acceptance**: all Unit 2a tests PASS (green); determinism re-run byte-identical; descended-node
content pinned by `string(locale:)`; no machine-path leak; no warnings.
**Note**: U1 makes NO view-source edit. The two `TimelineView` sites (`:2166`, `:3775`) are left
untouched; if Unit 0's re-check showed a `context.date` leak it is a named U2 prerequisite (D-U1-5, L1).

### ⬜ Unit 2c: ViewSnapshotHost — Coverage & Refactor
**What**: Verify all host branches covered (env forcing, traversal, `AnyView` unwrap, empty-tree
edge, the no-leak path). Refactor; keep green.
**Acceptance**: host branches exercised; green; no warnings.

### ⬜ Unit 3a: ViewSnapshotStore + `assertViewSnapshot` (record/compare/artifact) — Tests
**What**: Write failing tests for the store + assertion helper, using a temp dir / injected base
path so the tests don't pollute the real `__Snapshots__/`: (i) missing reference → records it;
(ii) matching reference → passes; (iii) mismatching reference → fails AND writes a `.actual.txt`
artifact whose content is the actual tree; (iv) `OURO_SNAPSHOT_RECORD=1` overwrites; (v) the diff
message names both files. Assert the `#filePath`-relative path derivation.
**Acceptance**: tests exist and FAIL (red).

### ⬜ Unit 3b: ViewSnapshotStore + `assertViewSnapshot` — Implementation
**What**: Implement `#filePath`-relative `__Snapshots__/<name>.txt` read/write, record-vs-compare
(D-U1-3), mismatch artifact writing (D-U1-4: `XCTAttachment` + `.actual.txt` under
`./U1-ax-snapshot-harness/`), and the throwing `assertViewSnapshot(of:named:file:line:)` one-liner
wiring serializer + host + store with call-site failure reporting. Make Unit 3a green.
**Acceptance**: all Unit 3a tests PASS (green); no warnings.

### ⬜ Unit 3c: ViewSnapshotStore — Coverage & Refactor
**What**: Verify all store branches (record/compare/missing/mismatch/env/artifact-dir-create/
unreadable-reference error path). Refactor; keep green.
**Acceptance**: store branches exercised incl. error paths; green; no warnings.

### ⬜ Unit 4: PROOF — complex ④ surface + simpler views + commit references + determinism + the isEditable-inversion negative control
**What**: Write the proof tests using `assertViewSnapshot`:
  - **`BossProposalCardList.editable`** + **`BossProposalCardList.static`** (fixture via
    `AgentProposalQueue.enqueue`→VM→`pendingProposals`→`BossProposalCardList(model:)`; private
    `BossProposalCard`/`ItemRow` reached by descent) → record + commit both references. The two
    trees MUST differ at the item-field nodes: `kind=editable` (`TextField`) when `editableFields`
    includes the field vs `kind=static` (`Text`) when it doesn't — proving child bodies are inspected,
    the thing Mirror could not do.
  - **`DashboardRowLabel.default`** + **`SidebarWorkspaceEmptyRow.default`** → record + commit
    references (the simpler-surface sanity proofs).
  - **Negative control Mirror FAILED (the headline acceptance, P2):** assert the RENDERED-control
    flip Mirror could not produce — `editableFields=[.label]` → the label node serializes as
    `kind=editable` (`TextField`); the SAME provenance-built item with `editableFields=[]` → that node
    MUST flip to `kind=static` (`Text`). `XCTAssertNotEqual` the two serialized trees AND assert the
    specific `kind=` flip at the label node. (Per the harness-shape Honesty note: `isEditable()` is a
    private func; the inversion is induced through its only input, `editableFields`, via the real
    model — the diff is at the RENDERED `TextField`/`Text`, which is exactly what distinguishes this
    from Mirror's data-only snapshot. A source-level predicate inversion would need a temporary
    behavior-preserving test seam — default is the `editableFields`-driven render flip, no source edit.)
  - **Input control (P2):** a mutated proposal fixture (different label/selection) → tree differs
    from its reference.
  - **Determinism (P3):** serialize each proof fixture twice → `XCTAssertEqual`; AND `swift test`
    TWICE + `git diff --exit-code __Snapshots__/` clean (capture to `determinism-rerun.txt`).
  If a proof node lacks stable identity, add `.accessibilityIdentifier` to that proof view ONLY
  (D-U1-7) and note it.
**Output**: committed reference files in `Tests/OuroWorkbenchAppViewsTests/__Snapshots__/`
(incl. the editable/static ④ pair); proof tests green; `determinism-rerun.txt` (clean
`git diff --exit-code`); a note in `viewinspector-spike.md` showing the editable-vs-static trees
side-by-side + how the render-control flip is induced via `editableFields`.
**Acceptance**: proof tests green; references match; determinism re-run byte-identical
(`git diff --exit-code` clean); **the editable→static control FLIPS the rendered `kind=` at the
label node** (the RENDERED-control diff Mirror failed to produce); editable-vs-static produce
DIFFERENT committed trees; no `/Users/…` leak in any reference; trees are agent-legible.

### ⬜ Unit 5: Gates + planning-coverage + single commit
**What**: Run the full gate battery and capture outputs to `./U1-ax-snapshot-harness/`:
  - `swift build` strict → `final-build.txt` (0 warn on our products; `SwiftTermFuzz` excepted;
    **and NO SwiftPM "unhandled file" warning for `__Snapshots__/`** — the `exclude:` must have
    silenced it; grep the output to confirm absence).
  - `swift test` strict → `final-test.txt` (all green; same unhandled-file-warning-absent check).
  - `swift run … OuroWorkbench --uisurfacetest` → `final-uisurfacetest.txt` (green).
  - `Scripts/check-coverage.sh` → `final-coverage.txt` (green; allowlist unchanged; views lib NOT
    in `COVERAGE_DIRS`).
  - `git status` confirm `SerpentGuide.ouro/` NOT staged.
  Verify the harness source's own branch coverage by inspection (the gate doesn't cover the test
  target) and record the checklist. Then **one commit** for the whole unit (no Co-Authored-By /
  AI attribution). Do NOT open a PR. Update the campaign doc's iteration log + this doc's
  Progress Log + flip Status fields.
**Acceptance**: all gates green; allowlist + `COVERAGE_DIRS` unchanged; `SerpentGuide.ouro/`
unstaged; single commit landed on `feat/anneal-u1-ax-harness`; campaign iteration log updated.

## Execution
- **TDD strictly enforced**: tests → red → implement → green → refactor, per sub-unit.
- **One commit for the unit** (campaign rule), staged at the end of Unit 5 after all gates pass.
- Run the full strict test suite before marking the unit done.
- **All artifacts**: save outputs/logs/spike/diffs to `./U1-ax-snapshot-harness/`.
- **Fixes/blockers**: spawn a sub-agent immediately — don't ask, just do it (operator asleep).
- **Decisions made mid-flight**: append to "Decisions made", commit-with-the-unit, log it.
- **Anti-scope-creep**: do NOT enumerate the full per-surface state-sets (U1 proves on the ④ card +
  2 leaves; the complete checklists are U2/U3), do NOT roll out `.accessibilityIdentifier` broadly
  (only on a proof view if a node lacks identity — D-U1-7), do NOT add the views lib to
  `COVERAGE_DIRS` (U4), do NOT do the `TimelineView` view-source touch (U2 prerequisite — D-U1-5),
  do NOT add the grep-guard retirement (U5). ViewInspector itself IS in scope now (D-U1-DEP).

## Determinism landmines (P3) — the baseline list + what U1 found

Baseline-measured (campaign doc): 0 `accessibilityIdentifier`, 39 `Date()`/`.now`, the
`ElapsedTimePill` `TimelineView(.periodic(from: .now, by: 30))`, 4 `UUID()` sites. Plus, found
during this conversion:

- **L1 — `TimelineView(.periodic(from: .now, by: 30))` appears at TWO sites; re-checked under
  ViewInspector.** `ElapsedTimePill` @ `WorkbenchViewsAndModel.swift:3775` AND `DecisionInboxSheet`
  @ `:2166`. Whether ViewInspector's traversal pulls `context.date` (wall clock) into the serialized
  text is **re-checked in Unit 0** (the AX design assumed a host render; ViewInspector may read the
  timeline differently). **If it leaks**, freezing needs a view-source touch (injectable clock) at
  both sites — a NAMED U2 PREREQUISITE (U2 snapshots the surfaces embedding them), NOT U1. U1's
  proof views are chosen to avoid an unfrozen periodic `TimelineView` in the asserted text. Carry
  the re-check result into the campaign journal so U2 plans it.
- **L2 — `.help(...)` tooltip on `ElapsedTimePill` (`:3785`) embeds a formatted absolute date**
  (`startDate.formatted(date:.abbreviated,time:.shortened)`) — locale/tz-dependent AND wall-clock-
  derived. The serializer's whitelist (declared content only; no `.help`) drops it — which is why
  excluding `.help` is a determinism requirement, not just a noise requirement (P4b ∩ P3).
- **L3 — `Text`/`label` content can fold in locale-formatted numbers/dates.** Forcing `en_US_POSIX`
  + UTC at the host environment root is necessary but the doer must VERIFY the proof views'
  serialized text carries no implicit locale/tz formatting (assert exact expected strings, computed
  via the real formatter with a fixed `now`).
- **L4 — `#filePath` must resolve identically local vs CI.** The store derives `__Snapshots__/`
  from `#filePath`; store/compare using a path RELATIVE to the test file's directory (not an
  absolute path baked into output) so no machine-specific absolute path leaks into any committed
  file. (Artifacts under `./U1-…/` are fine — not committed references.)
- **L5 — the Mirror VM-graph leak (the reason for the pivot) must NOT recur via ViewInspector.**
  Mirror leaked 25 `/Users/…` paths by recursing the `@ObservedObject` graph. ViewInspector extracts
  DECLARED content (not stored objects), so it should not — but Unit 0 + Unit 2 ASSERT the serialized
  text of a VM-driven view (`BossProposalCard`, sidebar) contains NO `/Users/…`, and the serializer
  NEVER stringifies a raw model object. This is the load-bearing determinism check for the new source.
- **L6 — ViewInspector + Swift-6 implicit-`AnyView`.** Under Xcode 16+/Swift 6, the compiler inserts
  implicit `AnyView`s; positional traversal indices shift across toolchains. Traverse STRUCTURALLY
  (find by view-type / accessibility id) and unwrap via `.anyView()`/`.implicitAnyView()` per Unit 0's
  recipe — a positional `AnyView` unwrap is a cross-toolchain determinism hazard (D-U1-VI).
- **L7 — `find()`-descended children LOSE `@Environment` (ViewInspector issue #317) → use
  `string(locale:)`.** A `.environment(\.locale, …)` forced on a parent does NOT propagate to nodes
  reached via `find()` (they aren't installed in a render tree). So locale/tz determinism for the ④
  item nodes MUST come from the explicit-argument API `Text.string(locale: en_US_POSIX)`, NOT from the
  environment (which is secondary belt only). `.string()` with no arg defaults to `.testsDefault` (≠
  POSIX), so the explicit `Locale` is mandatory. This is the single most concrete determinism defect
  the review caught; D-U1-6/D-U1-VI/Unit-2 now encode the fix; Unit 0 verifies it empirically.
- **L8 — `WorkbenchViewModel.init` spawns DETACHED tasks that touch the real machine (test hygiene,
  not snapshot bytes).** `init` → `sweepStaleWorkbenchBundlesOnLaunch()` spawns a detached `Task`
  running `cleanupAllAgents()` (mutates `~/AgentBundles`, shells out to `git`) regardless of the temp
  `paths` (AgentBundles is home-relative). It will NOT appear in serialized output (declared content
  only — L5), so it doesn't break determinism of the SNAPSHOT, but it is a flake/hygiene hazard the
  `makeVM` fixture inherits. Unit 0 records it; the doer keeps fixtures hermetic where feasible and
  watches for flakes. (NOT a P3 snapshot-byte issue; a test-hygiene note.)

## UX / design forks worth surfacing (non-blocking; for the operator on wake)

- **F0 — THE supply-chain call: ViewInspector dependency (D-U1-DEP).** This is the one thing to
  ratify. It's test-only, pinned `exact: 0.10.3`, zero product/runtime/distribution surface,
  reversible in one PR — and it is UNAVOIDABLE for in-process rendered-view testing (AX out-of-process,
  Mirror NOT VIABLE; the only dep-free alternative is presentation-MODEL snapshots that test
  already-covered value seams, abandoning view coverage). Proceeding per the operator's standing
  directive; surfaced here + in the campaign journal as the ratification item.
- **F1 — What the snapshot asserts on (content vs identifier).** ViewInspector lets the tree carry
  declared `text`/`image`/`label` AND explicit `identifier`s. For U2/U3's real surfaces the campaign
  plans an `.accessibilityIdentifier` rollout — **the open question for the operator is whether the
  gate should assert on declared `text`/`label` (rich + catches copy regressions, but churns on copy
  edits) or anchor on explicit `identifier`s (stable, needs the rollout).** U1 records both; the
  gating posture is a U2 design call. Noted, not decided here.
- **F2 — Snapshot record ergonomics.** `OURO_SNAPSHOT_RECORD=1` is the chosen knob (D-U1-3). If the
  operator prefers a per-test `isRecording` flag or a `Scripts/record-snapshots.sh` wrapper, that's a
  trivial later add. Surfacing the choice; default stands.

## Review gate (fresh unbiased sub-agent — run BEFORE flipping to READY_FOR_EXECUTION)

Per the brief (operator asleep → no human signoff), an independent sub-agent with NO authoring
context reviews this doc against: (a) the campaign rubric P1–P7, (b) the brief's scope/out-of-scope,
(c) the constraints (test-only pinned dep, strict gates, allowlist unchanged, one commit, no AI
attribution, `SerpentGuide.ouro/` unstaged), (d) **the ViewInspector serializer-shape feasibility**
(child-body invocation + no VM-graph leak + Swift-6 `AnyView` handling — the things that must beat
Mirror), (e) the determinism landmines, (f) that the proof targets the COMPLEX ④ surface with the
`isEditable`-inversion negative control (not just trivial views). Findings + resolutions recorded in
`./U1-ax-snapshot-harness/review-gate-viewinspector.md`. Zero surviving CRITICAL/HIGH before READY.

## Progress Log
- 2026-06-25 02:20 Created from campaign U1 brief (autonomous; authored straight to READY pending review gate).
- 2026-06-25 **Unit 0 spike → NO-GO; UNIT BLOCKED.** Hosting a SwiftUI view in `NSHostingView`
  inside a headless `xctest` process yields an EMPTY AppKit AX tree (`accessibilityChildren() == []`,
  zero NSView subviews) across all 7 fallbacks tried (bare host / windowed host / unignoredDescendant /
  key-window+runloop-spin+`.accessory` activation / `AXUIElement` C-API / forced `display()`). Raw
  AppKit (`NSButton`) DOES populate children → the harness walk MECHANISM is sound; the wall is
  SwiftUI serving its AX tree out-of-process via the remote-AX server (needs a bundled `.app` + a
  connected assistive client; unavailable to `swift test`). This is the F-2 "one true feasibility
  wall"; per Unit 0's directive + the brief, STOPPED and surfaced — did NOT fake a tree.
  **F-1 packaging fix verified** (probe.txt → unhandled-file warning; `exclude:` silences it; build
  stays exit-0) and documented, but REVERTED from `Package.swift` so the branch carries no
  half-finished implementation while blocked. **Pivot found + VERIFIED dependency-free:** a `Mirror`
  reflection of each proof view's `body` reaches the rendered text in-process — `SidebarWorkspaceEmptyRow`
  → `["No tabs yet","No tabs yet"]`, `DashboardRowLabel` → `["Workbench MCP","infinity","infinity"]`.
  But that is a SwiftUI-introspection source, NOT an AX role tree — a material change to the
  campaign's P4a/P4b serialization-source definition → needs an operator call (options: ViewInspector
  [adds a dep], `Mirror` [dep-free, weaker AX semantics], or a real `.app` UI-test target). Full
  evidence + recommendations: `./U1-ax-snapshot-harness/ax-walk-spike.md`. Scratch spike + probe
  removed; tree clean; build green; allowlist + `Package.swift` + `COVERAGE_DIRS` unchanged.
- 2026-06-25 **Mirror-source viability spike (coordinator-requested) → `MIRROR NOT VIABLE`.** Drove
  a throwaway Mirror-walk serializer against a COMPLEX surface built via the real seam
  (`AgentProposalQueue.enqueue` → `model.loadPendingProposals` → `BossProposalCardList.body`) in
  editable vs static states, plus a stateful `WorkspaceSidebarRow` (pinned/active). Two INDEPENDENT
  FATAL findings: (1) **Meaningfulness** — Mirror does NOT invoke child views' `body`, so composed
  surfaces (`BossProposalCard`→`BossProposalItemRow`, i.e. every `ForEach`-of-subviews target) are
  OPAQUE leaves; the rendered `TextField` vs `Text` never appears. The editable-vs-static diff
  survived only because `editableFields` is stored DATA in the ForEach source — so the snapshot
  reflects the MODEL, not the VIEW, and would NOT catch a view-logic regression (inverted
  `isEditable()` → byte-identical snapshot). (2) **Determinism across machines** — reflecting a view
  holding `@ObservedObject model` recurses into the entire `WorkbenchViewModel` graph and leaked
  **25 absolute machine paths** (`/Users/microsoft/AgentBundles/…`, app-bundle/cli paths);
  unwhitelistable (unbounded graph, intermixed with real content) → fails P3/L4 on CI. Plus
  toolchain-fragile internal field names (`Storage`/`ImageProviderBox`/`_VStackLayout`). →
  **ViewInspector is NECESSARY, not just preferable** (or re-scope to presentation-MODEL snapshots,
  e.g. `WorkspaceSidebarPresentation.resolve(...).rows` / `model.pendingProposals` — pure value
  types, dep-free, deterministic — trading view-tree fidelity). Evidence + output samples:
  `./U1-ax-snapshot-harness/mirror-viability-spike.md`. Spike removed; no impl committed; tree clean;
  build green; `Package.swift`/allowlist/`COVERAGE_DIRS` unchanged; `SerpentGuide.ouro/` never staged.
- 2026-06-25 Verified facts against source: 2 `TimelineView(.periodic` sites (`:2166`,`:3775`);
  `SidebarWorkspaceEmptyRow` is `internal` + VM-free + AX-labelled (locked as 2nd proof view);
  `DashboardRowLabel` public; coverage gate = Core+ShellAdapter only (views lib not gated).
- 2026-06-25 Fresh unbiased sub-agent review gate run on the AX/Mirror-era draft → NOT READY (2 HIGH).
  Resolved: F-1 (SwiftPM unhandled-file warning → `exclude: ["__Snapshots__"]`, corrected D-U1-2),
  F-3 (no host-level `TimelineView` freeze seam → split clock leaks; `TimelineView` touch deferred
  to U2; removed un-passable red test). Folded in F-2 go/no-go, F-5 adapter, F-6 proof-view lock.
  Review record: `./U1-ax-snapshot-harness/review-gate.md`. (This gate predates the source pivot.)
- 2026-06-25 **SOURCE PIVOT → ViewInspector; doc re-spec'd IN PLACE (this revision).** Coordinator
  relayed: AX source NO-GO (out-of-process) + `Mirror` NOT VIABLE (evidence:
  `mirror-viability-spike.md`) → **ViewInspector is the serialization source** (test-only dep,
  flagged for operator ratification, recorded in the campaign journal @ `a5e17ce`). Re-spec, keeping
  the F-1/F-2 findings + the surface state-sets: (1) dep `.exact("0.10.3")` on the test target ONLY —
  D-U1-DEP, the operator-ratification item (latest stable 2025-09-21; `0.10.2` fixed all Swift-6
  compile + Xcode-16.3 opaque-`AnyView` issues); (2) serializer source = ViewInspector rendered-tree
  walk emitting `kind=static|editable` (`TextField` vs `Text`) + declared content — D-U1-VI/D-U1-8;
  (3) Swift-6: implicit-`AnyView` handled, `@MainActor`, structural (not positional) traversal;
  (4) determinism unchanged (formatter clock + locale/tz + fixed UUIDs); `TimelineView` `context.date`
  RE-CHECKED under ViewInspector in Unit 0 (was an AX-host assumption) → if it leaks, U2 source-touch;
  (5) reused the harness shape (host/store/`assertViewSnapshot`) + the F-1 `exclude:`; (6) PROOF now
  targets the COMPLEX ④ `BossProposalCard`/`BossProposalItemRow` (real `enqueue`→VM fixture) in
  editable vs static + the **`isEditable()`-inversion negative control Mirror FAILED** + the 2 leaves
  + twice-run determinism. Units renamed AX→View (`ViewTreeSerializer`/`ViewSnapshotHost`/
  `ViewSnapshotStore`); Unit 0 now adds the dep + spikes the ④ walk as the make-or-break gate
  (must clear BOTH Mirror failures: child-body invocation + no `/Users/…` leak). Fresh ViewInspector
  review gate to run before READY (`review-gate-viewinspector.md`).
- 2026-06-25 **Fresh ViewInspector review gate → NOT READY (2 HIGH); both resolved → READY.** The
  reviewer checked ViewInspector's actual API/issues + the ④ access levels. **HIGH-3a:**
  `find()`-descended children lose `@Environment` (ViewInspector #317), so the host-level
  `.environment(\.locale,…)` lever was broken for the ④ nodes → switched the determinism lever to
  `Text.string(locale: en_US_POSIX)` (`.string()` defaults to `.testsDefault`, not POSIX); updated
  D-U1-6/D-U1-VI/Pieces/Unit-2/Unit-0 + added L7. **HIGH-1:** the proof relies on `find()` evaluating
  `@ObservedObject` child bodies WITHOUT `ViewHosting`/an `Inspection` hook — now NAMED as the regime
  in D-U1-VI with a STOP-and-surface if any descended node needs hosting/a hook, and Unit 0 must
  confirm it. Tightened the negative-control claim (MEDIUM-2: it proves the harness sees the rendered
  `TextField`/`Text` + catches the `if isEditable` branch-wiring regression, NOT a regression internal
  to the private predicate). Added L8 (VM-init detached-task hygiene) + the 0.10.4-exists NIT (exact
  pin stands; 0.10.4 sanctioned fallback). Record: `./U1-ax-snapshot-harness/review-gate-viewinspector.md`.
  Residual risk concentrated in Unit 0 (the make-or-break gate that STOPS + surfaces). Re-verdict:
  **READY_FOR_EXECUTION.**
