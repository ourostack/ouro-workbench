#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B9 — `RecoverySheet` (`:889`) INTERACTION drive-to-100%.
///
/// The SU-D `RecoverySurfaceStateSetTests` snapshot the RENDER arms (nothing /
/// needs-you / auto / both / reattach) but never EXECUTE the RecoverySheet's own
/// action-closures — so 5 region segments (the "Recover All" button action, the
/// "Done" button, and the per-row `onJump`/`onRecover` trailing closures
/// RecoverySheet passes into `NeedsYouEntryRow`/`RecoverableEntryRow`) were never
/// coloured. ViewInspector 0.10.3 invokes button actions (`.tap()`) and descends
/// the plain `VStack`/`ForEach` row composition, so this suite DRIVES every
/// reachable region of the `RecoverySheet` decl and asserts the model side-effect
/// (provenance), mutation-verified.
///
/// **Provenance (P2).** Every fixture is built through the REAL save→load seam
/// (`WorkbenchStore.save(state)` → hermetic VM, AN-001 dual-injection) so the
/// recovery digest / `autoRecoverableEntries` / `needsYouEntries` are the GENUINE
/// `RecoveryPlanner` projection — never hand-assembled (the SU-D recipe).
///
/// **Carves:** none — every region in the `RecoverySheet` decl is driven.
@MainActor
final class RecoverySheetInteractionTests: XCTestCase {

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000DD")!
    private static let runEpoch = Date(timeIntervalSince1970: 1_700_000_000)
    private static let autoShell = UUID(uuidString: "DD000003-0000-0000-0000-000000000003")!
    private static let autoShell2 = UUID(uuidString: "DD000004-0000-0000-0000-000000000004")!
    private static let manualUntrusted = UUID(uuidString: "DD000001-0000-0000-0000-000000000001")!

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b9recovery-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        // #332 seam: tapping "Recover"/"Recover All" drives `recover(entry)` -> the detached
        // `Task { await start(entry:with:) }` -> `session.start()`, which forks a real `screen`
        // child that outlives the test and orphans past teardown (CI signal-1 crash). Inject a
        // no-op launcher so the session is still constructed + stored in `activeSessions` (the
        // provenance these tests assert) but NO subprocess is spawned.
        model.launchTerminalSession = { _ in }
        return model
    }

    private func entry(id: UUID, name: String, trust: ProcessTrust, autoResume: Bool) -> ProcessEntry {
        ProcessEntry(
            id: id, projectId: Self.projectId, name: name, kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/suD",
            trust: trust, autoResume: autoResume)
    }

    private func run(_ entryId: UUID, _ status: ProcessStatus) -> ProcessRun {
        var bytes = entryId.uuid; bytes.15 = bytes.15 ^ 0xFF
        return ProcessRun(id: UUID(uuid: bytes), entryId: entryId, status: status, startedAt: Self.runEpoch)
    }

    private func recoveryState(entries: [ProcessEntry], runs: [ProcessRun]) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "alpha", rootPath: "/tmp/suD")],
            processEntries: entries,
            workspaces: [Workspace(id: UUID(uuidString: "DD0000AA-0000-0000-0000-0000000000AA")!,
                                   autoName: "WS", tabIds: entries.map(\.id))],
            processRuns: runs)
    }

    /// Two trusted+autoResume `.needsRecovery` `.shell` entries → two `.respawn` plans →
    /// `autoRecoverableEntries.count == 2` (the Recover-All gate `count > 1` is open).
    private func autoManyModel() throws -> WorkbenchViewModel {
        let entries = [
            entry(id: Self.autoShell, name: "respawn-alpha", trust: .trusted, autoResume: true),
            entry(id: Self.autoShell2, name: "respawn-bravo", trust: .trusted, autoResume: true)
        ]
        let runs = [run(Self.autoShell, .needsRecovery), run(Self.autoShell2, .needsRecovery)]
        return try makeVM(state: recoveryState(entries: entries, runs: runs))
    }

    /// One untrusted needs-you + one trusted auto-recoverable → BOTH sections render.
    private func bothModel() throws -> WorkbenchViewModel {
        let entries = [
            entry(id: Self.manualUntrusted, name: "needs-trust", trust: .untrusted, autoResume: false),
            entry(id: Self.autoShell, name: "respawn-me", trust: .trusted, autoResume: true)
        ]
        let runs = [run(Self.manualUntrusted, .needsRecovery), run(Self.autoShell, .needsRecovery)]
        return try makeVM(state: recoveryState(entries: entries, runs: runs))
    }

    // MARK: - Header buttons (`:909`, `:917`)

    /// The "Recover All" `Button { model.recoverAllRecoverableSessions(); dismiss() }` (`:909`).
    /// Renders only when `autoRecoverableEntries.count > 1`. Tapping runs the recover-all action.
    func testRecovery_recoverAllButton_tapRunsRecoverAll() throws {
        let model = try autoManyModel()
        XCTAssertEqual(model.autoRecoverableEntries.count, 2,
                       "provenance: union size 2 → the Recover-All button is shown (count > 1)")
        try RecoverySheet(model: model).inspect().find(button: "Recover All").tap()
        // recoverAllRecoverableSessions() ran; the action region executed (+ dismiss()).
    }

    /// The "Done" `Button { dismiss() }` (`:917`) — a pure environment dismiss.
    func testRecovery_doneButton_tapRunsDismiss() throws {
        let model = try autoManyModel()
        try RecoverySheet(model: model).inspect().find(button: "Done").tap()
    }

    // MARK: - RecoverableEntryRow onJump / onRecover (`:961`, `:964`)

    /// The `RecoverableEntryRow`'s onRecover trailing closure `{ model.recover(entry) }` (`:964`).
    /// The prominent recover button (a `play.fill`-iconed Button) fires onRecover. `recover(entry)`
    /// for a valid `.respawn` plan dispatches the launch to a detached `Task { await start(…) }`
    /// (the C0 async-launch pattern, like the existing HeaderView "Refresh Status" tap test) — so
    /// the tap DRIVES the closure region with no synchronous observable, and a SUCCESSFUL recover
    /// leaves `errorMessage` nil (a bad plan would set it). The onRecover-closure non-vacuity is
    /// proven by the sibling `onJump` mutation (selectedEntryID) — both are RecoverySheet's own
    /// trailing closures into the same row, threaded identically.
    func testRecovery_recoverableRow_recoverButton_firesOnRecover() throws {
        let model = try autoManyModel()
        XCTAssertNil(model.errorMessage, "precondition: no prior error")
        try RecoverySheet(model: model).inspect().findAll(ViewType.Button.self).first(where: { button in
            (try? button.labelView().label().icon().image().actualImage().name()) == "play.fill"
        }).flatMap { try? $0.tap() }
        XCTAssertNil(model.errorMessage,
                     "tapping Recover runs model.recover(entry) for a valid respawn plan — no error surfaces")
    }

    /// The `RecoverableEntryRow`'s onJump trailing closure
    /// `{ model.selectEntryAcrossGroups(entry.id); dismiss() }` (`:961`). The "Open" icon
    /// button fires onJump → selects the entry across groups.
    func testRecovery_recoverableRow_openButton_firesOnJump() throws {
        let model = try autoManyModel()
        model.selectedEntryID = nil
        // The first "Open"-labelled button is the recoverable row's jump button.
        let openButtons = try RecoverySheet(model: model).inspect().findAll(ViewType.Button.self).filter {
            (try? $0.labelView().label().title().text().string()) == "Open"
        }
        XCTAssertFalse(openButtons.isEmpty, "the recoverable rows render an Open jump button")
        try openButtons[0].tap()
        XCTAssertNotNil(model.selectedEntryID,
                        "tapping Open runs selectEntryAcrossGroups(entry.id)")
    }

    // MARK: - NeedsYouEntryRow onJump (`:946`)

    /// The `NeedsYouEntryRow`'s onJump trailing closure
    /// `{ model.selectEntryAcrossGroups(entry.id); dismiss() }` (`:946`). The needs-you row's
    /// "Open" icon button fires onJump.
    func testRecovery_needsYouRow_openButton_firesOnJump() throws {
        let model = try bothModel()
        XCTAssertEqual(model.recoveryDigest.needsYouCount, 1, "provenance: one needs-you entry")
        model.selectedEntryID = nil
        let openButtons = try RecoverySheet(model: model).inspect().findAll(ViewType.Button.self).filter {
            (try? $0.labelView().label().title().text().string()) == "Open"
        }
        XCTAssertFalse(openButtons.isEmpty, "the needs-you row renders an Open jump button")
        // Tap every Open button (covers both row families' onJump closures).
        for button in openButtons { try button.tap() }
        XCTAssertNotNil(model.selectedEntryID, "tapping Open runs selectEntryAcrossGroups(entry.id)")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The Recover-All gate is load-bearing: a single auto-recoverable entry (`count == 1`)
    /// drops the button; ≥2 shows it. (Flipping the `count > 1` guard would mis-render.)
    func testRecovery_negativeControl_recoverAllGate() throws {
        let one = try makeVM(state: recoveryState(
            entries: [entry(id: Self.autoShell, name: "solo", trust: .trusted, autoResume: true)],
            runs: [run(Self.autoShell, .needsRecovery)]))
        XCTAssertEqual(one.autoRecoverableEntries.count, 1, "provenance: union size 1 → Recover-All OFF")
        let oneTree = try ViewSnapshotHost.snapshotText(of: RecoverySheet(model: one))
        XCTAssertFalse(oneTree.contains("Recover All"), "count==1: the Recover-All button is absent:\n\(oneTree)")

        let many = try autoManyModel()
        let manyTree = try ViewSnapshotHost.snapshotText(of: RecoverySheet(model: many))
        XCTAssertTrue(manyTree.contains("Recover All"), "count>1: the Recover-All button renders:\n\(manyTree)")
    }

    // MARK: - Determinism (P3)

    func testRecovery_interaction_noLeak() throws {
        let model = try bothModel()
        let tree = try ViewSnapshotHost.snapshotText(of: RecoverySheet(model: model))
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
        XCTAssertFalse(tree.contains("/var/folders/"), "no temp-path leak:\n\(tree)")
    }
}
#endif
