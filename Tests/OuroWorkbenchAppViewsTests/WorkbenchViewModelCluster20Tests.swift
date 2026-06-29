#if os(macOS)
import XCTest
import OuroWorkbenchCore
import SwiftUI
@testable import OuroWorkbenchAppViews

/// VM-GATE cluster 20 — the small-decl LOGIC TAIL (the big dispatch decls are all driven).
///
/// Drives the directly-callable computed-property / format-helper arms that the view tests only
/// partially exercise (a view snapshot seeds ONE status, leaving the other color/line arms
/// uncovered). Each is pure logic (no machinery): a direct call covering every arm.
///   • `supportDiagnosticsStatusColor` (`:1763`) — error→orange / nil-result→secondary / result→green.
///   • `bossWorkbenchMCPStatusColor` (`:2430`) — nil→secondary / .registered→green / .needsUpdate→orange
///     / the red group (.notRegistered/.agentMissing/.executableMissing/.invalidConfig/.toolsNotInjected).
///   • `bossWorkbenchMCPActionTitle` (`:2447`) — .needsUpdate→"Clean up" / else→"Connect".
///   • `mailboxStatusLine` (`:1525`) — error→message / nil→"Mailbox status unavailable".
///   • `startFreshConfirmationMessage` (`:4301`) — the one-line confirmation copy.
///   • `supportDiagnosticsURL` (`:1771`) — result→archiveURL / nil→nil.
@MainActor
final class WorkbenchViewModelCluster20Tests: XCTestCase {

    private static let wsId = UUID(uuidString: "C20F1A00-0000-0000-0000-0000000000B1")!

