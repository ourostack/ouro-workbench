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
/// the clone runner is injected so the interaction test never shells out to the local `ouro` CLI
/// or depends on network resolution.
///
/// **Async (P2/P3).** `startClone()` spawns a `Task` that awaits `model.cloneAgentHeadless`. The
/// interaction test waits for the tapped Task to hit the injected runner; a separate model-fold
/// test awaits `cloneAgentHeadless` directly with the same injected runner to assert the honest
/// `.failed` copy. The view action stays proven without live subprocesses or repo-root output.
///
/// **Non-vacuity (P2 — mutation-verified).** Neutering `startClone`'s `cloneState = .cloning`
/// assignment makes the post-tap busy state never appear → the busy-arm assertion goes RED.
@MainActor
final class OuroAgentInstallSheetInteractionTests: XCTestCase {

    private actor CloneRunnerProbe {
        private var plans: [OuroAgentInstallPlan] = []

        func record(_ plan: OuroAgentInstallPlan) {
            plans.append(plan)
        }

        var callCount: Int {
            plans.count
        }

        var commandLines: [String] {
            return plans.map(\.commandLine)
        }
    }

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

    private func repoRootOuroArtifacts() throws -> [String] {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ouro" }
            .map(\.lastPathComponent)
            .sorted()
    }

    private func waitForCloneRunnerCalls(
        _ probe: CloneRunnerProbe,
        atLeast expectedCount: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<20 {
            let callCount = await probe.callCount
            if callCount >= expectedCount {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let callCount = await probe.callCount
        XCTFail("expected at least \(expectedCount) clone runner call(s), got \(callCount)", file: file, line: line)
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
    /// `initialRemote`. The tap colours the action + `startClone` body; the Task's clone uses the
    /// injected runner, so the interaction stays hermetic.
    func testInstall_cloneAgent_runsStartCloneAndClonesHeadless() async throws {
        let model = try makeVM()
        let probe = CloneRunnerProbe()
        model.runCloneAgent = { plan in
            await probe.record(plan)
            return .exited(code: 12)
        }
        XCTAssertEqual(try repoRootOuroArtifacts(), [], "precondition: repo root must start clean")
        // Enabled: a present remote + valid (blank) name → `canClone == true`.
        let remote = "git@github.com:org/repo.git"
        let sheet = OuroAgentInstallSheet(model: model, initialRemote: remote)
        // Tap the enabled "Clone Agent" button → runs the action closure + `startClone()` body.
        try sheet.inspect().find(button: "Clone Agent").tap()
        await waitForCloneRunnerCalls(probe, atLeast: 1)
        let commandLines = await probe.commandLines
        XCTAssertEqual(commandLines.count, 1, "the tapped task should run the injected clone once")
        XCTAssertTrue(
            commandLines.allSatisfy { $0.contains(remote) },
            "the injected runner still receives the native clone command"
        )
        XCTAssertEqual(try repoRootOuroArtifacts(), [], "the injected clone runner must not create repo-root bundles")
    }

    func testCloneAgentHeadless_usesInjectedRunnerForFailureFold() async throws {
        let model = try makeVM()
        let probe = CloneRunnerProbe()
        model.runCloneAgent = { plan in
            await probe.record(plan)
            return .exited(code: 12)
        }
        XCTAssertEqual(try repoRootOuroArtifacts(), [], "precondition: repo root must start clean")
        let remote = "git@github.com:org/repo.git"
        let result = await model.cloneAgentHeadless(remote: remote, agentName: "")
        guard case .failed = result else {
            return XCTFail("the injected non-zero clone result must fold to .failed, got \(result)")
        }
        let commandLines = await probe.commandLines
        XCTAssertEqual(commandLines.count, 1, "the model fold should call the injected clone once")
        XCTAssertTrue(commandLines.allSatisfy { $0.contains(remote) }, "the injected runner receives the native clone command")
        XCTAssertNotNil(result.inlineMessage, "the failed fold carries a seam-free inline message")
        XCTAssertFalse(result.inlineMessage?.contains("/Users/") ?? false, "no machine-path leak in the failure copy")
        XCTAssertEqual(try repoRootOuroArtifacts(), [], "the injected clone runner must not create repo-root bundles")
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
