#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// AN-R3-01 — energy-0 round-3 close for `FirstRunStepRow`'s `.isDone` icon arm.
///
/// `FirstRunStepRow.icon` (`:7060`) is a five-arm `@ViewBuilder` chain keyed off the row's
/// `BootstrapStepRunState`:
///
///   - `row.isActive`          → `ProgressView()`                              (no serializable image — host drops it)
///   - `row.isDone`            → `Image("checkmark.circle.fill")`              ← THIS ARM
///   - `row.isTerminalFailure` → `Image("exclamationmark.triangle.fill")`     (pinned: `E2.needsAttention` step row)
///   - `row.isAwaitingHuman`   → `Image("person.crop.circle.badge.exclamationmark")` (pinned: `E2.parked`)
///   - else (pending)          → `Image("circle")`                            (pinned: every E2 step snapshot)
///
/// The round-3 single-actor serial mutation sweep proved the `.isDone` arm was the ONE residual
/// P2 energy here: mutating `checkmark.circle.fill` to a sentinel left the ENTIRE
/// `FirstRunBootstrapView` suite (and the broad onboarding set, 218 tests) GREEN. Every committed
/// `E2.*` reference exercises only `pending` / `halted` / `awaitingHuman` step states (`presentIdle()`
/// is all-`pending`; `.failedStep` halts one and leaves the rest pending; `.parked` awaits the human),
/// so NO snapshot ever rendered a `.verified` (done) row — the checkmark arm executed in production
/// the moment the live bootstrap advanced a step, but no test asserted its distinguishing glyph.
/// The sibling arms were sweep-verified CAUGHT (each mutation went RED); `.isActive`'s `ProgressView`
/// has no serializable image (structurally non-energy). So this leaf closes exactly one live guard.
///
/// **Provenance (P2).** Two layers, both through the real seam:
///   1. The PURE Core producer `FirstRunBootstrapDrive.present(result:activeStep:)` is the genuine
///      step-row factory the live `runFirstRunBootstrap()` feeds the VM — a `BootstrapStepOutcome`
///      whose `recovery == .verified` (`BootstrapRecoveryTruth.classify(.healthy)`) is mapped to a
///      `.verified` row (`FirstRunBootstrapDrive.swift:352`). `verifiedRow()` asserts that mapping
///      so the fixture's `.verified` state is producer-derived, not hand-set.
///   2. `FirstRunStepRow` is a `View`; constructing it directly with that producer-derived
///      `BootstrapStepProgress` IS the legitimate render seam (exactly as `TerminalAgentRowDecoratedLeafTests`
///      constructs its row leaf — P2 forbids hand-assembling serializer OUTPUT, not instantiating a `View`).
///
/// **Determinism (P3).** No clock / path / UUID / agent-name is read — the row is a pure function
/// of the fixed `BootstrapStepProgress`. Asserted byte-identical twice + no machine-path leak.
@MainActor
final class FirstRunStepRowDoneLeafTests: XCTestCase {

    private let drive = FirstRunBootstrapDrive()

    /// A `.verified` (done) step row, derived through the REAL Core producer: a `.verified`
    /// recovery outcome on `.ensureDaemon` makes `present(result:)` emit a `.verified` row.
    /// This pins the provenance — the fixture's `.verified` state is the producer's output, never
    /// a hand-set enum (P2 §2b).
    private func verifiedRow() -> BootstrapStepProgress {
        let presentation = drive.present(
            result: BootstrapResult(
                phase: .failedStep(.verifyCredentials),
                stepOutcomes: [
                    // An earlier step the bootstrap genuinely brought up — `.verified`.
                    BootstrapStepOutcome(step: .ensureDaemon, recovery: .verified)
                ]
            ),
            activeStep: nil
        )
        // The producer maps the `.verified` outcome to a `.verified` row for `.ensureDaemon`.
        return presentation.rows.first { $0.step == .ensureDaemon && $0.state == .verified }!
    }

    // MARK: - The committed reference (the `.isDone` arm renders the checkmark + the done line)

