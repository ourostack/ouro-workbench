#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C11-4 — `ImportSummaryBanner` (the post-Bring-Back-Work receipt).
///
/// The slide-in banner that confirms what a `.workbench.json` import just did. Its
/// whole tree is driven through:
///   - `model.lastImportSummary` (the SAME `@Published` the live import-apply flow
///     sets) — the AN-001/BossDashboard/C5 direct-injection production seam;
///   - the pure Core `WorkbenchImportSummaryPresentation` (tone / icon / color /
///     not-persisted note) + the `WorkbenchImportApplyResult.headline` / `.detail`
///     derivations — all real producers, never hand-assembled.
///
/// **Reclassified LOGIC (reconfirm-by-mutation).** Five captured-node axes flip:
///   - `if let summary` — the whole banner appears/disappears (the Group gate);
///   - `Image(systemName: iconSystemName(tone))` — `checkmark.seal.fill` (success)
///     vs `exclamationmark.triangle.fill` (warning) — a captured SF-symbol flip
///     through the real `tone(persisted:createdCount:)` producer;
///   - `Text(summary.headline)` — "Brought back N terminals…" — the real producer;
///   - `if !summary.persisted` — the orange "lost on quit" note;
///   - `if let detail` — the skipped/duplicate-cleanup detail line;
///   - `if let entryID … model.state.processEntries.contains` — the "Open" button.
/// All proven by the negative control.
///
/// **Determinism (P3).** `WorkbenchImportApplyResult` fields are fixed fixture
/// values; no clock / path / machine-name / UUID renders on this banner (the
/// `firstSelectedEntryID` UUID is a GATE, never rendered) → no cross-TZ proof
/// needed (asserted: no `/Users/`, no `/var/folders/`, byte-identical twice).
@MainActor
final class ImportSummaryBannerTests: XCTestCase {

    private static let entryId = UUID(uuidString: "C1100004-0000-0000-0000-000000000001")!
    private static let projectId = UUID(uuidString: "C1100000-0000-0000-0000-0000000000B4")!

