#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 — `NeedsYouEntryRow` (`:1011`) action drive-to-100%.
///
/// The "Needs you" recovery row lives inside `RecoverySheet`; its inline fix buttons
/// (`Trust & resume` when the blocker is `.untrusted`, else `Start fresh`) were never
/// tapped. Promoted private->internal for the per-file-100% gate; this suite drives BOTH
/// conditional arms + the onJump button, asserting the model effect (provenance).
///
/// **Provenance (P2).** A real `.untrusted` `.needsRecovery` `.shell` entry → the planner
/// classifies the blocker as `.untrusted` → `recoveryTrustFixAvailable == true` → the
/// `Trust & resume` arm renders. A `.trusted` entry whose plan offers no untrusted-fix →
/// the `else` (`Start fresh`) arm. The `#332` `launchTerminalSession` no-op is injected so
/// `trustAndRecover` (-> recover -> start) spawns no `screen`.
///
/// **Carves:** none — both arms + the onJump action are driven.
@MainActor
final class NeedsYouEntryRowDriveTests: XCTestCase {

    private static let projectId = UUID(uuidString: "C5000001-0000-0000-0000-000000000001")!
    private static let runEpoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u5-needsyou-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        model.launchTerminalSession = { _ in }  // #332: trustAndRecover -> recover -> start()
        return model
    }

    private func entry(_ id: UUID, name: String, trust: ProcessTrust, autoResume: Bool) -> ProcessEntry {
        ProcessEntry(id: id, projectId: Self.projectId, name: name, kind: .shell,
                     executable: "/bin/zsh", workingDirectory: "/tmp/u5needsyou",
                     trust: trust, autoResume: autoResume)
    }

    private func run(_ entryId: UUID, _ status: ProcessStatus) -> ProcessRun {
        var b = entryId.uuid; b.15 = b.15 ^ 0xFF
        return ProcessRun(id: UUID(uuid: b), entryId: entryId, status: status, startedAt: Self.runEpoch)
    }

    private func state(_ e: ProcessEntry, _ r: ProcessRun) -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "alpha", rootPath: "/tmp/u5needsyou")],
            processEntries: [e],
            workspaces: [Workspace(id: UUID(uuidString: "C50000AA-0000-0000-0000-0000000000AA")!,
                                   autoName: "WS", tabIds: [e.id])],
            processRuns: [r])
    }

    // MARK: - the `recoveryTrustFixAvailable == true` arm (Trust & resume)

    func testNeedsYou_untrustedBlocker_trustAndResumeArm() throws {
        let id = UUID(uuidString: "C5000010-0000-0000-0000-000000000010")!
        // An UNTRUSTED + non-autoResume entry with a `.needsRecovery` run → the planner
        // classifies the action as `.manualActionNeeded` with `blocker == .untrusted`
        // (the RecoverySheet `bothModel` recipe) → `recoveryTrustFixAvailable == true`.
        let e = entry(id, name: "needs-trust", trust: .untrusted, autoResume: false)
        let model = try makeVM(state: state(e, run(id, .needsRecovery)))
        let loaded = model.state.processEntries.first ?? e
        XCTAssertTrue(model.recoveryTrustFixAvailable(for: loaded),
                      "provenance: an untrusted manual-recovery entry → the Trust & resume arm")
        let row = NeedsYouEntryRow(entry: loaded, model: model, onJump: {})
        try row.inspect().find(button: "Trust & resume").tap()
        // trustAndRecover trusts the entry (observable) then drives the seamed recover.
        XCTAssertEqual(model.state.processEntries.first?.trust, .trusted,
                       "Trust & resume trusted the entry (the action ran)")
    }

    // MARK: - the `else` arm (Start fresh) + the onJump action

    func testNeedsYou_noTrustFix_startFreshArmAndJump() throws {
        let id = UUID(uuidString: "C5000011-0000-0000-0000-000000000011")!
        // A TRUSTED entry → recoveryTrustFixAvailable is false (no untrusted blocker) → else arm.
        let e = entry(id, name: "no-resume", trust: .trusted, autoResume: false)
        let model = try makeVM(state: state(e, run(id, .manualActionNeeded)))
        let loaded = model.state.processEntries.first ?? e
        XCTAssertFalse(model.recoveryTrustFixAvailable(for: loaded),
                       "provenance: a trusted entry → the Start fresh else-arm")
        var jumped = false
        let row = NeedsYouEntryRow(entry: loaded, model: model, onJump: { jumped = true })
        try row.inspect().find(button: "Start fresh").tap()
        XCTAssertEqual(model.pendingStartFresh?.id, loaded.id,
                       "Start fresh arms the pending-start-fresh confirmation (requestStartFresh)")
        // The onJump trailing closure (the "Open" icon button — `.iconOnly` label, so match on
        // the underlying Label title rather than `find(button:)`, mirroring RecoverySheet's tests).
        let openButtons = try row.inspect().findAll(ViewType.Button.self).filter {
            (try? $0.labelView().label().title().text().string()) == "Open"
        }
        XCTAssertFalse(openButtons.isEmpty, "the row renders an Open jump button")
        try openButtons[0].tap()
        XCTAssertTrue(jumped, "tapping Open fires the onJump callback")
    }
}
#endif
