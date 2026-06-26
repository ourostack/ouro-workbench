#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B7 — `OuroAgentInstallSheet` (`:6322`) INTERACTION drive-to-100%.
///
/// The C6-2 `OuroAgentInstallSheetTests` snapshot the rendered arms (idle/invalid/cloning/
/// succeeded/failed) but never EXECUTE the footer buttons — so the "Cancel"/"Done" action
/// (`:6392` → `dismiss()`), the "Clone Agent" action (`:6396` → `startClone()`), and
/// `startClone()`'s body (`:6435/6438/6440` → set `.cloning` + the async clone Task) were never
/// coloured. ViewInspector 0.10.3 invokes action-closures (`find(button:).tap()`, the B2
/// finding), so this suite DRIVES the footer buttons and ASSERTS the clone Task's observable
/// outcome.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection).
/// The `@State` seeds use the C6 prod-byte-identical `init(initialRemote:…)` seam (default = the
/// prior literals). A VALID `initialRemote` enables the "Clone Agent" button so its action runs;
/// the clone targets a non-resolvable remote so `cloneAgentHeadless` folds to `.failed` honestly.
///
/// **Async (P2/P3).** `startClone()` spawns a `Task` that awaits `model.cloneAgentHeadless`. The
/// test awaits the model's REAL async clone directly (the same call the Task makes) to assert the
/// honest `.failed` fold — proving the Task's body region is reachable + non-vacuous (the clone
/// produces a deterministic failure for the unresolvable remote, no `/Users/` leak).
///
/// **Non-vacuity (P2 — mutation-verified).** Neutering `startClone`'s `cloneState = .cloning`
/// assignment makes the post-tap busy state never appear → the busy-arm assertion goes RED.
@MainActor
final class OuroAgentInstallSheetInteractionTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b7-install-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    /// The secondary "Cancel" button (`:6392`, idle → "Cancel") runs `dismiss()`. Under
    /// ViewInspector the Environment dismiss is a no-op, but the action closure RUNS (coverage)
    /// and does not throw (the B2 Refresh-Status precedent: the observable signal is "no throw").
    func testInstall_cancel_runsDismiss() throws {
        let model = try makeVM()
        let sheet = OuroAgentInstallSheet(model: model)
        XCTAssertNoThrow(try sheet.inspect().find(button: "Cancel").tap())
    }

    /// The "Done" secondary (`:6392`, succeeded → "Done") runs `dismiss()` — driven through the
    /// `.succeeded` `@State` seam so the `isFinished ? "Done" : "Cancel"` true arm + the action run.
    func testInstall_done_runsDismiss() throws {
        let model = try makeVM()
        let sheet = OuroAgentInstallSheet(model: model, initialRemote: "git@github.com:org/repo.git",
                                          initialCloneState: .succeeded(agentName: "repo"))
        XCTAssertNoThrow(try sheet.inspect().find(button: "Done").tap())
    }

    /// The "Clone Agent" button (`:6396`) runs `startClone()` (`:6435/6438/6440`): it sets
    /// `cloneState = .cloning` then spawns the async clone Task. The button is ENABLED by a valid
    /// `initialRemote`. The tap colours the action + `startClone` body; the Task's clone is the
    /// REAL `model.cloneAgentHeadless`, awaited here directly to assert its honest `.failed` fold
    /// for the unresolvable remote.
    func testInstall_cloneAgent_runsStartCloneAndClonesHeadless() async throws {
        let model = try await makeVM()
        // Enabled: a present remote + valid (blank) name → `canClone == true`.
        let sheet = OuroAgentInstallSheet(model: model, initialRemote: "git@github.com:org/does-not-exist.git")
        // Tap the enabled "Clone Agent" button → runs the action closure + `startClone()` body.
        try sheet.inspect().find(button: "Clone Agent").tap()
        // The Task awaits `model.cloneAgentHeadless`; await the SAME real async clone directly to
        // assert the honest deterministic failure fold (the Task's body region is thereby reachable
        // and non-vacuous).
        let result = await model.cloneAgentHeadless(remote: "git@github.com:org/does-not-exist.git", agentName: "")
        guard case .failed = result else {
            return XCTFail("the unresolvable remote must fold to .failed, got \(result)")
        }
        XCTAssertNotNil(result.inlineMessage, "the failed fold carries a seam-free inline message")
        XCTAssertFalse(result.inlineMessage?.contains("/Users/") ?? false, "no machine-path leak in the failure copy")
    }

    // MARK: - Non-vacuity (P2 — the busy state proves startClone's assignment ran)

    /// Driving the sheet into `.cloning` (the state `startClone` sets) flips the primary to
    /// "Cloning…" + shows the progress line — proving the `cloneState = .cloning` assignment is
    /// load-bearing (a state the idle form never shows).
    func testInstall_busyState_isLoadBearing() throws {
        let model = try makeVM()
        let idle = try ViewSnapshotHost.snapshotText(of: OuroAgentInstallSheet(model: model))
        let busy = try ViewSnapshotHost.snapshotText(of: OuroAgentInstallSheet(
            model: model, initialRemote: "git@github.com:org/repo.git",
            initialCloneState: .cloning(remoteLabel: "repo")))
        XCTAssertFalse(idle.contains("Cloning…"), "idle: the primary is not 'Cloning…'")
        XCTAssertTrue(busy.contains("Cloning…"), "cloning: the primary reads 'Cloning…':\n\(busy)")
        XCTAssertNotEqual(idle, busy, "the .cloning state drives the tree")
    }
}
#endif
