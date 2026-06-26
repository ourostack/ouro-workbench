#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C5-2 — `ReportBugSheet` SUCCESS states (the `if let url = model.lastBugReportURL` green
/// result box, #U30). After a bundle is written the sheet shows a result block whose nested
/// gates each flip a CAPTURED subtree:
///   - `Label("Saved bug report: \(url.lastPathComponent)", …checkmark.circle.fill)` — the
///       saved-bundle confirmation (renders ONLY the bundle's LAST path component, the
///       path-leak vector pinned by a fixed URL — see Determinism).
///   - `ForEach(model.lastBugReportWarnings)` → an orange warning `Label` per warning.
///   - `if model.bugReportIssueURL == nil` → the "File as GitHub Issue" button (the gate
///       flips: once an issue is filed the button DISAPPEARS).
///   - `if let issueURL = model.bugReportIssueURL` → the green "Filed: \(issueURL)" Label.
///   - `if let issueError = model.bugReportIssueError` → the orange issue-error Label.
///
/// **Provenance (P2).** Every state is built through the REAL model seam: `lastBugReportURL`,
/// `lastBugReportWarnings`, `bugReportIssueURL`, and `bugReportIssueError` are the SAME
/// writable `@Published` the live submit + file-as-issue flows (`submitBugReport()` /
/// `fileLastBugReportAsGitHubIssue()`) set — direct injection IS the production seam (the
/// AN-001 / BossDashboard precedent). `model` is built via the `makeVM` dual-injection store
/// seam (AN-001 hermetic).
///
/// **Determinism (P3) — the path-leak fix.** `lastBugReportURL` is a machine-derived `URL`,
/// but the view renders ONLY `url.lastPathComponent`. The fixture uses a FIXED relative-style
/// URL (`/tmp/u4/bug-reports/bug-report-2026-06-25-000000`) so the rendered last component is
/// byte-stable AND no `/Users/…` reaches the tree. The issue URL / warnings / issue-error are
/// fixed fixture strings (no machine content). Byte-identical twice + `!contains("/Users/")`.
///
/// **Enumerated SUCCESS state-set:**
///   - `success`            — `lastBugReportURL` set + two warnings, `bugReportIssueURL ==
///       nil` → the saved Label + the warning Labels + the "File as GitHub Issue" button.
///   - `successWithIssueURL`— `lastBugReportURL` + `bugReportIssueURL` set → the "Filed: …"
///       Label renders AND the "File as GitHub Issue" button DISAPPEARS (the `== nil` gate).
///   - `successWithIssueError` — `lastBugReportURL` + `bugReportIssueError` set → the orange
///       issue-error Label renders (the file-as-issue failure path).
@MainActor
final class ReportBugSheetSuccessStateSetTests: XCTestCase {

    /// A FIXED bundle URL — only its `lastPathComponent` reaches the tree (path-leak fix).
    private static let fixedBundleURL = URL(
        fileURLWithPath: "/tmp/u4/bug-reports/bug-report-2026-06-25-000000", isDirectory: true)
    private static let fixedIssueURL = "https://github.com/example/repo/issues/42"

    // MARK: - Hermetic model (AN-001 dual-injection)

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c5-reportbug-success-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"))
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// A model with the saved-bundle result populated (the `if let url` gate open).
    private func savedModel(warnings: [String] = ["Screenshot capture skipped (no window)."]) throws
        -> WorkbenchViewModel
    {
        let model = try makeVM()
        model.lastBugReportURL = Self.fixedBundleURL
        model.lastBugReportWarnings = warnings
        return model
    }

    // MARK: - Enumerated state-set

