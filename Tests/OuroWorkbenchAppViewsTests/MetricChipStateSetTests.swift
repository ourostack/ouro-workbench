#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C2-2 — the dashboard-strip metric chip leaves: `MetricChip` and `MetricStateChip`.
/// Both carry a data-driven `if` that flips a CAPTURED node (the host whitelist captures
/// `Text` strings + `Image` SF-symbol names):
///   - `MetricChip`: `if tap != nil` adds the `arrow.up.right` "door" glyph `Image` (and
///     wraps the chip in a `Button`) — the inert-chip vs tappable-door flip.
///   - `MetricStateChip`: `if presentation.isUnavailable` adds the `info.circle` glyph
///     `Image` (and, with a retry handler, the `arrow.clockwise` retry `Image`) — the
///     real-value vs not-a-value flip the #U23b strip exists to surface.
/// These are the leaves `DashboardMetricsStrip` / `WorkbenchVisibilityStrip` compose, so
/// covering them here is the cheapest seam for the strip's per-metric states (C2-6 then
/// covers the strips' composition).
///
/// **Provenance (P2).** `MetricStateChip`'s `presentation` is provenance-built through
/// its REAL producer — `MetricValuePresentation.resolve(value:isAvailable:issue:)` /
/// `resolve(text:isAvailable:issue:)` — the exact resolver `DashboardMetricsStrip` calls
/// per chip. We do NOT hand-assemble the presentation; we drive the real resolver so the
/// chip renders the SAME value/glyph the live strip would. The chips are instantiated
/// DIRECTLY via their `View` initializers (the leaf seam; the C0-chip precedent).
///
/// **Determinism (P3).** Fixed labels/values + a fixed issue string (no machine path /
/// clock / UUID). The `.help(...)` tooltip is dropped by the host (AN-004). Byte-identical
/// twice + `!contains("/Users/")`.
///
/// **Enumerated state-set:**
///   `MetricChip`:
///     - `inert`   — `tap == nil` → value + label `Text`, NO door glyph.
///     - `tappable`— `tap != nil` → value + label `Text` + the `arrow.up.right` glyph.
///   `MetricStateChip`:
///     - `value`       — a real number (`isAvailable`) → the number `Text`, NO info glyph.
///     - `zero`        — a genuine zero (distinct from unavailable) → "0" `Text`, no glyph.
///     - `unavailableNoRetry` — `isAvailable == false`, no `onRetry` → the muted dash
///         "—" + the `info.circle` glyph, NO retry glyph.
///     - `unavailableRetry`   — unavailable WITH an `onRetry` → dash + `info.circle` +
///         the `arrow.clockwise` retry glyph (the captured retry affordance).
@MainActor
final class MetricChipStateSetTests: XCTestCase {

    // MARK: - MetricChip (the inert-vs-door flip)

    func testMetricChip_inert() throws {
        let view = MetricChip(label: "claims", value: "ok", tap: nil)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertFalse(tree.contains("arrow.up.right"), "inert: no door glyph:\n\(tree)")
        try assertViewSnapshot(of: view, named: "MetricChip.inert")
    }

