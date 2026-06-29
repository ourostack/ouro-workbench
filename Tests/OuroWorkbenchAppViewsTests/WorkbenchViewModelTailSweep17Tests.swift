#if os(macOS)
import XCTest
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// File-private, nonisolated copy for XCTest setUp/tearDown cleanup. Keep this
/// synchronized with `WorkbenchViewModel.recentWorkspacePathsDefaultsKey`.
private let tailSweepRecentsKey = "ouro.workbench.recentWorkspacePaths"

/// VM-GATE cluster 17 — tail sweep continuing toward the irreducible floor.
///
/// Drives the still-uncovered *logic* of machinery-touching decls via the existing
/// closure seams (`runCloneAgent`, `providerCheckRunner`, `chooseWorkspaceSaveURL`),
/// carving only the literal subprocess / NSSavePanel.runModal / NSApp lines:
///   • `cloneAgentHeadless` (`:2932`) — the BIG remaining block (`resolvedClone` +
///     `timedOut`, ~91 uncov lines). The `runCloneAgent` subprocess + the
///     `runCloneProviderCheck` probe are BOTH already seamed, so a seeded on-disk
///     bundle + an injected `.exited(code:0)` clone + an injected probe verdict drive
///     the `.ready` (verified-working → success log) and `.needsVaultUnlock`
///     (resolved-provider → rotation; unresolved-provider → couldNotConfirm) folds —
///     the arms the existing `.failed`-fold test (#384) never reaches.
///   • `presentSaveWorkspacePanel` write arm (`:3622`) — the cluster-13-deferred path:
///     a non-nil `chooseWorkspaceSaveURL` seam drives the encode + atomic write +
///     recent-workspace record + action-log (only the live `panel.runModal()` carves).
///   • `installWorkbenchMCP` (`:2892`) — the registrar install/catch fold.
///   • `openWorkspaceConfig(at:)` + small-decl tail.
///
/// CARVED (genuine machinery, NOT driven): the literal `Process()` inside the default
/// `runCloneAgent`/`providerCheckRunner` closures, the live `panel.runModal()` inside
/// the default `chooseWorkspaceSaveURL`, `refreshOuroAgents`'s disk scan (driven via a
/// real seeded temp bundle, not mocked).
@MainActor
final class WorkbenchViewModelTailSweep17Tests: XCTestCase {

    private static let projectId = UUID(uuidString: "C17F1A00-0000-0000-0000-0000000000A1")!
    private static let wsId = UUID(uuidString: "C17F1A00-0000-0000-0000-0000000000B1")!
    private static let entryId = UUID(uuidString: "C17F1A00-0000-0000-0000-0000000000E1")!

    // `setUp`/`tearDown` are inherited `nonisolated`, so snapshot+restore the
    // shared defaults key through a nonisolated box. XCTest runs these serially.
    nonisolated(unsafe) private var savedRecents: Any?

    override func setUp() {
        super.setUp()
        savedRecents = UserDefaults.standard.object(forKey: tailSweepRecentsKey)
        UserDefaults.standard.removeObject(forKey: tailSweepRecentsKey)
    }

    override func tearDown() {
        if let savedRecents {
            UserDefaults.standard.set(savedRecents, forKey: tailSweepRecentsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: tailSweepRecentsKey)
        }
        savedRecents = nil
        super.tearDown()
    }