    func testReportBug_success() throws {
        let model = try savedModel(warnings: [
            "Screenshot capture skipped (no window).",
            "Diagnostics zip omitted (collector unavailable)."
        ])
        XCTAssertNotNil(model.lastBugReportURL, "provenance: a saved bundle")
        XCTAssertNil(model.bugReportIssueURL, "provenance: not yet filed → the file button shows")
        let tree = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: model))
        XCTAssertTrue(tree.contains("Saved bug report: bug-report-2026-06-25-000000"),
                      "success: the saved Label renders the bundle's last path component:\n\(tree)")
        XCTAssertTrue(tree.contains("checkmark.circle.fill"), "success: the green check glyph:\n\(tree)")
        XCTAssertTrue(tree.contains("Screenshot capture skipped (no window)."),
                      "success: the first warning Label renders:\n\(tree)")
        XCTAssertTrue(tree.contains("Diagnostics zip omitted (collector unavailable)."),
                      "success: the second warning Label renders:\n\(tree)")
        XCTAssertTrue(tree.contains("File as GitHub Issue"),
                      "success: the file-as-issue button shows (bugReportIssueURL == nil):\n\(tree)")
        XCTAssertFalse(tree.contains("Filed:"), "success: not yet filed → no Filed label:\n\(tree)")
        try assertViewSnapshot(of: ReportBugSheet(model: model), named: "ReportBugSheet.success")
    }

    func testReportBug_successWithIssueURL() throws {
        let model = try savedModel(warnings: [])
        model.bugReportIssueURL = Self.fixedIssueURL
        XCTAssertNotNil(model.bugReportIssueURL, "provenance: an issue was filed")
        let tree = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: model))
        XCTAssertTrue(tree.contains("Filed: \(Self.fixedIssueURL)"),
                      "successWithIssueURL: the Filed label renders the issue URL:\n\(tree)")
        XCTAssertTrue(tree.contains("checkmark.seal.fill"), "the filed-seal glyph:\n\(tree)")
        XCTAssertTrue(tree.contains("Open Issue"), "the Open Issue button:\n\(tree)")
        XCTAssertFalse(tree.contains("File as GitHub Issue"),
                       "the file button DISAPPEARS once filed (the == nil gate flips):\n\(tree)")
        try assertViewSnapshot(of: ReportBugSheet(model: model), named: "ReportBugSheet.successWithIssueURL")
    }

    func testReportBug_successWithIssueError() throws {
        let model = try savedModel(warnings: [])
        model.bugReportIssueError = "gh is not authenticated. Run `gh auth login`."
        XCTAssertNotNil(model.bugReportIssueError, "provenance: filing failed")
        let tree = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: model))
        XCTAssertTrue(tree.contains("gh is not authenticated. Run `gh auth login`."),
                      "successWithIssueError: the issue-error Label renders:\n\(tree)")
        // Still unfiled → the file button is still offered.
        XCTAssertTrue(tree.contains("File as GitHub Issue"),
                      "still unfiled → the file button remains:\n\(tree)")
        try assertViewSnapshot(of: ReportBugSheet(model: model), named: "ReportBugSheet.successWithIssueError")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The success gates flip whole captured subtrees: the saved box (nil vs set URL), the
    /// "Filed:" label + the file-button disappearance (issueURL nil vs set), and the issue-error
    /// label (nil vs set) each appear only when their seam is populated.
    func testReportBug_negativeControl_successGatesFlipTree() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: try makeVM()))
        let saved = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: try savedModel()))
        XCTAssertNotEqual(empty, saved, "the lastBugReportURL gate must flip the captured tree")
        XCTAssertFalse(empty.contains("Saved bug report"), "empty: no success box:\n\(empty)")
        XCTAssertTrue(saved.contains("Saved bug report"), "saved: the success box renders:\n\(saved)")

        let filedModel = try savedModel(warnings: [])
        filedModel.bugReportIssueURL = Self.fixedIssueURL
        let filed = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: filedModel))
        XCTAssertNotEqual(saved, filed, "the bugReportIssueURL gate must flip the captured tree")
        XCTAssertTrue(saved.contains("File as GitHub Issue"), "unfiled: the file button shows:\n\(saved)")
        XCTAssertFalse(filed.contains("File as GitHub Issue"), "filed: the file button is gone:\n\(filed)")
        XCTAssertTrue(filed.contains("Filed:"), "filed: the Filed label renders:\n\(filed)")
    }

    // MARK: - Determinism (P3 — incl. the path-leak defense)

    func testReportBug_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let builders: [(String, () throws -> WorkbenchViewModel)] = [
            ("success", { try self.savedModel(warnings: ["w1", "w2"]) }),
            ("successWithIssueURL", {
                let m = try self.savedModel(warnings: [])
                m.bugReportIssueURL = Self.fixedIssueURL
                return m
            }),
            ("successWithIssueError", {
                let m = try self.savedModel(warnings: [])
                m.bugReportIssueError = "gh missing"
                return m
            })
        ]
        for (name, makeModel) in builders {
            let model = try makeModel()
            let a = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: model))
            let b = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: model))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"),
                           "\(name): no machine-path leak (only the fixed lastPathComponent shows):\n\(a)")
        }
    }
}
#endif
