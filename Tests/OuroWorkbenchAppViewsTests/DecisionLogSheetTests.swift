#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C4-4 — `DecisionLogSheet` (`:2156`) enumerated state-set.
///
/// The sheet has one data-driven gate, `if model.state.decisionLog.isEmpty` (`:2178`):
///   - empty → the "No decisions recorded yet" empty state (`Image("checklist")` + headline +
///     explainer copy).
///   - else → `ScrollView { ForEach(model.state.decisionLog) { DecisionLogRow(…) } }` (`:2196`),
///     the full chronological audit. Each row is the shared `DecisionLogRow` (covered standalone
///     in its own sub-unit) threaded with the deterministic `timeZone`/`locale` seam (AN-007).
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001). The decision log is
/// provenance-built by persisting a `WorkspaceState(decisionLog: [...])` through
/// `WorkbenchStore.save` → VM (the REAL load path the persisted log decodes through), each
/// `BossInboxDecision` via its REAL public initializer with a FIXED `occurredAt` + id. NO
/// hand-assembled serializer output.
///
/// **Clock (AN-007).** The sheet is rendered with injected `.gmt` + `en_GB` (threaded to every
/// embedded `DecisionLogRow`), so the rows' `occurredAt` timestamps are byte-identical across CI
/// runner zones/locales. The cross-TZ/locale proof runs in the gate.
///
/// **Determinism (P3).** Fixed timestamps/ids; no machine path; byte-identical twice.
///
/// **Non-vacuity (P2).** The negative control flips the `isEmpty` gate: empty → the empty-state
/// copy; populated → the row content (session name + the migrated timestamp). The two trees
/// differ; named content appears/vanishes per arm.
@MainActor
final class DecisionLogSheetTests: XCTestCase {

    private static let fixedDate = Date(timeIntervalSince1970: 1_767_323_045)
    private static let clockLocale = Locale(identifier: "en_GB")
    private static let decisionId = UUID(uuidString: "DEC15102-0000-0000-0000-00000000000B")!

    private func makeVM(decisionLog: [BossInboxDecision]) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c4-logsheet-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        var state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"))
        state.decisionLog = decisionLog
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func decision() -> BossInboxDecision {
        BossInboxDecision(
            id: Self.decisionId,
            occurredAt: Self.fixedDate,
            source: "boss:slugger",
            sessionName: "deploy-runner",
            friendName: "Sam",
            prompt: "Apply the migration?",
            kind: .escalate,
            proposedInput: "y",
            preferenceCited: "Sam always approves staging migrations",
            confidence: 0.82,
            reasoning: "Matches the team's standing preference.",
            status: .recorded
        )
    }

    private func sheet(_ model: WorkbenchViewModel) -> DecisionLogSheet {
        DecisionLogSheet(model: model, timeZone: .gmt, locale: Self.clockLocale)
    }

    // MARK: - Enumerated state-set

    func testLog_empty() throws {
        let model = try makeVM(decisionLog: [])
        XCTAssertTrue(model.state.decisionLog.isEmpty, "provenance: the empty-log arm")
        try assertViewSnapshot(of: sheet(model), named: "DecisionLogSheet.empty")
    }

    func testLog_populated() throws {
        let model = try makeVM(decisionLog: [decision()])
        XCTAssertEqual(model.state.decisionLog.count, 1, "provenance: a persisted decision loads")
        XCTAssertEqual(model.state.decisionLog.first?.occurredAt, Self.fixedDate,
                       "provenance: the fixed timestamp survives the save→load path")
        try assertViewSnapshot(of: sheet(model), named: "DecisionLogSheet.populated")
    }

    // MARK: - Determinism (P3)

    func testLog_determinism_byteIdenticalTwiceNoLeak() throws {
        for (name, log) in [("empty", [BossInboxDecision]()), ("populated", [decision()])] {
            let model = try makeVM(decisionLog: log)
            let a = try ViewSnapshotHost.snapshotText(of: sheet(model))
            let b = try ViewSnapshotHost.snapshotText(of: sheet(model))
            XCTAssertEqual(a, b, "\(name) must be byte-identical twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative control (P2 — mutation-verified)

    func testLog_negativeControl_emptyGateFlipsTree() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: sheet(try makeVM(decisionLog: [])))
        let populated = try ViewSnapshotHost.snapshotText(of: sheet(try makeVM(decisionLog: [decision()])))

        XCTAssertNotEqual(empty, populated, "the decisionLog.isEmpty gate must drive the tree")
        XCTAssertTrue(empty.contains("No decisions recorded yet"), "empty: the empty-state copy:\n\(empty)")
        XCTAssertFalse(empty.contains("deploy-runner"), "empty: no row content")
        XCTAssertTrue(populated.contains("deploy-runner"), "populated: the row session name renders:\n\(populated)")
        XCTAssertTrue(populated.contains("2 Jan 2026"), "populated: the migrated row timestamp renders")
        XCTAssertFalse(populated.contains("No decisions recorded yet"), "populated: not the empty state")
    }
}
#endif
