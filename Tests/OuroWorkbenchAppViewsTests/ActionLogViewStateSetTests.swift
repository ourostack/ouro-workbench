#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C10-2 — the boss action-log strip (`ActionLogView` `:7766`). A leaf `View` that takes a fixed
/// `[WorkbenchActionLogEntry]` directly → constructing it standalone IS the legitimate seam
/// (the SU3r leaf pattern; the two parents — the advanced cluster + `BossActionReceiptStrip` —
/// embed it via `ForEach`/disclosure, covered in their own surfaces).
///
/// **Clock migration (AN-007 — the C10 named hazard).** The per-entry timestamp at `:7838` was a
/// raw `entry.occurredAt.formatted(date:.omitted, time:.standard)` (unpinnable at read-time — a
/// PDT-recorded ref mismatches a UTC runner, the C0 root cause). It is MIGRATED to the shared
/// `Date.workbenchTimeText(date:time:timeZone:locale:)` seam — production defaults to
/// `.autoupdatingCurrent` for both (operator-local, BYTE-IDENTICAL to the prior `.formatted`),
/// the test injects `.gmt` + `en_GB` so the timestamp renders byte-identically on any CI runner
/// zone/locale. (Same prod-byte-identical migration C4 `DecisionLogRow` did.)
///
/// **Provenance (P2).** Each `WorkbenchActionLogEntry` is built via its REAL public initializer
/// (the same type the persisted `actionLog` decodes to) with a FIXED `occurredAt` + `id`. The
/// icon/color flow through the REAL pure `WorkbenchActionOutcomePresentation` seam (a settled
/// success → green check; a settled failure → orange triangle; an in-flight ack → neutral
/// ellipsis — never a false green). No serializer output is hand-assembled.
///
/// **`@State isExpanded` arm (structurally-unreachable in a snapshot — recorded, not fabricated).**
/// `isExpanded` defaults to `false`; ViewInspector's synchronous `inspect()` renders the INITIAL
/// state, so the view always shows the COLLAPSED single-entry arm (`entries.first` + the
/// "N recent" count + the toggle), never the expanded 6-row `ForEach` (reachable only by firing
/// the toggle Button's closure, which `inspect()` does not do). Classified below, not fabricated
/// (the C1/AN-006/C4 `taught` discipline).
@MainActor
final class ActionLogViewStateSetTests: XCTestCase {

    /// A single canonical fixed epoch — 2026-01-02 03:04:05 UTC. Under the injected `.gmt` zone
    /// + `en_GB` locale, `workbenchTimeText(date:.omitted, time:.standard)` renders a clean ASCII
    /// `3:04:05` byte-identically on any runner (the C4 finding: `en_GB` avoids the U+202F
    /// narrow-no-break-space `en_US_POSIX` injects before AM/PM).
    private static let fixedDate = Date(timeIntervalSince1970: 1_767_323_045)
    private static let clockLocale = Locale(identifier: "en_GB")
    private static let entryId = UUID(uuidString: "AC710000-0000-0000-0000-00000000000A")!

    private func entry(
        source: String = "boss",
        action: String = "approve",
        targetName: String? = "deploy-runner",
        result: String = "applied migration",
        succeeded: Bool = true,
        isInFlight: Bool = false,
        id: UUID = entryId
    ) -> WorkbenchActionLogEntry {
        WorkbenchActionLogEntry(
            id: id, occurredAt: Self.fixedDate, source: source, action: action,
            targetName: targetName, result: result, succeeded: succeeded, isInFlight: isInFlight
        )
    }

    private func view(_ entries: [WorkbenchActionLogEntry]) -> ActionLogView {
        ActionLogView(entries: entries, timeZone: .gmt, locale: Self.clockLocale)
    }

    // MARK: - Enumerated state-set (the collapsed arm's data-driven branches)