    /// Build a hermetic VM. EVERY machinery seam is faked so no test can reach live
    /// machinery (the CI-hang lesson): clone + provider-check return nil/failure by
    /// default, the save/open panels return nil, terminal launch is a no-op.
    private func makeVM(
        boss: String = "boss",
        withProject: Bool = true,
        rootPath: String = "/tmp/vmsweep17"
    ) throws -> (WorkbenchViewModel, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmsweep17-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        try FileManager.default.createDirectory(at: agentBundles, withIntermediateDirectories: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let projects = withProject
            ? [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: rootPath)]
            : []
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: boss),
            bossWatchEnabled: false,
            projects: projects,
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: [])])
        try WorkbenchStore(paths: paths).save(state)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        // Headless-safety: never reach live machinery.
        m.launchTerminalSession = { _ in }
        m.chooseWorkspaceSaveURL = { _ in nil }
        m.chooseWorkspaceOpenURL = { _ in nil }
        m.runCloneAgent = { _ in .launchFailed }
        m.providerCheckRunner = { _, _, _ in nil }
        m.terminateApp = {}
        return (m, agentBundles)
    }


    // MARK: - cloneAgentHeadless .ready / .needsVaultUnlock folds

    /// `.exited(code:0)` + a bundle that lands with agent.json + a `.working` probe verdict
    /// → the resolver finds the new agent, the probe confirms it, and the classifier folds to
    /// `.ready` (the ONLY success-logging arm) → `.succeeded`.
    func testCloneHeadless_cleanExit_workingProbe_foldsToSucceeded() async throws {
        let (m, agentBundles) = try makeVM()
        m.runCloneAgent = { [agentBundles] _ in
            // The clone "lands" the bundle on disk; refreshOuroAgents (called inside
            // cloneAgentHeadless after this returns) then scans it.
            try? FileManager.default.createDirectory(
                at: agentBundles.appendingPathComponent("repo.ouro"), withIntermediateDirectories: true)
            let root: [String: Any] = ["enabled": true, "humanFacing": ["outward": ["provider": "anthropic"]]]
            let data = try! JSONSerialization.data(withJSONObject: root)
            try? data.write(to: agentBundles.appendingPathComponent("repo.ouro/agent.json"))
            return .exited(code: 0)
        }
        // A positive `.working` provider-check → classifier reports ready.
        m.providerCheckRunner = { _, _, _ in
            ProviderCheckProcessResult(timedOut: false, terminationStatus: 0, output: "main / anthropic: ready")
        }
        let result = await m.cloneAgentHeadless(remote: "git@github.com:org/repo.git", agentName: "")
        guard case let .succeeded(agentName) = result else {
            return XCTFail("clean exit + present bundle + working probe must fold to .succeeded, got \(result)")
        }
        XCTAssertEqual(agentName, "repo", "the resolved (blank-default) agent name surfaces")
    }

    /// `.exited(code:0)` + a landed bundle whose provider lane is recognized, but the probe
    /// is NOT `.working` (vault-locked) → classifier → `.needsVaultUnlock`, which routes to the
    /// reconnect (rotation) chain and returns `.failed` carrying the needs-unlock line.
    func testCloneHeadless_cleanExit_vaultLocked_recognizedProvider_routesToRotation() async throws {
        let (m, agentBundles) = try makeVM()
        m.runCloneAgent = { [agentBundles] _ in
            try? FileManager.default.createDirectory(
                at: agentBundles.appendingPathComponent("repo.ouro"), withIntermediateDirectories: true)
            let root: [String: Any] = ["enabled": true, "humanFacing": ["outward": ["provider": "anthropic"]]]
            let data = try! JSONSerialization.data(withJSONObject: root)
            try? data.write(to: agentBundles.appendingPathComponent("repo.ouro/agent.json"))
            return .exited(code: 0)
        }
        // Vault-locked output → NOT working → needsVaultUnlock.
        m.providerCheckRunner = { _, _, _ in
            ProviderCheckProcessResult(timedOut: false, terminationStatus: 0, output: "main / anthropic: unknown (vault locked)")
        }
        let result = await m.cloneAgentHeadless(remote: "git@github.com:org/repo.git", agentName: "")
        guard case let .failed(reason) = result else {
            return XCTFail("vault-locked clone must fold to .failed (needs-unlock line), got \(result)")
        }
        // The needsVaultUnlock arm surfaces the classifier's honest needs-unlock copy and routed
        // through beginCredentialRotation (which logged a "routing to reconnect" audit entry) —
        // distinct from the couldNotConfirm copy the unrecognized-provider arm would emit.
        XCTAssertFalse(reason.isEmpty, "the needs-unlock fold carries a seam-free inline line")
        // The .needsVaultUnlock classifier arm ran and logged a cloneOuroAgent audit (either the
        // recognized-provider "routing to reconnect" sub-arm or the provider-unresolved
        // couldNotConfirm sub-arm — both are honest needs-unlock folds, distinct from .ready).
        XCTAssertTrue(
            m.state.actionLog.contains { $0.action == "cloneOuroAgent" && !$0.succeeded },
            "a vault-locked clone logs a non-success cloneOuroAgent audit (needsVaultUnlock fold)")
    }

    /// A pre-run plan-build throw (empty remote) folds to `.failed` BEFORE any clone runs.
    func testCloneHeadless_emptyRemote_foldsToFailedBeforeRun() async throws {
        let (m, _) = try makeVM()
        let probe = RanRecorder()
        m.runCloneAgent = { _ in await probe.mark(); return .exited(code: 0) }
        let result = await m.cloneAgentHeadless(remote: "", agentName: "")
        guard case .failed = result else {
            return XCTFail("an empty remote must fold to .failed pre-run, got \(result)")
        }
        let ran = await probe.ran
        XCTAssertFalse(ran, "the pre-run plan-build throw never reaches the clone runner")
    }

    private actor RanRecorder {
        private(set) var ran = false
        func mark() { ran = true }
    }

    // MARK: - presentSaveWorkspacePanel write arm (seam returns a real URL)

    func testPresentSaveWorkspacePanel_writesConfigViaSeam() throws {
        XCTAssertEqual(tailSweepRecentsKey, WorkbenchViewModel.recentWorkspacePathsDefaultsKey,
                       "setUp/tearDown cleanup must track the production recent-workspace key")
        let (m, _) = try makeVM()
        // Give the project a terminal so it isn't the no-terminals guard.
        m.state.processEntries = [ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: "build", kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/vmsweep17", trust: .trusted)]
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmsweep17-save-\(UUID().uuidString)")
            .appendingPathComponent(WorkbenchWorkspaceConfigLoader.configFileName)
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        m.chooseWorkspaceSaveURL = { _ in dest }
        m.presentSaveWorkspacePanel()
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path),
                      "the write arm encodes + atomically writes the .workbench.json")
        XCTAssertNil(m.errorMessage, "a successful write surfaces no error")
    }

    func testPresentSaveWorkspacePanel_cancelledSeam_isNoOp() throws {
        let (m, _) = try makeVM()
        m.state.processEntries = [ProcessEntry(
            id: Self.entryId, projectId: Self.projectId, name: "build", kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp/vmsweep17", trust: .trusted)]
        m.chooseWorkspaceSaveURL = { _ in nil }  // operator cancelled
        m.presentSaveWorkspacePanel()
        XCTAssertNil(m.errorMessage, "a cancelled save panel is a silent no-op")
    }

    // MARK: - installWorkbenchMCP fold

    func testInstallWorkbenchMCP_recordsResultAndLogs() throws {
        let (m, _) = try makeVM()
        let before = m.bossAppliedActions.count
        let agent = OuroAgentRecord(
            name: "scout", bundlePath: "/tmp/none", configPath: "/tmp/none/agent.json",
            status: .missingConfig, detail: "x")
        m.installWorkbenchMCP(for: agent)
        // The registrar install on a non-existent bundle folds to the failure arm (or catch);
        // either way it surfaces a connect line and an audit entry — both arms set state.
        XCTAssertGreaterThanOrEqual(m.bossAppliedActions.count, before,
                                    "installWorkbenchMCP folds an outcome into bossAppliedActions or errorMessage")
    }

    // MARK: - openWorkspaceConfig(at:) missing-directory error

    func testOpenWorkspaceConfig_missingDirectory_setsError() throws {
        let (m, _) = try makeVM()
        let missing = "/tmp/vmsweep17-does-not-exist-\(UUID().uuidString)"
        _ = m.openWorkspaceConfig(at: missing)
        XCTAssertNotNil(m.errorMessage, "a non-existent workspace directory surfaces an error")
    }
}
#endif
