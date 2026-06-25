# Doing: U1 — AX-Snapshot Harness (deterministic NSHostingView AX-tree serializer + `__Snapshots__` + proof)

**Status**: READY_FOR_EXECUTION
**Execution Mode**: direct
**Created**: 2026-06-25 02:20
**Campaign**: ./../2026-06-24-anneal-visual-testing.md
**Artifacts**: ./U1-ax-snapshot-harness/
**Branch**: `feat/anneal-u1-ax-harness` (off `origin/main` @ `3eecd79`; do NOT branch again)

> **Autonomous run note.** Operator asleep — no interactive signoff. This doc was authored
> straight to `READY_FOR_EXECUTION` per the brief. Ambiguities resolved with the **reversible
> default**, each recorded under "Decisions made (autonomous, reversible)". A **fresh unbiased
> sub-agent review gate** was run before flipping to `READY_FOR_EXECUTION` (see "Review gate").

---

## Execution Mode

- **direct**: execute units sequentially in this branch. One commit for the whole unit
  (campaign rule: "one commit per unit") — staged at the end, after all gates pass. NO
  Co-Authored-By / AI attribution. Do NOT stage `SerpentGuide.ouro/`. Do NOT open a PR.

---

## Objective

Build the **AX-snapshot harness infrastructure** the visual-testing campaign depends on: a
deterministic, dependency-free walk over an `NSHostingView`-hosted SwiftUI view that emits one
indented text line per accessibility node (`role / label / value / identifier / children` only),
plus the determinism plumbing (fixed clock / locale / tz / UUID / no tooltip) that makes the
output byte-identical, plus a committed-reference `__Snapshots__` compare-or-fail mechanism with
an artifact-on-failure. **Prove** it end-to-end on 1–2 already-in-lib views with a committed
reference, a determinism re-run, and a negative control.

**This unit builds the MECHANISM and PROVES it on 1–2 views. It does NOT snapshot the full
per-surface enumerated state-sets (proposal card / sidebar / tab-strip / recovery / onboarding)
— those are U2/U3.** (Anneal scope discipline; campaign PERT `U1 ─► U2 ─► U4` / `└► U3 ─┘`.)

---

## Completion Criteria

- [ ] AX-tree text serializer exists: walks an `NSHostingView`-hosted SwiftUI view, emits one
      indented line per node with **only** `role`, `label`, `value`, `identifier`, `children`.
- [ ] **No new package dependency** added (reuse `NSHostingView` + AppKit `NSAccessibility`;
      `Package.swift` `dependencies:` list unchanged). The ONLY allowed `Package.swift` edit is
      `exclude: ["__Snapshots__"]` on the `OuroWorkbenchAppViewsTests` test target (F-1; D-U1-2) —
      no other manifest change.
- [ ] SwiftPM emits NO "unhandled file" build-plan warning for `__Snapshots__/` (the `exclude:`
      silences it) — verified in the strict `swift build`/`swift test` output (F-1).
- [ ] Serializer output excludes geometry / color / font / `.help`-tooltip / pointer-address (P4b).
- [ ] Determinism plumbing closes the U1-addressable leaks (P3): injectable FORMATTER clock
      (`coarseDescription(since:now:)` with fixed `now`), `Locale(identifier: "en_US_POSIX")`,
      `TimeZone(UTC)`, fixed UUIDs in fixtures, `.help` excluded by the serializer whitelist.
- [ ] The `TimelineView(.periodic(from: .now, …))` `context.date` freeze (sites `:2166`, `:3775`)
      is EXPLICITLY DEFERRED to U2 with a recorded rationale (no host-level seam; needs a
      view-source touch) — NOT silently dropped (D-U1-5b, L1). U1's proof views embed neither site.
