#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C6-2 — `OuroAgentInstallSheet` (`:6310`) enumerated state-set.
///
/// The clone-from-Git form has two data-driven arms over its `@State`:
///   - `if cloneNameValidation.isInvalid, let message` (`:6332`) — the inline red name error,
///     driven by `CloneAgentNameValidation.evaluate(agentName)` (the real pure classifier).
///   - `if let inlineMessage = cloneState.inlineMessage` (`:6340`) — the progress/success/failure
///     line, with a busy ProgressView / error `Image("exclamationmark.triangle.fill")` / success
///     `Image("checkmark.circle.fill")` branch, plus the primary button copy
///     ("Cloning…" / "Try Again" / "Clone Agent") and the secondary "Done"/"Cancel" branch.
///
/// **Seam (AN-007).** These arms hinge on the form's `@State` (`agentName` / `cloneState`), which
/// in production only mutate via the in-view "Clone Agent" Button closure (`startClone()` →
/// `model.cloneAgentHeadless`) that ViewInspector's synchronous `inspect()` CANNOT fire (the C4
/// `DecisionLogRow.taught` pattern). A minimal prod-byte-identical seam
/// (`init(model:initialAgentName:initialRemote:initialCloneState:)`, all defaulting to the prior
/// literals) lets this test drive each arm through the REAL `CloneAgentFlowState` Core values, so
/// the validation / message / error / success arms are COVERED — not fabricated. The only call
/// site (`OuroAgentInstallSheet(model:)`) takes all defaults → production renders the empty idle
/// form exactly as before.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection). The
/// `cloneState` arms are the real `CloneAgentFlowState.{idle,cloning,succeeded,failed}` enum
/// cases (a `public` Core value type — constructing it IS the seam); the name error is the real
/// `CloneAgentNameValidation.evaluate` classifier driven by a malformed injected name.
///
/// **Determinism (P3).** No clock / UUID / path — the inline lines are static seam-free Core copy.
/// Byte-identical twice; no `/Users/` leak.
///
/// **Non-vacuity (P2).** Each arm flips a CAPTURED node: the idle form has no inline line; the
/// invalid-name arm adds the red error Text; cloning/failed/succeeded each render a distinct
/// inline message + button copy ("Cloning…" / "Try Again" / "Clone Agent") + secondary
/// ("Cancel" vs "Done"). The negative controls assert the flips.
@MainActor
final class OuroAgentInstallSheetTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c6-install-\(UUID().uuidString)", isDirectory: true)
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

    private func sheet(name: String = "",
                       remote: String = "",
                       state: CloneAgentFlowState = .idle) throws -> OuroAgentInstallSheet {
        OuroAgentInstallSheet(model: try makeVM(),
                              initialAgentName: name,
                              initialRemote: remote,
                              initialCloneState: state)
    }

    // MARK: - Enumerated state-set

    /// Idle (the production default): the empty editable form, no inline line, "Clone Agent" +
    /// "Cancel" buttons.
    func testInstall_idle() throws {
        try assertViewSnapshot(of: try sheet(), named: "OuroAgentInstallSheet.idle")
    }

    /// A malformed agent name → the inline red `CloneAgentNameValidation` error.
    func testInstall_invalidName() throws {
        let view = try sheet(name: "bad/name", remote: "git@github.com:org/repo.git")
        XCTAssertTrue(CloneAgentNameValidation.evaluate("bad/name").isInvalid,
                      "provenance: 'bad/name' is malformed per the real classifier")
        try assertViewSnapshot(of: view, named: "OuroAgentInstallSheet.invalidName")
    }

    /// Cloning (busy): the ProgressView + "Cloning <remote>…" line + "Cloning…" button.
    func testInstall_cloning() throws {
        let view = try sheet(remote: "git@github.com:org/repo.git",
                             state: .cloning(remoteLabel: "repo"))
        try assertViewSnapshot(of: view, named: "OuroAgentInstallSheet.cloning")
    }

    /// Succeeded: the success checkmark + "Cloned <name>." line + "Done" secondary.
    func testInstall_succeeded() throws {
        let view = try sheet(remote: "git@github.com:org/repo.git",
                             state: .succeeded(agentName: "repo"))
        try assertViewSnapshot(of: view, named: "OuroAgentInstallSheet.succeeded")
    }

    /// Failed: the error triangle + the seam-free failure line + "Try Again" button.
    func testInstall_failed() throws {
        let view = try sheet(remote: "git@github.com:org/repo.git",
                             state: .failed(reason: CloneAgentFlowState.failureReason(forRemoteLabel: "repo")))
        try assertViewSnapshot(of: view, named: "OuroAgentInstallSheet.failed")
    }

    // MARK: - Determinism (P3)

    func testInstall_determinism_byteIdenticalTwiceNoLeak() throws {
        let cases: [(String, () throws -> OuroAgentInstallSheet)] = [
            ("idle", { try self.sheet() }),
            ("invalidName", { try self.sheet(name: "bad/name", remote: "git@github.com:org/repo.git") }),
            ("cloning", { try self.sheet(remote: "git@github.com:org/repo.git", state: .cloning(remoteLabel: "repo")) }),
            ("succeeded", { try self.sheet(remote: "git@github.com:org/repo.git", state: .succeeded(agentName: "repo")) }),
            ("failed", { try self.sheet(remote: "git@github.com:org/repo.git", state: .failed(reason: CloneAgentFlowState.failureReason(forRemoteLabel: "repo"))) }),
        ]
        for (name, make) in cases {
            let a = try ViewSnapshotHost.snapshotText(of: try make())
            let b = try ViewSnapshotHost.snapshotText(of: try make())
            XCTAssertEqual(a, b, "\(name) must be byte-identical twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }

    // MARK: - Negative controls (P2 — mutation-verified)

    /// The `cloneNameValidation.isInvalid` gate adds/removes the inline red error.
    func testInstall_negativeControl_invalidNameGateFlipsError() throws {
        let valid = try ViewSnapshotHost.snapshotText(of: try sheet(name: "good-name", remote: "git@github.com:org/repo.git"))
        let invalid = try ViewSnapshotHost.snapshotText(of: try sheet(name: "bad/name", remote: "git@github.com:org/repo.git"))

        XCTAssertNotEqual(valid, invalid, "the name-validation gate must drive the tree")
        XCTAssertFalse(valid.contains(CloneAgentNameValidation.invalidMessage),
                       "valid: no inline error:\n\(valid)")
        XCTAssertTrue(invalid.contains(CloneAgentNameValidation.invalidMessage),
                      "invalid: the inline name error renders:\n\(invalid)")
    }

    /// The `cloneState` gate drives the inline line + the primary/secondary button copy.
    func testInstall_negativeControl_cloneStateGateFlipsTree() throws {
        let idle = try ViewSnapshotHost.snapshotText(of: try sheet())
        let cloning = try ViewSnapshotHost.snapshotText(of: try sheet(remote: "git@github.com:org/repo.git", state: .cloning(remoteLabel: "repo")))
        let succeeded = try ViewSnapshotHost.snapshotText(of: try sheet(remote: "git@github.com:org/repo.git", state: .succeeded(agentName: "repo")))
        let failed = try ViewSnapshotHost.snapshotText(of: try sheet(remote: "git@github.com:org/repo.git", state: .failed(reason: CloneAgentFlowState.failureReason(forRemoteLabel: "repo"))))

        // Idle: no inline line; "Clone Agent" + "Cancel".
        XCTAssertFalse(idle.contains("Cloning repo…"), "idle: no progress line")
        XCTAssertTrue(idle.contains("Clone Agent"), "idle: the primary reads Clone Agent")
        XCTAssertTrue(idle.contains("Cancel"), "idle: the secondary reads Cancel")
        // Cloning: the progress line + "Cloning…" primary.
        XCTAssertTrue(cloning.contains("Cloning repo…"), "cloning: the progress line renders:\n\(cloning)")
        XCTAssertTrue(cloning.contains("Cloning…"), "cloning: the primary reads Cloning…")
        // Succeeded: the success line + "Done" secondary.
        XCTAssertTrue(succeeded.contains("Cloned repo."), "succeeded: the success line renders:\n\(succeeded)")
        XCTAssertTrue(succeeded.contains("Done"), "succeeded: the secondary reads Done")
        // Failed: the failure line + "Try Again" + the error triangle.
        XCTAssertTrue(failed.contains("Couldn't clone repo."), "failed: the failure line renders:\n\(failed)")
        XCTAssertTrue(failed.contains("Try Again"), "failed: the primary reads Try Again")
        XCTAssertTrue(failed.contains("exclamationmark.triangle.fill"), "failed: the error icon renders")

        XCTAssertNotEqual(idle, cloning)
        XCTAssertNotEqual(cloning, succeeded)
        XCTAssertNotEqual(succeeded, failed)
    }
}
#endif