    private func makeVM(boss: String = "boss") throws -> (WorkbenchViewModel, URL) {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vmcluster20-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        try FileManager.default.createDirectory(at: agentBundles, withIntermediateDirectories: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: boss),
            bossWatchEnabled: false,
            workspaces: [Workspace(id: Self.wsId, autoName: "WS", tabIds: [])])
        try WorkbenchStore(paths: paths).save(state)
        let m = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
        m.launchTerminalSession = { _ in }
        m.chooseWorkspaceSaveURL = { _ in nil }
        m.chooseWorkspaceOpenURL = { _ in nil }
        m.terminateApp = {}
        return (m, agentBundles)
    }

    private func registration(_ status: BossWorkbenchMCPRegistrationStatus)
        -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss", serverName: "workbench", commandPath: "AgentBundles/workbench-mcp",
            agentConfigPath: "AgentBundles/boss.ouro/agent.json", status: status, detail: "d")
    }

    // MARK: - supportDiagnosticsStatusColor (3 arms)

    func testSupportDiagnosticsStatusColor_allArms() throws {
        let (m, _) = try makeVM()
        // error → orange
        m.supportDiagnosticsError = "boom"
        XCTAssertEqual(m.supportDiagnosticsStatusColor, .orange, "an error surfaces orange")
        // nil error + nil result → secondary
        m.supportDiagnosticsError = nil
        m.supportDiagnosticsResult = nil
        XCTAssertEqual(m.supportDiagnosticsStatusColor, .secondary, "no result yet → secondary")
        // nil error + result → green
        m.supportDiagnosticsResult = SupportDiagnosticsResult(
            archiveURL: URL(fileURLWithPath: "/tmp/ouro-support.zip"), output: "ok")
        XCTAssertEqual(m.supportDiagnosticsStatusColor, .green, "a written archive → green")
    }

    func testSupportDiagnosticsURL_resultVsNil() throws {
        let (m, _) = try makeVM()
        XCTAssertNil(m.supportDiagnosticsURL, "no result → nil URL")
        let url = URL(fileURLWithPath: "/tmp/ouro-support.zip")
        m.supportDiagnosticsResult = SupportDiagnosticsResult(archiveURL: url, output: "ok")
        XCTAssertEqual(m.supportDiagnosticsURL, url, "a result surfaces its archive URL")
    }

    // MARK: - bossWorkbenchMCPStatusColor (4 arms)

    func testBossWorkbenchMCPStatusColor_allArms() throws {
        let (m, _) = try makeVM()
        // nil registration → secondary
        m.bossWorkbenchMCPRegistration = nil
        XCTAssertEqual(m.bossWorkbenchMCPStatusColor, .secondary, "no registration → secondary")
        // .registered → green
        m.bossWorkbenchMCPRegistration = registration(.registered)
        XCTAssertEqual(m.bossWorkbenchMCPStatusColor, .green, ".registered → green")
        // .needsUpdate → orange
        m.bossWorkbenchMCPRegistration = registration(.needsUpdate)
        XCTAssertEqual(m.bossWorkbenchMCPStatusColor, .orange, ".needsUpdate → orange")
        // the red group (.notRegistered representative)
        m.bossWorkbenchMCPRegistration = registration(.notRegistered)
        XCTAssertEqual(m.bossWorkbenchMCPStatusColor, .red, ".notRegistered → red")
    }

    func testBossWorkbenchMCPActionTitle_needsUpdateVsElse() throws {
        let (m, _) = try makeVM()
        m.bossWorkbenchMCPRegistration = registration(.needsUpdate)
        XCTAssertEqual(m.bossWorkbenchMCPActionTitle, "Clean up", ".needsUpdate → Clean up")
        m.bossWorkbenchMCPRegistration = registration(.registered)
        XCTAssertEqual(m.bossWorkbenchMCPActionTitle, "Connect", "non-needsUpdate → Connect")
        m.bossWorkbenchMCPRegistration = nil
        XCTAssertEqual(m.bossWorkbenchMCPActionTitle, "Connect", "nil registration → Connect")
    }

    // MARK: - mailboxStatusLine (2 arms)

    func testMailboxStatusLine_errorVsDefault() throws {
        let (m, _) = try makeVM()
        XCTAssertEqual(m.mailboxStatusLine, "Mailbox status unavailable", "no error → the default copy")
        m.mailboxError = "rate limited"
        XCTAssertEqual(m.mailboxStatusLine, "rate limited", "an error surfaces verbatim")
    }

    // MARK: - startFreshConfirmationMessage (pure copy)

    func testStartFreshConfirmationMessage_namesEntry() throws {
        let (m, _) = try makeVM()
        let entry = ProcessEntry(
            projectId: UUID(), name: "deploy", kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp", trust: .trusted)
        let message = m.startFreshConfirmationMessage(for: entry)
        XCTAssertTrue(message.contains("deploy"), "the confirmation copy names the entry")
        XCTAssertTrue(message.contains("new conversation"), "the copy explains the fresh-start consequence")
    }

    // MARK: - bossWorkbenchMCPStatusLine (the 5 untested status arms)

    func testBossWorkbenchMCPStatusLine_untestedStatusArms() throws {
        let (m, _) = try makeVM()
        let cases: [(BossWorkbenchMCPRegistrationStatus, String)] = [
            (.needsUpdate, "stale entry to clean"),
            (.agentMissing, "agent bundle missing"),
            (.executableMissing, "install app first"),
            (.invalidConfig, "config issue"),
            (.toolsNotInjected, "tools didn't load — update ouro to alpha.660+"),
        ]
        for (status, expected) in cases {
            m.bossWorkbenchMCPRegistration = registration(status)
            XCTAssertEqual(m.bossWorkbenchMCPStatusLine, expected, "\(status) status line")
        }
        // The .registered arm names the agent at runtime.
        m.bossWorkbenchMCPRegistration = registration(.registered)
        XCTAssertEqual(m.bossWorkbenchMCPStatusLine, "available to boss at runtime",
                       ".registered names the agent")
    }

    // MARK: - bossWatchStatusColor (3 arms) + bossWatchStatusLine (error/last-run arms)

    func testBossWatchStatusColor_allArms() throws {
        let (m, _) = try makeVM()
        // lastError → orange (takes precedence)
        m.bossWatchLastError = "stalled"
        XCTAssertEqual(m.bossWatchStatusColor, .orange, "a watch error surfaces orange")
        // no error + enabled → green
        m.bossWatchLastError = nil
        m.setBossWatchEnabled(true)
        XCTAssertEqual(m.bossWatchStatusColor, .green, "enabled + no error → green")
        // no error + disabled → secondary
        m.setBossWatchEnabled(false)
        XCTAssertEqual(m.bossWatchStatusColor, .secondary, "disabled + no error → secondary")
    }

    func testBossWatchStatusLine_errorAndLastRunArms() throws {
        let (m, _) = try makeVM()
        // error arm
        m.bossWatchLastError = "boom"
        XCTAssertEqual(m.bossWatchStatusLine, "error: boom", "the error arm surfaces the message")
        // enabled + last-run arm (a fixed Date)
        m.bossWatchLastError = nil
        m.setBossWatchEnabled(true)
        m.bossWatchLastRunAt = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(m.bossWatchStatusLine.hasPrefix("watching; last "),
                      "enabled + a last-run timestamp → the watching-with-time arm")
    }

    // MARK: - stopConfirmationTitle (2 arms)

    func testStopConfirmationTitle_pendingVsNone() throws {
        let (m, _) = try makeVM()
        XCTAssertEqual(m.stopConfirmationTitle, "Stop?", "no pending stop → the bare title")
        m.pendingStopSession = ProcessEntry(
            projectId: UUID(), name: "deploy", kind: .shell,
            executable: "/bin/zsh", workingDirectory: "/tmp", trust: .trusted)
        XCTAssertTrue(m.stopConfirmationTitle.contains("deploy"),
                      "a pending stop names the session in the title")
    }

    // MARK: - transcriptSearchStatusLine (empty / press-search arms)

    func testTranscriptSearchStatusLine_emptyAndPressSearchArms() throws {
        let (m, _) = try makeVM()
        m.transcriptSearchQuery = "   "
        XCTAssertEqual(m.transcriptSearchStatusLine, "Enter a query to search saved transcripts.",
                       "an empty query → the prompt-to-enter arm")
        m.transcriptSearchQuery = "needle"
        XCTAssertEqual(m.transcriptSearchStatusLine, "Press Search to search saved transcripts.",
                       "a typed-but-unsearched query → the press-search arm")
    }

    // MARK: - ouroAgentStatusLine (populated arm)

    func testOuroAgentStatusLine_populatedArm() throws {
        let (m, agentBundles) = try makeVM()
        let bundle = agentBundles.appendingPathComponent("scout.ouro", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let root: [String: Any] = ["enabled": true, "humanFacing": ["outward": ["provider": "anthropic"]]]
        try JSONSerialization.data(withJSONObject: root)
            .write(to: bundle.appendingPathComponent("agent.json"))
        m.refreshOuroAgents()
        let line = m.ouroAgentStatusLine
        XCTAssertTrue(line.contains("1 local"), "the populated arm counts local agents: \(line)")
        XCTAssertTrue(line.contains("ready; boss "),
                      "the populated arm renders the ready count + boss label: \(line)")
    }
}
#endif