- [ ] `__Snapshots__` mechanism: write-on-record / compare-on-run; on mismatch FAIL and emit the
      actual tree as an artifact (mirrors the repo's `--expect-coverage-digest` artifact discipline).
- [ ] PROOF: 1–2 already-in-lib views snapshotted, asserting (a) match-committed-reference,
      (b) determinism (serialize twice → byte-identical), (c) negative control (mutating the
      fixture changes the snapshot — P2).
- [ ] Harness code itself is exercised by real tests (it's testable Swift).
- [ ] 100% test coverage on all new harness code (see Code Coverage Requirements).
- [ ] All tests pass under strict flags; no warnings.
- [ ] `swift build` / `swift test` strict (`-warnings-as-errors -strict-concurrency=complete`):
      0 warn / 0 fail on our products (3rd-party `SwiftTermFuzz` excepted).
- [ ] `swift run … OuroWorkbench --uisurfacetest` still green.
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
  empty-tree edge, nested-children recursion, nil label/value/id).
- All error paths tested (reference file unreadable, artifact dir creation).
- Edge cases: empty fixture tree, node with nil label/value/identifier, deeply-nested children,
  unicode label.

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
  - **(b) The `TimelineView(.periodic(from: .now, by: 30))` `context.date` — NO host-level
    injection seam exists.** SwiftUI gives no public API to override a `TimelineView`'s
    `context.date` from outside the view; freezing it genuinely requires a **view-source touch**
    (swap the periodic `TimelineView` for an injectable clock) at the two sites — `ElapsedTimePill`
    (`WorkbenchViewsAndModel.swift:3775`) and `DecisionInboxSheet` (`:2166`). **That source touch
    is OUT OF SCOPE for U1 and is DEFERRED to U2**, which is the unit that actually snapshots the
    surfaces embedding these (sidebar `ElapsedTimePill`, the inbox sheet). U1's proof views
    (`DashboardRowLabel` + `SidebarWorkspaceEmptyRow`) embed NEITHER periodic `TimelineView`, so
    U1 proves the harness end-to-end WITHOUT needing (b).
  **Consequence (kills the earlier contradiction):** U1 does NOT write a red test asserting a
  host-level `TimelineView` freeze (there is no seam to make it pass — that would be an un-passable
  red, i.e. gameable vaporware). U1's determinism red tests assert (a)+locale/tz only. The
  `TimelineView` freeze is a NAMED U2 prerequisite recorded here + in the campaign iteration log,
  NOT "required infra delivered in U1." If U2 finds the freeze trivial it may pull a
  `TimelineView`-bearing proof view forward — but U1 does not block on it. Reversible.
- **D-U1-6 — `Locale`/`TimeZone` forced via `EnvironmentValues` on the hosted root.** The harness
  wraps the view-under-test with `.environment(\.locale, Locale(identifier: "en_US_POSIX"))` and
  `.environment(\.timeZone, TimeZone(identifier: "UTC")!)` before hosting. Rationale: SwiftUI text
  formatting reads these from the environment; forcing them at the host root is the least-invasive
  determinism lever and needs no view edits. Reversible.
- **D-U1-7 — `.accessibilityIdentifier` on proof views: add only if needed for stable identity.**
  Per brief, U1 may add `.accessibilityIdentifier` to the 1–2 proof views if the AX tree lacks
  stable identity; otherwise leave the broad rollout to U2/U3. Default = **do not add unless a
  proof node is otherwise unidentifiable**; if added, note it in the iteration log. Reversible.
- **D-U1-8 — Serializer field order is fixed: `role / label / value / identifier`, children
  indented beneath.** Empty fields are RENDERED as explicit empty markers (e.g. `label=""`) rather
  than omitted, so a value appearing/disappearing is a visible diff (P4e/P2 sensitivity).
  Reversible (format is one function).

---

## The harness API shape (what the doer builds)

A test declares a snapshot like this (illustrative target shape, not final code):

```swift
@MainActor
func testDashboardRowLabel_default() {
    let view = DashboardRowLabel(title: "Workbench MCP", systemImage: "infinity")
    assertAXSnapshot(of: view, named: "DashboardRowLabel.default")
    // ↑ hosts in NSHostingView under forced en_US_POSIX/UTC (+ fixtures pass a fixed
    //   formatter `now`/UUIDs), serializes the AX tree, compares to
    //   __Snapshots__/DashboardRowLabel.default.txt, records on OURO_SNAPSHOT_RECORD=1 or
    //   missing-reference, fails+artifacts on mismatch.
}
```

Pieces:
1. **`AXTreeSerializer`** — pure: takes an `AXNode` root → `String`. Recurses `children`, emitting
   per node: `role` (normalized from `accessibilityRole().rawValue`), `label`
   (`accessibilityLabel()`), `value` (`accessibilityValue()` stringified), `identifier`
   (`accessibilityIdentifier()`), then children indented +2. **Whitelist only** — never reads
   frame/size/color/font/`help`/pointer. Stable, depth-first, no set/dict ordering leakage.
   Consumes the `AXNode` protocol, fed by an **adapter** over the real `NSView`/
   `NSAccessibilityElement` AX surface (F-5: `[Any]?`/`Any?` are untyped → adapter, not retroactive
   conformance); the test fake conforms to `AXNode` directly.
2. **`AXSnapshotHost`** — `@MainActor`: wraps the view in forced `locale`/`timeZone` environment,
   builds an `NSHostingView`, lays it out (`layoutSubtreeIfNeeded` on a fixed frame, reusing the
   existing `UISurfaceTest.swift` `fittingSize`/`NSHostingController` render path idiom), returns
   the AX root (adapted to `AXNode`) for the serializer. Does NOT override `TimelineView`
   `context.date` (D-U1-5b; no seam → deferred to U2).
3. **`AXSnapshotStore`** — `#filePath`-relative `__Snapshots__/<name>.txt` read/write; record vs
   compare; missing-reference → record (first run); mismatch → write `.actual.txt` artifact +
   `XCTAttachment` + fail with a readable diff.
4. **`assertAXSnapshot(of:named:file:line:)`** — the one-liner test entry that wires 1→2→3 and
   reports failures at the call site.

**Determinism is injected** by: (a) fixtures pass a fixed `Date`(formatter `now`)/`UUID` into the
views' real seams (VM/model/formatter); (b) the host forces `Locale`/`TimeZone` in the environment;
(c) the serializer's whitelist drops `.help`/geometry/address. **NOT in U1:** a `TimelineView`
`context.date` freeze — no host-level seam exists; deferred to U2 (D-U1-5b). U1's proof views embed
no periodic `TimelineView`, so (a)+(b)+(c) fully determinize them. **References live** in
`Tests/OuroWorkbenchAppViewsTests/__Snapshots__/`.

**Proof views (the 1–2):**
- **`DashboardRowLabel`** (`Sources/OuroWorkbenchAppViews/Views/DashboardRowLabel.swift`) — the
  VM-free leaf already used as the importability keystone; renders a `Label` (title + symbol) →
  a deterministic AX text node. Trivially clock/locale-stable.
- **`SidebarWorkspaceEmptyRow`** (`WorkbenchViewsAndModel.swift:3183`) — **the chosen 2nd proof
  view.** Verified during conversion: it is **`internal`** (`struct SidebarWorkspaceEmptyRow: View`,
  no access modifier → `@testable import` reaches it directly, NO visibility change needed), it is
  **VM-free** (no `@ObservedObject`; zero-stored-prop, so the implicit memberwise `init()` is a
  reachable no-arg init), carries an **explicit `.accessibilityLabel("No tabs yet")`** (`:3190`) so
  the AX tree has a real `label=` field, and embeds **NO `TimelineView`** (both periodic-timeline
  sites are `:2166` + `:3775`, neither here). Construct it `@testable` exactly like the
  `ImportabilityProofTests` reach `DashboardRowLabel`. Reversible fallback if a reachability/AX
  surprise appears: the `internal InlineRenameEditor` `.accessibilityLabel("Rename")` control at
  `:3163`/`:3177` (VM-driven, heavier) — but `SidebarWorkspaceEmptyRow` is the default.
  (Caveat for the doer: 42 of the ~75 lib `View` structs are `private`/file-private and are NOT
  `@testable`-reachable; `SidebarWorkspaceEmptyRow` and `InlineRenameEditor` are both `internal`,
  which is why they qualify — do not pick a `private` view as the proof.)

**Negative control (P2):** the same proof view fixture with a MUTATED input (different `title`/
label/state) MUST produce a different serialized tree than the committed reference — asserted by
serializing both and `XCTAssertNotEqual`. Plus the determinism control: serialize the SAME fixture
twice → `XCTAssertEqual` byte-identical.

---

## Work Units

### Legend
⬜ Not started · 🔄 In progress · ✅ Done · ❌ Blocked

> **CRITICAL: every unit header starts with a status emoji (⬜ for new).**

### ⬜ Unit 0: Reality-check the AX walk + pick the 2nd proof view (research)
**What**: Spike (throwaway, in a scratch test) the AppKit `NSAccessibility` walk over an
`NSHostingView`-hosted `DashboardRowLabel`: confirm `host.view` (or its AX root) exposes
`accessibilityChildren()` with a reachable text node carrying the `Label` text, and that
`accessibilityRole()/Label()/Value()/Identifier()` are readable. Determine the exact AX root
to walk (the `NSHostingView` itself vs `host.view.accessibilityChildren()`) and the empty-frame
vs `fittingSize` requirement for AX to populate. The 2nd proof view is already chosen —
`SidebarWorkspaceEmptyRow` (internal, VM-free, `.accessibilityLabel("No tabs yet")`, no
`TimelineView`); Unit 0 just CONFIRMS it constructs `@testable` and exposes a readable AX node
(fall back to `InlineRenameEditor` only if it surprises). Record findings (root element, layout
requirement, confirmed 2nd view + its construction) to `./U1-ax-snapshot-harness/ax-walk-spike.md`.
ALSO in Unit 0: verify the **F-1 packaging fix** — drop a throwaway `__Snapshots__/_probe.txt`
under the test target, run a CLEAN `swift build`/`swift test` plan with the strict flags, and
confirm the SwiftPM "unhandled file" warning appears; then add `exclude: ["__Snapshots__"]` to the
`OuroWorkbenchAppViewsTests` test target in `Package.swift` and confirm the warning is GONE and the
`#filePath`-derived path still resolves to the in-tree `__Snapshots__/`. Record the before/after in
the spike md. Also pin down the AX-node ADAPTER shape (F-5): `accessibilityChildren()` returns
`[Any]?` and `accessibilityValue()` returns `Any?` (untyped), so the serializer consumes a tiny
`AXNode` protocol via a thin ADAPTER that maps the `NSView`/`NSAccessibilityElement` AX surface to
it (the fake test double conforms directly) — NOT retroactive conformance. **Go/no-go (F-2):**
record explicitly whether `NSHostingView`'s SwiftUI AX tree surfaces text through
`accessibilityChildren()` cleanly; if `AXStaticText` children don't surface, record the fallback
tried (walk `host.view` vs the window AX root vs `accessibilityChildren(forSubrole:)`) and which
worked. If NONE expose a readable tree, STOP and surface to the operator (this is the one true
feasibility wall) — do not fake a tree.
**Output**: `ax-walk-spike.md` with: the AX root expression, the layout prerequisite, the AX-node
adapter shape, the normalized role set observed, the F-1 warning before/after `exclude:`, the
go/no-go, and the chosen 2nd proof view (`SidebarWorkspaceEmptyRow`) + how to construct it.
**Acceptance**: spike prints a non-empty AX tree for `DashboardRowLabel` containing the title text;
`exclude: ["__Snapshots__"]` added + the unhandled-file warning confirmed gone; AX-node adapter
shape recorded; go/no-go = GO (or operator surfaced); 2nd view confirmed constructible across the
module boundary. Scratch spike removed before commit (findings captured in the md).

### ⬜ Unit 1a: AXTreeSerializer — Tests
**What**: Write failing tests for `AXTreeSerializer.serialize(root:)`. Drive it with a
**fake AX node** type (a test double conforming to the minimal protocol the serializer consumes —
`role/label/value/identifier/children`) so the serializer logic is testable WITHOUT a live
hosting view: assert indentation, field order (`role / label / value / identifier`), explicit
empty markers (D-U1-8), depth-first child recursion, nil→`""` normalization, unicode passthrough,
and the empty-tree edge. Add the **whitelist negation** test: a fake node also exposing
geometry/help/address-like fields → those MUST NOT appear in output.
**Acceptance**: tests exist and FAIL (red); serializer doesn't exist yet.

### ⬜ Unit 1b: AXTreeSerializer — Implementation
**What**: Implement `AXTreeSerializer` against the minimal `AXNode` protocol (`role/label/value/
identifier/children`). Per F-5, this is NOT retroactive conformance: `accessibilityChildren()`
returns `[Any]?` and `accessibilityValue()` returns `Any?` (untyped), so a thin **adapter** wraps
the real `NSView`/`NSAccessibilityElement` AX surface to the `AXNode` protocol (mapping
`[Any]?`→`[AXNode]`, `Any?`→stringified value), while the test FAKE conforms to `AXNode` directly.
The serializer only ever sees `AXNode`. Pure string building; deterministic depth-first;
whitelist-only fields. Make Unit 1a green.
**Acceptance**: all Unit 1a tests PASS (green); no warnings under strict flags.

### ⬜ Unit 1c: AXTreeSerializer — Coverage & Refactor
**What**: Verify 100% branch coverage of the serializer (all nil/empty/nested/unicode/empty-tree
branches hit by Unit 1a). Refactor for clarity; keep green.
**Acceptance**: every serializer branch exercised; tests green; no warnings.

### ⬜ Unit 2a: AXSnapshotHost (render + determinism plumbing) — Tests
**What**: Write failing tests for the host: (i) hosting `DashboardRowLabel` yields a serializable
AX root whose serialization contains the title; (ii) **determinism (locale/tz)** — forcing
`en_US_POSIX` + UTC on the host root, serializing the same fixture twice → byte-identical;
(iii) **formatter-clock determinism (the U1-owned clock seam, D-U1-5a)** — render text derived
through `WorkbenchElapsedFormatter.coarseDescription(since:now:)` with a FIXED `now`/`since` and
assert the serialized AX text contains the expected coarse string, computed by calling the REAL
formatter with that same fixed `now` (provenance — P2; no hand-assembled output). **Do NOT write
a test asserting a host-level `TimelineView` `context.date` freeze — there is no SwiftUI seam to
make it pass (D-U1-5b); that freeze is deferred to U2.** U1's proof views embed no periodic
`TimelineView`, so their host render is deterministic from (ii)+(iii) alone.
**Acceptance**: tests exist and FAIL (red).

### ⬜ Unit 2b: AXSnapshotHost — Implementation
**What**: Implement `AXSnapshotHost`: wrap-in-environment (`.environment(\.locale,
Locale(identifier: "en_US_POSIX"))` + `.environment(\.timeZone, TimeZone(identifier: "UTC")!)`),
build `NSHostingView`, lay out on a fixed frame (reusing the `UISurfaceTest.swift`
`NSHostingController`/`fittingSize` idiom — use the AX-root expression + layout prerequisite Unit 0
established), expose the AX root for the serializer's adapter. The "clock" the host honors is the
**formatter clock via fixtures** (D-U1-5a) — the host does NOT attempt a `TimelineView`
`context.date` override (D-U1-5b: no seam; deferred to U2). Make Unit 2a green.
**Acceptance**: all Unit 2a tests PASS (green); determinism re-run byte-identical; no warnings.
**Note**: U1 makes NO view-source edit for clock freezing. The two `TimelineView` sites
(`:2166`, `:3775`) are left untouched in U1 and recorded as a named U2 prerequisite (D-U1-5b, L1).

### ⬜ Unit 2c: AXSnapshotHost — Coverage & Refactor
**What**: Verify all host branches covered (env forcing, layout, AX-root extraction, empty/no-AX
edge). Refactor; keep green.
**Acceptance**: host branches exercised; green; no warnings.

### ⬜ Unit 3a: AXSnapshotStore + `assertAXSnapshot` (record/compare/artifact) — Tests
**What**: Write failing tests for the store + assertion helper, using a temp dir / injected base
path so the tests don't pollute the real `__Snapshots__/`: (i) missing reference → records it;
(ii) matching reference → passes; (iii) mismatching reference → fails AND writes a `.actual.txt`
artifact whose content is the actual tree; (iv) `OURO_SNAPSHOT_RECORD=1` overwrites; (v) the diff
message names both files. Assert the `#filePath`-relative path derivation.
**Acceptance**: tests exist and FAIL (red).

### ⬜ Unit 3b: AXSnapshotStore + `assertAXSnapshot` — Implementation
**What**: Implement `#filePath`-relative `__Snapshots__/<name>.txt` read/write, record-vs-compare
(D-U1-3), mismatch artifact writing (D-U1-4: `XCTAttachment` + `.actual.txt` under
`./U1-ax-snapshot-harness/`), and the `assertAXSnapshot(of:named:file:line:)` one-liner wiring
serializer + host + store with call-site failure reporting. Make Unit 3a green.
**Acceptance**: all Unit 3a tests PASS (green); no warnings.

### ⬜ Unit 3c: AXSnapshotStore — Coverage & Refactor
**What**: Verify all store branches (record/compare/missing/mismatch/env/artifact-dir-create/
unreadable-reference error path). Refactor; keep green.
**Acceptance**: store branches exercised incl. error paths; green; no warnings.

### ⬜ Unit 4: PROOF — snapshot 1–2 in-lib views + commit reference + determinism + negative control
**What**: Write the proof tests using `assertAXSnapshot`:
  - `DashboardRowLabel.default` → record + commit `__Snapshots__/DashboardRowLabel.default.txt`.
  - The chosen 2nd AX-labelled view (Unit 0) → record + commit its reference.
  - **Determinism (P3)**: serialize each proof view twice in-test → `XCTAssertEqual` byte-identical.
  - **Negative control (P2)**: a mutated fixture (different title/label/state) → serialized tree
    `XCTAssertNotEqual` to the committed reference (i.e. breaking the input flips the snapshot).
  Run `swift test` TWICE and `git diff --exit-code` the `__Snapshots__/` dir to prove cross-run
  byte-identity (P3 check). If a proof node lacks stable identity, add `.accessibilityIdentifier`
  to that proof view ONLY (D-U1-7) and note it.
**Output**: committed reference file(s) in `Tests/OuroWorkbenchAppViewsTests/__Snapshots__/`;
proof tests green; the twice-run `git diff --exit-code` output captured to
`./U1-ax-snapshot-harness/determinism-rerun.txt`.
**Acceptance**: proof tests green; committed reference matches; determinism re-run byte-identical
(`git diff --exit-code` clean); negative control fails when expected (asserted in-test); proof
view AX tree is agent-legible (role/label/value/id/children only).

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
- **Anti-scope-creep**: do NOT snapshot the full surfaces, do NOT roll out `.accessibilityIdentifier`
  broadly, do NOT add the views lib to `COVERAGE_DIRS`, do NOT add ViewInspector. Those are U2–U5.

## Determinism landmines (P3) — the baseline list + what U1 found

Baseline-measured (campaign doc): 0 `accessibilityIdentifier`, 39 `Date()`/`.now`, the
`ElapsedTimePill` `TimelineView(.periodic(from: .now, by: 30))`, 4 `UUID()` sites. Plus, found
during this conversion:

- **L1 — `TimelineView(.periodic(from: .now, by: 30))` appears at TWO sites, not one — and has
  NO host-level freeze seam.** `ElapsedTimePill` @ `WorkbenchViewsAndModel.swift:3775` (the
  baseline's one) AND `DecisionInboxSheet` @ `:2166`. Both leak `context.date` (wall clock) into
  rendered text, and SwiftUI exposes NO public API to override `context.date` from outside the
  view → freezing requires a **view-source touch** (swap the periodic `TimelineView` for an
  injectable clock at both sites). **DECISION (D-U1-5b, F-3): U1 does NOT attempt this freeze and
  does NOT write a test requiring it; U1 mitigates by choosing proof views that embed neither
  site, and the `TimelineView`-source-touch is a NAMED U2 PREREQUISITE** (U2 snapshots the
  surfaces that embed them — sidebar `ElapsedTimePill`, the inbox sheet). This is an explicit,
  recorded deferral, not vaporware "infra." Carry into the campaign iteration log so U2 plans it.
- **L2 — `.help(...)` tooltip on `ElapsedTimePill` (`:3785`) embeds a formatted absolute date**
  (`startDate.formatted(date:.abbreviated,time:.shortened)`) — locale/tz-dependent AND wall-clock-
  derived in fixtures. The serializer's whitelist (no `.help`) drops it from the AX value, which is
  exactly why excluding `.help` is a determinism requirement, not just a noise requirement (P4b ∩ P3).
- **L3 — SwiftUI AX `value`/`label` can fold in locale-formatted numbers/dates.** Forcing
  `en_US_POSIX` + UTC at the host environment root is necessary but the doer must VERIFY the proof
  views' serialized text carries no implicit locale/tz formatting (assert exact expected strings,
  computed via the real formatter with a fixed `now`).
- **L4 — `#filePath` must resolve identically local vs CI.** The store derives `__Snapshots__/`
  from `#filePath`; this is a path to the SOURCE file (stable across machines for relative
  resolution), but the doer must store/compare using a path RELATIVE to the test file's directory
  (not an absolute path baked into output) so no machine-specific absolute path leaks into any
  committed file. (Artifacts under `./U1-...//` are fine — they're not committed references.)
- **L5 — AX role strings may differ across macOS/SwiftUI versions.** If Unit 0's spike shows
  role rawValues that look version-fragile, normalize them through a small fixed mapping in the
  serializer (record the mapping). Reversible; only if observed.

## UX / design forks worth surfacing (non-blocking; for the operator on wake)

- **F1 — Where the AX `label` actually comes from.** The proof depends on the hosted view exposing
  a readable `accessibilityLabel`. `DashboardRowLabel` exposes its `Label` text implicitly; the 2nd
  proof view exposes an explicit `.accessibilityLabel`. For U2/U3's real surfaces, the campaign
  already plans adding `.accessibilityIdentifier` across views — **the open question for the operator
  is whether the gate should also assert on the implicit `label` text (brittle to copy edits) or
  ONLY on explicit `identifier`s (stable but requires the rollout).** U1 records both in the tree;
  the gating posture is a U2 design call. Noted, not decided here.
- **F2 — Snapshot record ergonomics.** `OURO_SNAPSHOT_RECORD=1` is the chosen knob (D-U1-3). If the
  operator prefers the pointfreeco-style per-test `isRecording` flag or a `Scripts/record-snapshots.sh`
  wrapper, that's a trivial later add. Surfacing the choice; default stands.

## Review gate (fresh unbiased sub-agent — run BEFORE flipping to READY_FOR_EXECUTION)

Per the brief (operator asleep → no human signoff), an independent sub-agent with NO authoring
context reviewed this doc against: (a) the campaign rubric P1–P7, (b) the brief's scope/out-of-scope,
(c) the constraints (no new dep, strict gates, allowlist unchanged, one commit, no AI attribution,
`SerpentGuide.ouro/` unstaged), (d) the harness-shape feasibility (AX walk over `NSHostingView`),
(e) the determinism landmines. Findings + resolutions recorded in
`./U1-ax-snapshot-harness/review-gate.md`. Zero surviving CRITICAL/HIGH required before READY.

## Progress Log
- 2026-06-25 02:20 Created from campaign U1 brief (autonomous; authored straight to READY pending review gate).
- 2026-06-25 Verified facts against source: 2 `TimelineView(.periodic` sites (`:2166`,`:3775`);
  `SidebarWorkspaceEmptyRow` is `internal` + VM-free + AX-labelled (locked as 2nd proof view);
  `DashboardRowLabel` public; coverage gate = Core+ShellAdapter only (views lib not gated).
- 2026-06-25 Fresh unbiased sub-agent review gate run → NOT READY (2 HIGH). Resolved:
  F-1 (SwiftPM unhandled-file warning → `exclude: ["__Snapshots__"]`, corrected D-U1-2),
  F-3 (no host-level `TimelineView` freeze seam → split clock leaks; `TimelineView` touch deferred
  to U2; removed un-passable red test). Folded in F-2 go/no-go, F-5 adapter, F-6 proof-view lock.
  Review record: `./U1-ax-snapshot-harness/review-gate.md`. Re-verdict: READY_FOR_EXECUTION.
