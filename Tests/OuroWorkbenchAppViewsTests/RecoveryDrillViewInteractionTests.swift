#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B9 — `RecoveryDrillView` (`:10473`) INTERACTION drive-to-100%.
///
/// The C10 `RecoveryDrillViewStateSetTests` snapshot the RENDER arms (not-run / with
/// result) but always INJECT `.gmt`/`en_GB`, and never tap the "Run Drill" button —
/// so 4 region segments (the `timeZone`/`locale` prod-default autoclosures, the
/// "Run Drill" button action, and the result-row `groupName` map closure) were never
/// coloured. ViewInspector 0.10.3 invokes button actions (`.tap()`), so this suite
/// DRIVES every reachable region and asserts the model side-effect, mutation-verified.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM`; the drill result is the
/// REAL `RecoveryDrill().run(state:now:)` producer fed a real `.needsRecovery` state
/// (the C10 seam). The prod-default clock autoclosures are driven by constructing the
/// view WITHOUT the `.gmt`/`en_GB` seam (the `.autoupdatingCurrent` defaults execute).
///
/// **Carves:** none — every region in the `RecoveryDrillView` decl is driven.
@MainActor
final class RecoveryDrillViewInteractionTests: XCTestCase {

    private static let fixedNow = Date(timeIntervalSince1970: 1_767_323_045)
    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!
    private static let entryId = UUID(uuidString: "11111111-0000-0000-0000-000000000001")!
    private static let runId = UUID(uuidString: "AAAAAAAA-0000-0000-0000-0000000000A1")!
    private static let started = Date(timeIntervalSince1970: 1_767_322_000)

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b9drill-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func recoverableState() -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "alpha", rootPath: "/tmp/u4")],
            processEntries: [ProcessEntry(id: Self.entryId, projectId: Self.projectId, name: "deploy-runner",
                                          kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u4",
                                          autoResume: true)],
            processRuns: [ProcessRun(id: Self.runId, entryId: Self.entryId, status: .needsRecovery,
                                     startedAt: Self.started)])
    }

    /// A model with a real drill result (the producer fed a recoverable state + fixed now).
    private func withResultModel() throws -> WorkbenchViewModel {
        let model = try makeVM()
        model.state = recoverableState()
        model.recoveryDrillResult = RecoveryDrill().run(state: recoverableState(), now: Self.fixedNow)
        return model
    }

    // MARK: - prod-default clock autoclosures (`:10478`, `:10479`)

    /// Constructing `RecoveryDrillView(model:)` WITHOUT the `.gmt`/`en_GB` seam executes the
    /// `timeZone = .autoupdatingCurrent` / `locale = .autoupdatingCurrent` default-value
    /// autoclosures (the C10 tests always inject, so these prod defaults were never run).
    func testDrill_prodDefaultClock_autoclosuresExecute() throws {
        let model = try withResultModel()
        // No timeZone/locale args → the prod-default autoclosures execute.
        let view = RecoveryDrillView(model: model)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("deploy-runner"), "the drill rows render under the prod-default clock:\n\(tree)")
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
    }

    // MARK: - "Run Drill" button (`:10486`)

    /// The "Run Drill" `Button { model.runRecoveryDrill() }`. Tapping runs the drill on the live
    /// state, which assigns `model.recoveryDrillResult` (the action's observable effect).
    func testDrill_runDrillButton_tapRunsDrill() throws {
        let model = try makeVM()
        model.state = recoverableState()
        XCTAssertNil(model.recoveryDrillResult, "precondition: no drill run yet")
        try RecoveryDrillView(model: model).inspect().find(button: "Run Drill").tap()
        XCTAssertNotNil(model.recoveryDrillResult,
                        "tapping Run Drill runs runRecoveryDrill() → a result is assigned")
    }

    // MARK: - result-row groupName map closure (`:10501`)

    /// The result row's `model.groupName(forEntryId: item.id).map { "\($0) / \(item.entryName)" }
    /// ?? item.entryName`. A result whose item's entry resolves a group runs the `.map` closure →
    /// "alpha / deploy-runner".
    func testDrill_resultRow_groupNameMapClosure() throws {
        let model = try withResultModel()
        XCTAssertEqual(model.groupName(forEntryId: Self.entryId), "alpha",
                       "provenance: the group resolves through the real state")
        let tree = try ViewSnapshotHost.snapshotText(of: RecoveryDrillView(model: model))
        XCTAssertTrue(tree.contains("alpha / deploy-runner"),
                      "the groupName map closure renders 'group / entry':\n\(tree)")
    }

    /// The `?? item.entryName` NIL-FALLBACK arm of the result-row label (`:10501`). A drill item
    /// whose entry has NO matching project → `groupName(forEntryId:)` returns nil → the row
    /// renders just the bare `entryName`. Drives the `??` right-hand side.
    func testDrill_resultRow_groupNameNilFallback() throws {
        // A recoverable state with the entry but NO project → groupName resolves nil.
        let noProjectState = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: [ProcessEntry(id: Self.entryId, projectId: Self.projectId, name: "deploy-runner",
                                          kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u4",
                                          autoResume: true)],
            processRuns: [ProcessRun(id: Self.runId, entryId: Self.entryId, status: .needsRecovery,
                                     startedAt: Self.started)])
        let model = try makeVM()
        model.state = noProjectState
        model.recoveryDrillResult = RecoveryDrill().run(state: noProjectState, now: Self.fixedNow)
        XCTAssertNil(model.groupName(forEntryId: Self.entryId),
                     "provenance: no project → nil group → the ?? fallback")
        XCTAssertFalse(model.recoveryDrillResult!.items.isEmpty, "provenance: a drill item exists")
        let tree = try ViewSnapshotHost.snapshotText(of: RecoveryDrillView(model: model))
        XCTAssertTrue(tree.contains("deploy-runner"), "the bare entryName renders (no 'group / '):\n\(tree)")
        XCTAssertFalse(tree.contains("alpha / deploy-runner"), "no group prefix on the no-project row:\n\(tree)")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The Run-Drill action is load-bearing: tapping assigns a result (nil → non-nil). A no-op
    /// action would leave `recoveryDrillResult` nil — the mutation that breaks the guard.
    func testDrill_negativeControl_runDrillAssignsResult() throws {
        let model = try makeVM()
        model.state = recoverableState()
        XCTAssertNil(model.recoveryDrillResult)
        try RecoveryDrillView(model: model).inspect().find(button: "Run Drill").tap()
        XCTAssertNotNil(model.recoveryDrillResult, "Run Drill assigned a result")
        XCTAssertFalse(model.recoveryDrillResult!.items.isEmpty,
                       "provenance: the recoverable state produced a drill item")
    }

    // MARK: - Determinism (P3)

    func testDrill_interaction_noLeak() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: RecoveryDrillView(model: try withResultModel(),
                                                                           timeZone: .gmt, locale: Locale(identifier: "en_GB")))
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
        XCTAssertFalse(tree.contains("/var/folders/"), "no temp-path leak:\n\(tree)")
    }
}
#endif