    func testMetricChip_tappable() throws {
        let view = MetricChip(label: "inbox", value: "2", tap: {})
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("arrow.up.right"), "tappable: the door glyph renders:\n\(tree)")
        try assertViewSnapshot(of: view, named: "MetricChip.tappable")
    }

    // MARK: - MetricStateChip (the real-value-vs-unavailable flip; the REAL resolver)

    func testMetricStateChip_value() throws {
        let presentation = MetricValuePresentation.resolve(value: 3, isAvailable: true, issue: nil)
        XCTAssertFalse(presentation.isUnavailable, "provenance: a present, available value")
        XCTAssertEqual(presentation.text, "3")
        let view = MetricStateChip(label: "needs me", presentation: presentation, onRetry: nil)
        try assertViewSnapshot(of: view, named: "MetricStateChip.value")
    }

    func testMetricStateChip_zero_distinctFromUnavailable() throws {
        // A genuine zero is NOT unavailable — the #U23b distinction the chip exists to keep.
        let presentation = MetricValuePresentation.resolve(value: 0, isAvailable: true, issue: nil)
        XCTAssertFalse(presentation.isUnavailable, "provenance: a genuine zero is a real value")
        XCTAssertEqual(presentation.text, "0")
        let view = MetricStateChip(label: "blocked", presentation: presentation, onRetry: nil)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertFalse(tree.contains("info.circle"), "zero: no unavailable info glyph:\n\(tree)")
        try assertViewSnapshot(of: view, named: "MetricStateChip.zero")
    }

    func testMetricStateChip_unavailableNoRetry() throws {
        let presentation = MetricValuePresentation.resolve(
            value: nil, isAvailable: false, issue: "needs-me: timed out")
        XCTAssertTrue(presentation.isUnavailable, "provenance: unavailable probe")
        XCTAssertEqual(presentation.text, "—", "provenance: the muted dash, not a number")
        let view = MetricStateChip(label: "needs me", presentation: presentation, onRetry: nil)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("info.circle"), "unavailable: the info glyph renders:\n\(tree)")
        XCTAssertFalse(tree.contains("arrow.clockwise"), "no onRetry: no retry glyph:\n\(tree)")
        try assertViewSnapshot(of: view, named: "MetricStateChip.unavailableNoRetry")
    }

    func testMetricStateChip_unavailableRetry() throws {
        let presentation = MetricValuePresentation.resolve(
            value: nil, isAvailable: false, issue: "coding: probe failed")
        XCTAssertTrue(presentation.canRetry, "provenance: unavailable → retryable")
        let view = MetricStateChip(label: "coding", presentation: presentation, onRetry: {})
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("info.circle"), "unavailable: the info glyph renders:\n\(tree)")
        XCTAssertTrue(tree.contains("arrow.clockwise"), "with onRetry: the retry glyph renders:\n\(tree)")
        try assertViewSnapshot(of: view, named: "MetricStateChip.unavailableRetry")
    }

    // MARK: - U5 B8 — retry Button INTERACTION (drive the `onRetry()` action closure)

    /// U5 B8 — `MetricStateChip`'s retry `Button` action (`:5697` — `Button { onRetry() }`). The
    /// existing `unavailableRetry` test RENDERS the retry glyph but never INVOKES the action. Here
    /// an unavailable+retryable presentation makes the retry button reachable; we FIND it and
    /// `.tap()` it → the `onRetry` closure fires → a recorded flag flips. ASSERT the side-effect.
    func testMetricStateChip_retryTap_firesOnRetry() throws {
        var retried = 0
        let presentation = MetricValuePresentation.resolve(
            value: nil, isAvailable: false, issue: "coding: probe failed")
        XCTAssertTrue(presentation.canRetry, "provenance: unavailable → the retry button renders")
        let view = MetricStateChip(label: "coding", presentation: presentation, onRetry: { retried += 1 })
        // The chip has exactly one Button (the retry affordance under `if presentation.isUnavailable`).
        try view.inspect().find(ViewType.Button.self).tap()
        XCTAssertEqual(retried, 1, "tapping the retry button fires the onRetry closure exactly once")
    }

    /// U5 B8 negative control (P2) — a real-VALUE (available) chip renders NO retry button, so the
    /// `if presentation.isUnavailable` / `if let onRetry, canRetry` gates are load-bearing: a button
    /// search finds nothing, proving the action closure is gated, not always present.
    func testMetricStateChip_value_noRetryButton() throws {
        let presentation = MetricValuePresentation.resolve(value: 7, isAvailable: true, issue: nil)
        XCTAssertFalse(presentation.isUnavailable, "provenance: an available value → no retry affordance")
        let view = MetricStateChip(label: "needs me", presentation: presentation, onRetry: { })
        XCTAssertThrowsError(try view.inspect().find(ViewType.Button.self),
                             "an available chip renders no retry button (the isUnavailable gate)")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `tap`/`isUnavailable` gates flip which captured glyphs render, and the resolved
    /// presentation text drives the value `Text`.
    func testMetricChip_negativeControl_gatesFlipGlyphs() throws {
        let inert = try ViewSnapshotHost.snapshotText(of: MetricChip(label: "x", value: "ok", tap: nil))
        let tappable = try ViewSnapshotHost.snapshotText(of: MetricChip(label: "x", value: "ok", tap: {}))
        XCTAssertNotEqual(inert, tappable, "the tap gate must add the door glyph")
        XCTAssertFalse(inert.contains("arrow.up.right"), inert)
        XCTAssertTrue(tappable.contains("arrow.up.right"), tappable)

        let value = try ViewSnapshotHost.snapshotText(of: MetricStateChip(
            label: "m", presentation: .resolve(value: 5, isAvailable: true, issue: nil), onRetry: nil))
        let unavailable = try ViewSnapshotHost.snapshotText(of: MetricStateChip(
            label: "m", presentation: .resolve(value: nil, isAvailable: false, issue: "x"), onRetry: {}))
        XCTAssertNotEqual(value, unavailable, "the isUnavailable gate must flip the tree")
        XCTAssertTrue(value.contains(#"text="5""#), "value: the number renders:\n\(value)")
        XCTAssertFalse(value.contains("info.circle"), "value: no info glyph:\n\(value)")
        XCTAssertTrue(unavailable.contains(#"text="—""#), "unavailable: the dash renders:\n\(unavailable)")
        XCTAssertTrue(unavailable.contains("info.circle"), "unavailable: the info glyph:\n\(unavailable)")
    }

    // MARK: - Determinism (P3)

    func testMetricChip_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("inert", { try ViewSnapshotHost.snapshotText(of: MetricChip(label: "claims", value: "ok", tap: nil)) }),
            ("tappable", { try ViewSnapshotHost.snapshotText(of: MetricChip(label: "inbox", value: "2", tap: {})) }),
            ("value", { try ViewSnapshotHost.snapshotText(of: MetricStateChip(
                label: "needs me", presentation: .resolve(value: 3, isAvailable: true, issue: nil), onRetry: nil)) }),
            ("unavailableRetry", { try ViewSnapshotHost.snapshotText(of: MetricStateChip(
                label: "coding", presentation: .resolve(value: nil, isAvailable: false, issue: "coding: probe failed"), onRetry: {})) })
        ]
        for (name, make) in cases {
            let a = try make()
            let b = try make()
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