    func testStepRow_done_pinsCheckmarkAndDoneLine() throws {
        let row = verifiedRow()
        // Provenance: the producer really emitted a `.verified` row (not a hand-set state).
        XCTAssertTrue(row.isDone, "provenance: a .verified recovery → an isDone row through present(result:)")

        let tree = try ViewSnapshotHost.snapshotText(of: FirstRunStepRow(row: row))

        // The `.isDone` arm → the green checkmark glyph (the guard this leaf closes).
        XCTAssertTrue(tree.contains(#"image="checkmark.circle.fill""#),
                      "done step → the checkmark glyph:\n\(tree)")
        // The done human-facing line (the `.verified` arm of `humanFacingLine`).
        XCTAssertTrue(tree.contains("Workbench is online."),
                      "done step → the done human line:\n\(tree)")

        try assertViewSnapshot(of: FirstRunStepRow(row: row), named: "FirstRunStepRow.done")
    }

    // MARK: - Negative control (P2) — only the `.verified` state renders the checkmark

    /// Every NON-done state renders a DIFFERENT (non-checkmark) icon, and the done state is the
    /// ONLY one whose tree carries `checkmark.circle.fill`. Proves the `.isDone` arm is the
    /// load-bearing guard for that glyph (mutating it flips the captured tree).
    func testStepRow_negativeControl_onlyDoneRendersCheckmark() throws {
        let done = try ViewSnapshotHost.snapshotText(of: FirstRunStepRow(row: verifiedRow()))
        XCTAssertTrue(done.contains(#"image="checkmark.circle.fill""#), "done renders the checkmark:\n\(done)")

        // pending → "circle", NOT the checkmark.
        let pending = BootstrapStepProgress(step: .ensureDaemon, state: .pending)
        let pendingTree = try ViewSnapshotHost.snapshotText(of: FirstRunStepRow(row: pending))
        XCTAssertFalse(pendingTree.contains(#"image="checkmark.circle.fill""#),
                       "pending: no checkmark:\n\(pendingTree)")
        XCTAssertTrue(pendingTree.contains(#"image="circle""#), "pending: the circle glyph:\n\(pendingTree)")
        XCTAssertNotEqual(done, pendingTree, "the .isDone guard flips the icon vs pending")

        // halted → "exclamationmark.triangle.fill", NOT the checkmark.
        let halted = BootstrapStepProgress(step: .ensureDaemon, state: .halted)
        let haltedTree = try ViewSnapshotHost.snapshotText(of: FirstRunStepRow(row: halted))
        XCTAssertFalse(haltedTree.contains(#"image="checkmark.circle.fill""#),
                       "halted: no checkmark:\n\(haltedTree)")
        XCTAssertNotEqual(done, haltedTree, "the .isDone guard flips the icon vs halted")

        // awaitingHuman → the person glyph, NOT the checkmark.
        let awaiting = BootstrapStepProgress(step: .providerConfig, state: .awaitingHuman)
        let awaitingTree = try ViewSnapshotHost.snapshotText(of: FirstRunStepRow(row: awaiting))
        XCTAssertFalse(awaitingTree.contains(#"image="checkmark.circle.fill""#),
                       "awaitingHuman: no checkmark:\n\(awaitingTree)")
        XCTAssertNotEqual(done, awaitingTree, "the .isDone guard flips the icon vs awaitingHuman")
    }

    // MARK: - U5 B3 — DRIVE the `.isActive` arm (L7072) — the ProgressView (no-glyph) branch

    /// U5 B3 (corrected recipe). The `icon` `@ViewBuilder`'s FIRST arm `if row.isActive` (`:7072`)
    /// was the residual uncovered region: every prior snapshot rendered pending/done/halted/
    /// awaitingHuman rows, never an `.active` one, because the active arm's `ProgressView()` emits
    /// no serializable node so the campaign skipped it. DRIVEN by rendering a producer-derived
    /// `.active` row (`present(result:activeStep:)` maps `step == activeStep` → `.active`).
    /// EXECUTING the row with `isActive == true` covers the branch; the assertion is that the
    /// active arm renders NONE of the sibling glyphs (it's the no-glyph ProgressView arm) while the
    /// active human-facing line renders. MUTATION-VERIFIED below.
    private func activeRow() -> BootstrapStepProgress {
        // `.awaitingHandoff` carries no per-step recovery override, so the `activeStep` (ensureDaemon)
        // maps cleanly to a `.active` row via `present(result:activeStep:)` (the producer rule
        // `step == activeStep → .active`).
        let presentation = drive.present(
            result: BootstrapResult(phase: .awaitingHandoff, stepOutcomes: []),
            activeStep: .ensureDaemon
        )
        return presentation.rows.first { $0.step == .ensureDaemon && $0.state == .active }!
    }

    func testStepRow_active_rendersProgressNoGlyph() throws {
        let row = activeRow()
        XCTAssertTrue(row.isActive, "provenance: step == activeStep → an .active row via present(result:activeStep:)")
        let tree = try ViewSnapshotHost.snapshotText(of: FirstRunStepRow(row: row))
        // The active arm is the ProgressView() branch — NONE of the sibling glyphs render.
        XCTAssertFalse(tree.contains(#"image="checkmark.circle.fill""#), "active ≠ done glyph:\n\(tree)")
        XCTAssertFalse(tree.contains(#"image="exclamationmark.triangle.fill""#), "active ≠ failure glyph:\n\(tree)")
        XCTAssertFalse(tree.contains(#"image="person.crop.circle.badge.exclamationmark""#), "active ≠ awaiting glyph:\n\(tree)")
        XCTAssertFalse(tree.contains(#"image="circle""#), "active ≠ pending circle glyph:\n\(tree)")
        // The active human-facing line renders (the row's text is captured).
        XCTAssertTrue(tree.contains("Bringing Workbench online…"), "active step → its human line:\n\(tree)")
        try assertViewSnapshot(of: FirstRunStepRow(row: row), named: "FirstRunStepRow.active")
    }

    /// NEGATIVE CONTROL — only the `.active` state renders the no-glyph ProgressView arm: flipping
    /// the row to pending makes the `circle` glyph appear (the `.isActive` guard no longer holds),
    /// so the trees differ. Proves the `if row.isActive` branch is load-bearing.
    func testStepRow_negativeControl_activeArmIsLoadBearing() throws {
        let active = try ViewSnapshotHost.snapshotText(of: FirstRunStepRow(row: activeRow()))
        let pending = try ViewSnapshotHost.snapshotText(of:
            FirstRunStepRow(row: BootstrapStepProgress(step: .ensureDaemon, state: .pending)))
        XCTAssertNotEqual(active, pending, "the .isActive guard flips the icon arm vs pending")
        XCTAssertFalse(active.contains(#"image="circle""#), "active: no pending circle:\n\(active)")
        XCTAssertTrue(pending.contains(#"image="circle""#), "pending: the circle glyph:\n\(pending)")
    }

    // MARK: - Determinism (P3)

    func testStepRow_done_twiceRunByteIdentical_noLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: FirstRunStepRow(row: verifiedRow()))
        let b = try ViewSnapshotHost.snapshotText(of: FirstRunStepRow(row: verifiedRow()))
        XCTAssertEqual(a, b, "the done step leaf must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }
}
#endif