    private func makeVM(withEntry: Bool) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c11import-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let entries: [ProcessEntry] = withEntry
            ? [ProcessEntry(id: Self.entryId, projectId: Self.projectId, name: "build",
                            kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u4")]
            : []
        try WorkbenchStore(paths: paths).save(WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u4")],
            processEntries: entries))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func view(_ model: WorkbenchViewModel) -> ImportSummaryBanner { ImportSummaryBanner(model: model) }

    // MARK: - Enumerated state-set

    func testBanner_nilSummary_empty() throws {
        let model = try makeVM(withEntry: false)
        model.lastImportSummary = nil
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertFalse(tree.contains("Brought back"), "no summary → empty banner:\n\(tree)")
        XCTAssertFalse(tree.contains("checkmark.seal.fill"), "no summary → no icon:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "ImportSummaryBanner.nilSummary")
    }

    func testBanner_successPersisted_greenSeal() throws {
        let model = try makeVM(withEntry: false)
        model.lastImportSummary = WorkbenchImportApplyResult(
            createdCount: 2, groupNames: ["Home"], skippedNames: [],
            firstSelectedEntryID: nil, persisted: true)
        let summary = try XCTUnwrap(model.lastImportSummary)
        let tone = WorkbenchImportSummaryPresentation.tone(persisted: true, createdCount: 2)
        XCTAssertEqual(tone, .success, "provenance: a persisted import is the success tone")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertTrue(tree.contains(WorkbenchImportSummaryPresentation.iconSystemName(for: .success)),
                      "the green seal icon via the real producer:\n\(tree)")
        XCTAssertTrue(tree.contains(summary.headline),
                      "the headline via the real producer (\(summary.headline)):\n\(tree)")
        XCTAssertFalse(tree.contains(WorkbenchImportSummaryPresentation.notPersistedNote),
                       "persisted: no lost-on-quit note:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "ImportSummaryBanner.successPersisted")
    }

    func testBanner_notPersisted_orangeWarningWithNote() throws {
        let model = try makeVM(withEntry: false)
        model.lastImportSummary = WorkbenchImportApplyResult(
            createdCount: 1, groupNames: ["Home"], skippedNames: [],
            firstSelectedEntryID: nil, persisted: false)
        let tone = WorkbenchImportSummaryPresentation.tone(persisted: false, createdCount: 1)
        XCTAssertEqual(tone, .warning, "provenance: a failed write is the warning tone")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertTrue(tree.contains(WorkbenchImportSummaryPresentation.iconSystemName(for: .warning)),
                      "the warning-triangle icon via the real producer:\n\(tree)")
        XCTAssertTrue(tree.contains(WorkbenchImportSummaryPresentation.notPersistedNote),
                      "the lost-on-quit note via the real producer:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "ImportSummaryBanner.notPersisted")
    }

    func testBanner_withDetailAndOpen_button() throws {
        let model = try makeVM(withEntry: true)   // the entry must EXIST for the Open gate
        model.lastImportSummary = WorkbenchImportApplyResult(
            createdCount: 2, groupNames: ["Home", "Side"], skippedNames: ["broken-one"],
            firstSelectedEntryID: Self.entryId, persisted: true)
        let summary = try XCTUnwrap(model.lastImportSummary)
        let detail = try XCTUnwrap(summary.detail, "provenance: groupNames+skipped yield a detail line")
        XCTAssertTrue(model.state.processEntries.contains { $0.id == Self.entryId },
                      "provenance: the selected entry is present → the Open button gate is satisfied")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertTrue(tree.contains(detail), "the detail line via the real producer:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Open""#), "the Open button (entry present):\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "ImportSummaryBanner.withDetailAndOpen")
    }

    /// The Open button is gated on the entry STILL being present. With the same
    /// summary but the entry absent, the button must NOT render — proving the
    /// `processEntries.contains` half of the gate.
    func testBanner_openGate_absentEntryDropsButton() throws {
        let model = try makeVM(withEntry: false)   // entry NOT in state
        model.lastImportSummary = WorkbenchImportApplyResult(
            createdCount: 1, groupNames: ["Home"], skippedNames: [],
            firstSelectedEntryID: Self.entryId, persisted: true)
        XCTAssertFalse(model.state.processEntries.contains { $0.id == Self.entryId },
                       "provenance: the selected entry is absent → the Open gate fails")
        let tree = try ViewSnapshotHost.snapshotText(of: view(model))
        XCTAssertFalse(tree.contains(#"text="Open""#),
                       "absent entry: the Open button must NOT render:\n\(tree)")
        try assertViewSnapshot(of: view(model), named: "ImportSummaryBanner.openGateAbsent")
    }

    // MARK: - Determinism (P3)

    func testBanner_deterministic_byteIdenticalTwiceAndNoLeak() throws {
        func tree(persisted: Bool) throws -> String {
            let model = try makeVM(withEntry: false)
            model.lastImportSummary = WorkbenchImportApplyResult(
                createdCount: 2, groupNames: ["Home"], skippedNames: [],
                firstSelectedEntryID: nil, persisted: persisted)
            return try ViewSnapshotHost.snapshotText(of: view(model))
        }
        for persisted in [true, false] {
            let a = try tree(persisted: persisted); let b = try tree(persisted: persisted)
            XCTAssertEqual(a, b, "persisted=\(persisted) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
            XCTAssertFalse(a.contains("/var/folders/"), "no temp-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The persisted axis flips both the icon (seal vs triangle) and the not-persisted
    /// note; the summary gate flips the whole banner. This asserts all are non-vacuous.
    func testBanner_negativeControl_persistedAndSummaryGateFlipTree() throws {
        let nilModel = try makeVM(withEntry: false); nilModel.lastImportSummary = nil
        let empty = try ViewSnapshotHost.snapshotText(of: view(nilModel))

        let okModel = try makeVM(withEntry: false)
        okModel.lastImportSummary = WorkbenchImportApplyResult(
            createdCount: 1, groupNames: ["Home"], skippedNames: [], firstSelectedEntryID: nil, persisted: true)
        let ok = try ViewSnapshotHost.snapshotText(of: view(okModel))

        let warnModel = try makeVM(withEntry: false)
        warnModel.lastImportSummary = WorkbenchImportApplyResult(
            createdCount: 1, groupNames: ["Home"], skippedNames: [], firstSelectedEntryID: nil, persisted: false)
        let warn = try ViewSnapshotHost.snapshotText(of: view(warnModel))

        XCTAssertNotEqual(empty, ok, "the summary gate must flip the whole banner")
        XCTAssertNotEqual(ok, warn, "the persisted axis must flip the icon + note")
        XCTAssertTrue(ok.contains(WorkbenchImportSummaryPresentation.iconSystemName(for: .success)))
        XCTAssertTrue(warn.contains(WorkbenchImportSummaryPresentation.iconSystemName(for: .warning)))
        XCTAssertFalse(ok.contains(WorkbenchImportSummaryPresentation.notPersistedNote))
        XCTAssertTrue(warn.contains(WorkbenchImportSummaryPresentation.notPersistedNote))
    }
}
#endif
