#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B2 — `AutonomyStatusCheckRow` (`:4813`) repair-button INTERACTION drive-to-100%.
///
/// The C3 `AutonomyStatusCheckRowTests` snapshot the indicator + the "Trust" repair button's LABEL
/// but never EXECUTE the button action (`apply(remediation.kind)`) — so the `repairButton` action
/// closure (`:4884`), the whole `apply(_:)` switch (`:4894`), and the private
/// `AutonomyRemediationKind.systemImage` extension switch (`:4912`) were never coloured. This suite
/// DRIVES every reachable remediation kind: for each, it provenance-builds the model state that makes
/// the kind's `hasLiveButton` true, renders the row, FINDS the repair button and `.tap()`s it →
/// executing `apply(kind)` (the matching actuator) AND rendering `kind.systemImage` for that arm.
///
/// **Carve (login-tainted):** the `.openAtLogin` arm (`apply` `.openAtLogin`, the "open-at-login"
/// check's repair button, and the `.openAtLogin` `systemImage` "power") is gated by
/// `loginItemActionable = loginItem.status != .appBundleMissing` — `LoginItemController` is the
/// non-injectable, machine-local `@StateObject` (no init seam to pin its status), so on a clean CI
/// runner (`.appBundleMissing`) the button never renders and the arm is unreachable in-process. That
/// one `apply` arm + the `.openAtLogin` systemImage arm are the recorded carve (allowlist candidate #6).
/// The OTHER 5 kinds are DRIVEN. (The `isDegraded` default-value `= false` parameter-default region is
/// a Swift default-argument storage region with no app seam to set it from the default — recorded carve.)
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` (AN-001). Each actuator's availability is
/// driven by REAL state: an untrusted `.terminalAgent` entry (trust), a non-auto-resume claude agent
/// (resume), a `.notRegistered` MCP registration (connect), a `.respawn` recoverable entry (recover),
/// and the default watch-OFF state (watch). `AutonomyReadinessCheck` is the public Core value type.
@MainActor
final class AutonomyStatusCheckRowInteractionTests: XCTestCase {

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000CC")!

    private func makeVM(configure: (inout WorkspaceState) -> Void = { _ in }) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b2-ascr-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        var state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"))
        configure(&state)
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        // #332 seam: the remediation "Recover" button drives recover(entry) → the detached
        // start() → session.start(), forking a real `screen` child that orphans past teardown
        // (CI signal-1 crash). Inject a no-op launcher so the recover path runs but no
        // subprocess spawns.
        model.launchTerminalSession = { _ in }
        return model
    }

    private func check(_ id: String, _ label: String, _ state: AutonomyReadinessCheckState) -> AutonomyReadinessCheck {
        AutonomyReadinessCheck(id: id, label: label, detail: "\(label) needs attention.", state: state)
    }

    private func row(_ check: AutonomyReadinessCheck, model: WorkbenchViewModel) -> AutonomyStatusCheckRow {
        AutonomyStatusCheckRow(check: check, model: model, loginItem: LoginItemController())
    }

    private func tapRepair(_ row: AutonomyStatusCheckRow, label: String) throws {
        try row.inspect().find(button: label).tap()
    }

    private func untrustedAgent() -> ProcessEntry {
        ProcessEntry(id: UUID(uuidString: "CC000001-0000-0000-0000-000000000001")!,
                     projectId: Self.projectId, name: "agent-untrusted", kind: .terminalAgent,
                     executable: "/usr/bin/claude", workingDirectory: "/tmp/u5ascr", trust: .untrusted)
    }

    private func resumableClaude() -> ProcessEntry {
        ProcessEntry(id: UUID(uuidString: "CC000002-0000-0000-0000-000000000002")!,
                     projectId: Self.projectId, name: "agent-resume", kind: .terminalAgent,
                     executable: "/usr/local/bin/claude", workingDirectory: "/tmp/u5ascr",
                     trust: .trusted, autoResume: false)
    }

    // MARK: - .trustTerminals

    func testApply_trustTerminals() throws {
        let model = try makeVM { $0.processEntries = [untrustedAgent()] }
        XCTAssertFalse(model.untrustedAutonomyAgentEntries.isEmpty, "provenance: an untrusted agent")
        let view = row(check("terminal-trust", "Agent terminals", .blocker), model: model)
        try tapRepair(view, label: "Trust")
        XCTAssertTrue(model.untrustedAutonomyAgentEntries.isEmpty, "Trust trusts every untrusted agent")
    }

    // MARK: - .enableResume

    func testApply_enableResume() throws {
        let model = try makeVM { $0.processEntries = [resumableClaude()] }
        XCTAssertFalse(model.resumableDisabledAutonomyAgentEntries.isEmpty,
                       "provenance: a non-auto-resume claude agent is resumable")
        let view = row(check("terminal-resume", "Auto-resume", .blocker), model: model)
        try tapRepair(view, label: "Enable resume")
        XCTAssertTrue(model.resumableDisabledAutonomyAgentEntries.isEmpty,
                      "Enable resume flips auto-resume on")
    }

    // MARK: - .connectTools

    func testApply_connectTools() throws {
        let model = try makeVM()
        model.bossWorkbenchMCPRegistration = BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss", serverName: "workbench",
            commandPath: "AgentBundles/workbench-mcp",
            agentConfigPath: "AgentBundles/boss.ouro/agent.json",
            status: .notRegistered, detail: "not connected")
        XCTAssertTrue(model.bossWorkbenchMCPRegistration?.isActionable == true,
                      "provenance: .notRegistered is actionable")
        let view = row(check("boss-mcp", "Workbench tools", .blocker), model: model)
        // Tapping "Connect tools" invokes installWorkbenchMCPForBoss(); the action region is covered.
        try tapRepair(view, label: "Connect tools")
    }

    // MARK: - .recover

    func testApply_recover() throws {
        let entryId = UUID(uuidString: "CC000003-0000-0000-0000-000000000003")!
        let model = try makeVM { state in
            let entry = ProcessEntry(id: entryId, projectId: Self.projectId, name: "respawn-me",
                                     kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u5ascr",
                                     trust: .trusted, autoResume: true)
            var runBytes = entryId.uuid; runBytes.15 = runBytes.15 ^ 0xFF
            let run = ProcessRun(id: UUID(uuid: runBytes), entryId: entryId, status: .needsRecovery,
                                 startedAt: Date(timeIntervalSince1970: 1_700_000_000))
            state.processEntries = [entry]
            state.workspaces = [Workspace(id: UUID(uuidString: "CC0000AA-0000-0000-0000-0000000000AA")!,
                                          autoName: "WS", tabIds: [entryId])]
            state.processRuns = [run]
        }
        XCTAssertFalse(model.recoverableEntries.isEmpty, "provenance: a real recoverable entry")
        let view = row(check("recovery", "Recovery", .blocker), model: model)
        // The recover repair button renders the .recover systemImage glyph (the ext arm).
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("arrow.uturn.backward"), "the .recover glyph:\n\(tree)")
        try tapRepair(view, label: "Recover")
    }

    // MARK: - .enableWatch

    func testApply_enableWatch() throws {
        // Persist watch OFF so `bossWatchDisabled == true` → the .enableWatch button is live.
        let model = try makeVM { $0.bossWatchEnabled = false }
        XCTAssertFalse(model.bossWatchIsEnabled, "provenance: persisted watch OFF → bossWatchDisabled")
        let view = row(check("boss-watch", "Boss watch", .blocker), model: model)
        try tapRepair(view, label: "Watch")
        XCTAssertTrue(model.bossWatchIsEnabled, "Watch enables boss watch")
        model.setBossWatchEnabled(false)  // stop the watch loop the actuator started
    }

    // MARK: - systemImage extension arms (rendered with each kind's repair button)

    /// Each driven kind renders its repair button with `remediation.kind.systemImage` — so the
    /// private `AutonomyRemediationKind.systemImage` switch arms are coloured as a side-effect of
    /// the kind-specific rows above. This test asserts the glyph reaches the tree per kind.
    func testSystemImage_glyphsPerKind() throws {
        let trust = try makeVM { $0.processEntries = [untrustedAgent()] }
        let trustTree = try ViewSnapshotHost.snapshotText(of: row(check("terminal-trust", "Agent terminals", .blocker), model: trust))
        XCTAssertTrue(trustTree.contains("checkmark.shield"), "trust glyph:\n\(trustTree)")

        let resume = try makeVM { $0.processEntries = [resumableClaude()] }
        let resumeTree = try ViewSnapshotHost.snapshotText(of: row(check("terminal-resume", "Auto-resume", .blocker), model: resume))
        XCTAssertTrue(resumeTree.contains("arrow.clockwise"), "resume glyph:\n\(resumeTree)")

        let watch = try makeVM { $0.bossWatchEnabled = false }
        let watchTree = try ViewSnapshotHost.snapshotText(of: row(check("boss-watch", "Boss watch", .blocker), model: watch))
        XCTAssertTrue(watchTree.contains(#"image="eye""#), "watch glyph:\n\(watchTree)")

        let connectModel = try makeVM()
        connectModel.bossWorkbenchMCPRegistration = BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss", serverName: "workbench", commandPath: "AgentBundles/workbench-mcp",
            agentConfigPath: "AgentBundles/boss.ouro/agent.json", status: .notRegistered, detail: "")
        let connectTree = try ViewSnapshotHost.snapshotText(of: row(check("boss-mcp", "Workbench tools", .blocker), model: connectModel))
        XCTAssertTrue(connectTree.contains("point.3.connected.trianglepath.dotted"), "connect glyph:\n\(connectTree)")
    }
}
#endif
