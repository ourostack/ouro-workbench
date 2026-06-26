#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C2-3 — `MailboxWarningView` (the dashboard strip's mailbox-warning banner). It renders
/// `Text("Mailbox warnings: \(issues.joined(separator: "; "))")` — a CAPTURED `Text`
/// whose string flips with the `issues` array (the host whitelist captures `Text`
/// strings). Re-confirmed LOGIC at execution by the C1 `SidebarCountBadge` value-flip
/// standard (the first-pass branchless binning is superseded).
///
/// **Provenance (P2).** The `issues` are provenance-built through their REAL producer —
/// `BossDashboardAvailability.mailbox(machineIssue:needsMeIssue:codingIssue:
/// habitHistoryIssue:)` — the exact factory `refreshBossDashboard()` calls to assemble
/// the availability the dashboard carries. The caller renders the view only when
/// `!dashboard.availability.issues.isEmpty`, so we drive the same `.issues` the live
/// pane reads. (We do NOT hand-assemble the array; we build it through the factory.)
///
/// **Determinism (P3).** The issue strings are fixed label-prefixed copy (no machine
/// path / clock / UUID). The `.help(...)` tooltip is dropped by the host (AN-004).
/// Byte-identical twice + `!contains("/Users/")`.
///
/// **Enumerated state-set (the captured `Text` value-flips):**
///   - `single`   — one probe issue → "Mailbox warnings: <one>".
///   - `multiple` — several issues, `; `-joined → "Mailbox warnings: a; b; c".
/// (The caller's `!issues.isEmpty` guard means the empty case never constructs this view
/// — there is no zero-issue tree to enumerate; that gate is covered in C2-7's
/// `BossDashboardView` state-set.)
@MainActor
final class MailboxWarningViewStateSetTests: XCTestCase {

    /// Build the real availability through the production factory, then take its `.issues`
    /// — the same array `BossDashboardView` feeds `MailboxWarningView`.
    private func issues(
        machine: String? = nil,
        needsMe: String? = nil,
        coding: String? = nil,
        habit: String? = nil
    ) -> [String] {
        BossDashboardAvailability.mailbox(
            machineIssue: machine,
            needsMeIssue: needsMe,
            codingIssue: coding,
            habitHistoryIssue: habit
        ).issues
    }

    func testWarning_single() throws {
        let issues = issues(needsMe: "needs-me: timed out")
        XCTAssertEqual(issues, ["needs-me: timed out"], "provenance: one probe issue")
        try assertViewSnapshot(of: MailboxWarningView(issues: issues), named: "MailboxWarningView.single")
    }

    func testWarning_multiple() throws {
        let issues = issues(
            machine: "machine: unreachable",
            coding: "coding: probe failed",
            habit: "habit-history: timed out")
        XCTAssertEqual(issues.count, 3, "provenance: three probe issues, compacted in factory order")
        try assertViewSnapshot(of: MailboxWarningView(issues: issues), named: "MailboxWarningView.multiple")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The `issues` array drives the captured warning `Text`. Distinct issue sets must
    /// produce distinct trees (the value-flip the false-coverage binning hid).
    func testWarning_negativeControl_issuesFlipTree() throws {
        let one = try ViewSnapshotHost.snapshotText(of: MailboxWarningView(issues: issues(needsMe: "needs-me: timed out")))
        let many = try ViewSnapshotHost.snapshotText(of: MailboxWarningView(issues: issues(
            machine: "machine: unreachable", coding: "coding: probe failed")))
        XCTAssertNotEqual(one, many, "the issues array must drive the captured warning Text")
        XCTAssertTrue(one.contains("Mailbox warnings: needs-me: timed out"), one)
        XCTAssertTrue(many.contains("Mailbox warnings: machine: unreachable; coding: probe failed"), many)
    }

    // MARK: - Determinism (P3)

    func testWarning_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, [String])] = [
            ("single", issues(needsMe: "needs-me: timed out")),
            ("multiple", issues(machine: "machine: unreachable", coding: "coding: probe failed", habit: "habit-history: timed out"))
        ]
        for (name, list) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: MailboxWarningView(issues: list))
            let b = try ViewSnapshotHost.snapshotText(of: MailboxWarningView(issues: list))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
