#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C10-3 — the default boss-pane action-receipt strip (`BossActionReceiptStrip` `:7885`). Renders
/// the compact "Recent actions: N ok · N failed" line and surfaces failed receipts prominently
/// even when collapsed, so a FAILED autonomous action is never one disclosure away.
///
/// **Provenance (P2).** The strip reads `model.bossActionReceiptSummary`, which is
/// `BossActionReceiptSummary.summarize(state.actionLog, window: 10)` — a pure Core producer. Each
/// fixture is a real `WorkspaceState` whose `actionLog` is built from real
/// `WorkbenchActionLogEntry` initializers (fixed `occurredAt`/`id`) and assigned to the model's
/// live `@Published var state` (the EXACT property the summary derives from — the same direct
/// injection the production async action handlers use). NEVER a hand-assembled summary.
///
/// **No visible timestamp in the reachable arms.** The collapsed strip + its failed-receipt rows
/// render only counts / action / target / result — NO timestamp `Text`. The per-entry timestamp
/// lives ONLY in the expanded `ActionLogView` (`if isExpanded`), which is structurally unreachable
/// in a snapshot (`@State isExpanded == false`). So no cross-TZ proof is needed for this surface
/// (the strip's reachable tree carries no clock), and the expanded arm is recorded, not fabricated.
///
/// **Enumerated state-set (the strip's data-driven branches):**
///   - `empty`        — `summary.isEmpty` → the whole strip renders nothing (stays calm, no "0 ok").
///   - `allOk`        — settled successes only → "N ok", NO failed segment, NO failed-receipt rows.
///   - `withFailures` — settled failures present → the orange "N failed" count + the prominent
///                      collapsed failed-receipt rows (`summary.failedReceipts.prefix(2)`).
@MainActor
final class BossActionReceiptStripStateSetTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_767_323_045)

    private func makeVM(actionLog: [WorkbenchActionLogEntry]) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c10receipt-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
        // Assign the live @Published state the summary derives from (the real seam).
        model.state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"), actionLog: actionLog)
        return model
    }

    /// A settled receipt with a fixed id/timestamp (timestamp feeds only the unreachable expanded
    /// log + the summary's newest-first sort — never a reachable `Text`).
    private func entry(
        action: String, targetName: String?, result: String, succeeded: Bool,
        secondsOffset: TimeInterval = 0, id: UUID = UUID()
    ) -> WorkbenchActionLogEntry {
        WorkbenchActionLogEntry(
            id: id, occurredAt: Self.fixedDate.addingTimeInterval(secondsOffset),
            source: "boss", action: action, targetName: targetName,
            result: result, succeeded: succeeded
        )
    }

    private func strip(_ actionLog: [WorkbenchActionLogEntry]) throws -> BossActionReceiptStrip {
        BossActionReceiptStrip(model: try makeVM(actionLog: actionLog))
    }

    // MARK: - Enumerated state-set

    /// EMPTY — no settled receipts → `summary.isEmpty` → the strip renders nothing.
    func testStrip_empty_rendersNothing() throws {
        let strip = try strip([])
        XCTAssertTrue(strip.model.bossActionReceiptSummary.isEmpty,
                      "provenance: an empty action log → an empty summary")
        try assertViewSnapshot(of: strip, named: "BossActionReceiptStrip.empty")
    }

    /// ALL-OK — two settled successes → "2 ok", no failed segment, no failed-receipt rows.
    func testStrip_allOk() throws {
        let log = [
            entry(action: "approve", targetName: "deploy-runner", result: "applied", succeeded: true),
            entry(action: "ack", targetName: "build", result: "acknowledged", succeeded: true)
        ]
        let strip = try strip(log)
        let summary = strip.model.bossActionReceiptSummary
        XCTAssertEqual([summary.okCount, summary.failedCount], [2, 0], "provenance: 2 ok, 0 failed")
        XCTAssertFalse(summary.hasFailures, "provenance: no failures → no failed segment")
        try assertViewSnapshot(of: strip, named: "BossActionReceiptStrip.allOk")
    }

    /// WITH-FAILURES — one success + one failure → the orange "1 failed" count + the prominent
    /// collapsed failed-receipt row (the `else if summary.hasFailures` reachable arm).
    func testStrip_withFailures() throws {
        let log = [
            entry(action: "approve", targetName: "deploy-runner", result: "applied",
                  succeeded: true, secondsOffset: 10),
            entry(action: "repair", targetName: "verify-provider", result: "exit 1",
                  succeeded: false, secondsOffset: 20)
        ]
        let strip = try strip(log)
        let summary = strip.model.bossActionReceiptSummary
        XCTAssertEqual([summary.okCount, summary.failedCount], [1, 1], "provenance: 1 ok, 1 failed")
        XCTAssertTrue(summary.hasFailures, "provenance: a settled failure → hasFailures")
        XCTAssertEqual(summary.failedReceipts.first?.action, "repair",
                       "provenance: the failed receipt surfaces newest-first")
        try assertViewSnapshot(of: strip, named: "BossActionReceiptStrip.withFailures")
    }

    // MARK: - @State isExpanded arm (structurally-unreachable — recorded, not fabricated)

    /// `@State isExpanded` defaults to `false`; the expanded `ActionLogView` (`if isExpanded`) is
    /// never constructed in a snapshot, so the strip shows the COLLAPSED disclosure (the
    /// `chevron.down` glyph), never the expanded full log. Asserted via the captured tree.
    func testStrip_collapsedByDefault_expandedLogUnreachable() throws {
        let log = [entry(action: "approve", targetName: "x", result: "ok", succeeded: true)]
        let tree = try ViewSnapshotHost.snapshotText(of: try strip(log))
        XCTAssertTrue(tree.contains("chevron.down"),
                      "the initial @State isExpanded==false renders the collapsed chevron:\n\(tree)")
        XCTAssertFalse(tree.contains("chevron.up"),
                       "the expanded ActionLogView arm is structurally unreachable in a snapshot")
    }

    // MARK: - Determinism (P3)

    func testStrip_determinism_byteIdenticalTwiceNoLeak() throws {
        let log = [entry(action: "repair", targetName: "x", result: "exit 1", succeeded: false)]
        let a = try ViewSnapshotHost.snapshotText(of: try strip(log))
        let b = try ViewSnapshotHost.snapshotText(of: try strip(log))
        XCTAssertEqual(a, b, "the strip must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
        XCTAssertFalse(a.contains("/var/folders/"), "no temp-dir path leak:\n\(a)")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The presence of a settled failure flips the tree: it adds the orange "N failed" count + the
    /// prominent failed-receipt row that an all-ok summary never renders — a real summary-driven
    /// branch (`summary.hasFailures`).
    func testStrip_negativeControl_failuresFlipTree() throws {
        let okLog = [entry(action: "approve", targetName: "x", result: "applied", succeeded: true)]
        let failLog = [
            entry(action: "approve", targetName: "x", result: "applied", succeeded: true, secondsOffset: 10),
            entry(action: "repair", targetName: "verify-provider", result: "exit 1", succeeded: false, secondsOffset: 20)
        ]
        let ok = try ViewSnapshotHost.snapshotText(of: try strip(okLog))
        let fail = try ViewSnapshotHost.snapshotText(of: try strip(failLog))

        XCTAssertNotEqual(ok, fail, "a settled failure must flip the tree")
        XCTAssertFalse(ok.contains("failed"), "all-ok: no failed segment:\n\(ok)")
        XCTAssertTrue(fail.contains("1 failed"), "with-failures: the orange failed count renders:\n\(fail)")
        XCTAssertTrue(fail.contains("verify-provider"),
                      "with-failures: the prominent collapsed failed-receipt row renders")
        XCTAssertFalse(ok.contains("verify-provider"), "all-ok: no failed-receipt row")
    }
}
#endif