    /// EMPTY — `entries.isEmpty` → the whole view renders nothing.
    func testLog_empty_rendersNothing() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: view([]))
        XCTAssertTrue(tree.isEmpty, "an empty action log renders nothing:\n\(tree)")
        try assertViewSnapshot(of: view([]), named: "ActionLogView.empty")
    }

    /// A settled SUCCESS — the green checkmark glyph + the fixed timestamp + source/action +
    /// target + result.
    func testLog_settledSuccess() throws {
        let view = view([entry(succeeded: true)])
        let tone = WorkbenchActionOutcomePresentation.tone(isInFlight: false, succeeded: true)
        XCTAssertEqual(WorkbenchActionOutcomePresentation.iconSystemName(for: tone),
                       "checkmark.circle.fill", "provenance: a settled success → the green check")
        try assertViewSnapshot(of: view, named: "ActionLogView.settledSuccess")
    }

    /// A settled FAILURE — the orange triangle glyph (the captured SF-symbol flips vs success).
    func testLog_settledFailure() throws {
        let view = view([entry(action: "repair", result: "exit 1", succeeded: false)])
        let tone = WorkbenchActionOutcomePresentation.tone(isInFlight: false, succeeded: false)
        XCTAssertEqual(WorkbenchActionOutcomePresentation.iconSystemName(for: tone),
                       "exclamationmark.triangle.fill", "provenance: a settled failure → orange triangle")
        try assertViewSnapshot(of: view, named: "ActionLogView.settledFailure")
    }

    /// An IN-FLIGHT optimistic ack — neutral pending glyph, NEVER a false green check (the
    /// honest-presentation seam: `succeeded == true` but unsettled → pending).
    func testLog_inFlightPending() throws {
        let view = view([entry(action: "verify", result: "working…", succeeded: true, isInFlight: true)])
        let tone = WorkbenchActionOutcomePresentation.tone(isInFlight: true, succeeded: true)
        XCTAssertNotEqual(WorkbenchActionOutcomePresentation.iconSystemName(for: tone),
                          "checkmark.circle.fill", "provenance: an in-flight ack is NOT a green check")
        try assertViewSnapshot(of: view, named: "ActionLogView.inFlightPending")
    }

    /// No target — the optional `targetName` arm absent (only the source/action + result render).
    func testLog_noTarget() throws {
        let view = view([entry(targetName: nil)])
        try assertViewSnapshot(of: view, named: "ActionLogView.noTarget")
    }

    // MARK: - @State isExpanded arm (structurally-unreachable in a snapshot — recorded)

    /// With MORE than one entry the collapsed arm still renders only the FIRST (the `entries.first`
    /// branch + the "N recent" count); the expanded 6-row `ForEach` is unreachable in a snapshot
    /// (`@State isExpanded == false`). Asserted via the captured tree — classified, not fabricated.
    func testLog_collapsedShowsFirstOnly_expandedArmUnreachable() throws {
        let many = (0..<3).map { i in
            entry(action: "act\(i)", result: "result\(i)",
                  id: UUID(uuidString: "AC710000-0000-0000-0000-00000000000\(i)")!)
        }
        let tree = try ViewSnapshotHost.snapshotText(of: view(many))
        XCTAssertTrue(tree.contains("3 recent"), "the count reflects all entries:\n\(tree)")
        XCTAssertTrue(tree.contains("result0"), "the collapsed arm shows the first entry")
        XCTAssertFalse(tree.contains("result1"),
                       "the expanded ForEach is structurally unreachable (@State isExpanded==false)")
    }

    // MARK: - Clock determinism (P3 — AN-007)

    func testLog_clockDeterminism_byteIdenticalTwiceAndFixedTimestamp() throws {
        let a = try ViewSnapshotHost.snapshotText(of: view([entry()]))
        let b = try ViewSnapshotHost.snapshotText(of: view([entry()]))
        XCTAssertEqual(a, b, "the fixed-timestamp action-log row must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
        XCTAssertTrue(a.contains("3:04:05"),
                      "the migrated seam renders the fixed epoch as a stable .gmt/en_GB clock:\n\(a)")
    }

    /// Cross-TZ/locale PROOF (AN-007): the SAME injected `.gmt`+`en_GB` seam renders the timestamp
    /// byte-identically regardless of the PROCESS TimeZone — directly mutate `TZ` across
    /// {PDT, EDT, UTC} and assert the tree is invariant. (Production reads `.autoupdatingCurrent`,
    /// so this proves the injected-seam snapshot is runner-zone-independent.)
    func testLog_crossTimeZone_byteIdenticalAcrossPDTEDTUTC() throws {
        let original = ProcessInfo.processInfo.environment["TZ"]
        defer {
            if let original { setenv("TZ", original, 1) } else { unsetenv("TZ") }
            tzset(); NSTimeZone.resetSystemTimeZone()
        }
        var trees: [String] = []
        for tz in ["America/Los_Angeles", "America/New_York", "UTC"] {
            setenv("TZ", tz, 1); tzset(); NSTimeZone.resetSystemTimeZone()
            trees.append(try ViewSnapshotHost.snapshotText(of: view([entry()])))
        }
        XCTAssertEqual(Set(trees).count, 1,
                       "the .gmt/en_GB-injected timestamp must be byte-identical across PDT/EDT/UTC:\n\(trees)")
        XCTAssertTrue(trees[0].contains("3:04:05"), "and renders the fixed .gmt clock:\n\(trees[0])")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The settled outcome flips the captured SF-symbol glyph (green check ↔ orange triangle), and
    /// the optional target arm appears/vanishes — real data-driven branches.
    func testLog_negativeControl_outcomeGlyphAndTargetFlipTree() throws {
        let success = try ViewSnapshotHost.snapshotText(of: view([entry(succeeded: true)]))
        let failure = try ViewSnapshotHost.snapshotText(of: view([entry(succeeded: false)]))
        let noTarget = try ViewSnapshotHost.snapshotText(of: view([entry(targetName: nil)]))

        XCTAssertNotEqual(success, failure, "the settled outcome must flip the glyph")
        XCTAssertTrue(success.contains("checkmark.circle.fill"), "success: green check:\n\(success)")
        XCTAssertTrue(failure.contains("exclamationmark.triangle.fill"), "failure: orange triangle:\n\(failure)")
        XCTAssertFalse(failure.contains("checkmark.circle.fill"), "failure: not a green check")

        XCTAssertNotEqual(success, noTarget, "the optional targetName arm must flip the tree")
        XCTAssertTrue(success.contains("deploy-runner"), "with-target: the target name renders")
        XCTAssertFalse(noTarget.contains("deploy-runner"), "no-target: the target name is absent")
    }
}
#endif
