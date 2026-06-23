import XCTest
@testable import OuroWorkbenchCore

/// Durable source-pin assertions for the MCP-pill injection-verdict fix. The App target
/// isn't coverage-gated and can't be click-tested in CI, so — exactly like
/// `AgentReadinessOverlayWiringTests` / `ColdStartHonestWiringTests` — we pin the structural
/// wiring in source: each of the three MCP-pill render sites must compute its colour + text
/// from `BossMCPPillPresentation` folding the registration STATUS with the live injection
/// VERDICT (`bossWorkbenchToolsInjectionByAgentName`), never from the status alone. A
/// status-only pill is the false-green this fix removes.
final class BossMCPPillVerdictWiringTests: XCTestCase {

    // MARK: - Core: HarnessAgentEntry carries the injection verdict, threaded by the builder

    /// `HarnessAgentEntry` must carry the per-agent injection verdict so the harness-diagnostic
    /// pill can render verdict-aware. Additive (default nil) so existing constructions compile.
    func testHarnessAgentEntryCarriesToolsInjectionVerdict() {
        let entry = HarnessAgentEntry(
            name: "boss",
            status: .ready,
            detail: "",
            isSelectedBoss: true,
            mcpStatus: .registered,
            toolsInjection: .confirmed(.present)
        )
        XCTAssertEqual(entry.toolsInjection, .confirmed(.present))
    }

    /// The verdict defaults to nil so every pre-existing `HarnessAgentEntry(...)` keeps compiling.
    func testHarnessAgentEntryToolsInjectionDefaultsNil() {
        let entry = HarnessAgentEntry(
            name: "boss",
            status: .ready,
            detail: "",
            isSelectedBoss: false
        )
        XCTAssertNil(entry.toolsInjection)
    }

    /// The harness builder must thread a per-agent injection-verdict map into the entries it
    /// builds — so the harness pill renders the SAME verdict the steady-state rows compute.
    func testHarnessStatusBuilderThreadsInjectionVerdictIntoEntries() {
        let builder = HarnessStatusBuilder()
        let agent = OuroAgentRecord(
            name: "boss",
            bundlePath: "/bundle",
            configPath: "/cfg",
            status: .ready,
            detail: ""
        )
        let registration = BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss",
            serverName: "workbench",
            commandPath: "/usr/bin/ouro",
            agentConfigPath: "/cfg",
            status: .registered,
            detail: ""
        )
        let status = builder.build(
            boss: BossAgentSelection(agentName: "boss"),
            dashboard: nil,
            agents: [agent],
            bossRegistration: registration,
            registrationByAgentName: ["boss": registration],
            injectionByAgentName: ["boss": .confirmed(.present)]
        )
        let entry = status.agents.entries.first { $0.name == "boss" }
        XCTAssertEqual(
            entry?.toolsInjection, .confirmed(.present),
            "the builder must thread injectionByAgentName into each HarnessAgentEntry.toolsInjection"
        )
    }

    /// The reachability/rollup axis must NOT regress: a config-installed + registered boss
    /// whose injection is merely unverified stays reachable (`.healthy`). Only the pill
    /// PRESENTATION changes — reachability keeps its existing status-based logic.
    func testReachabilityUnchangedForRegisteredButUnverifiedBoss() {
        let builder = HarnessStatusBuilder()
        let agent = OuroAgentRecord(
            name: "boss",
            bundlePath: "/bundle",
            configPath: "/cfg",
            status: .ready,
            detail: ""
        )
        let registration = BossWorkbenchMCPRegistrationSnapshot(
            agentName: "boss",
            serverName: "workbench",
            commandPath: "/usr/bin/ouro",
            agentConfigPath: "/cfg",
            status: .registered,
            detail: ""
        )
        let status = builder.build(
            boss: BossAgentSelection(agentName: "boss"),
            dashboard: nil,
            agents: [agent],
            bossRegistration: registration,
            registrationByAgentName: ["boss": registration],
            injectionByAgentName: [:] // not probed → unverified
        )
        XCTAssertTrue(
            status.boss.isReachable,
            "an unverified-but-registered boss must STILL be reachable — only the pill colour changes"
        )
    }

    // MARK: - App: all three pill render sites route through the seam with the verdict

    func testAgentDetailCardPillRoutesThroughSeamWithVerdict() throws {
        let body = try sourceSlice(
            from: "private struct AgentStatusCard: View {",
            to: "private struct AgentLanesCard: View {"
        )
        XCTAssertTrue(
            body.contains("BossMCPPillPresentation.tone("),
            "the agent-detail card pill must compute its tone via BossMCPPillPresentation"
        )
        XCTAssertTrue(
            body.contains("bossWorkbenchToolsInjectionByAgentName"),
            "the agent-detail card pill must thread the injection verdict, not switch on status alone"
        )
        XCTAssertFalse(
            body.contains("mcpPillColor(registration.status)"),
            "the status-only mcpPillColor(_ status:) must no longer drive the agent-detail pill"
        )
    }

    func testBossSectionRowPillRoutesThroughSeamWithVerdict() throws {
        let body = try sourceSlice(
            from: "struct OuroAgentRowView: View {",
            to: "struct ProviderConfigSheet: View {"
        )
        XCTAssertTrue(
            body.contains("BossMCPPillPresentation.tone("),
            "the boss-section row pill must compute its tone via BossMCPPillPresentation"
        )
        XCTAssertTrue(
            body.contains("bossWorkbenchToolsInjectionByAgentName"),
            "the boss-section row pill must thread the injection verdict, not switch on status alone"
        )
        XCTAssertFalse(
            body.contains("registrationTint(registration.status)"),
            "the status-only registrationTint(_ status:) must no longer drive the boss-section pill"
        )
    }

    func testHarnessDiagnosticPillRoutesThroughSeamWithVerdict() throws {
        let body = try sourceSlice(
            from: "private struct HarnessAgentRow: View {",
            to: "private struct HarnessActionRow: View {"
        )
        // The harness-diagnostic pill (entry.mcpStatus / entry.toolsInjection) must route
        // through the seam — no longer the status-only harnessShortLabel / harnessTint pair.
        XCTAssertTrue(
            body.contains("BossMCPPillPresentation.tone("),
            "the harness-diagnostic pill must compute its tone via BossMCPPillPresentation"
        )
        XCTAssertTrue(
            body.contains("entry.toolsInjection"),
            "the harness-diagnostic pill must read entry.toolsInjection (the threaded verdict)"
        )
        XCTAssertFalse(
            body.contains("mcpStatus.harnessShortLabel"),
            "the status-only harnessShortLabel must no longer drive the harness pill text"
        )
    }

    /// The App's `harnessStatus` builder call must pass the live injection map so the harness
    /// entries carry the verdict.
    func testHarnessStatusBuildPassesInjectionMap() throws {
        let body = try sourceSlice(
            from: "var harnessStatus: HarnessStatus {",
            to: "func refreshHarnessStatus() async {"
        )
        XCTAssertTrue(
            body.contains("injectionByAgentName:"),
            "the App's harnessStatus build call must pass injectionByAgentName"
        )
        XCTAssertTrue(
            body.contains("bossWorkbenchToolsInjectionByAgentName"),
            "the App must thread the live bossWorkbenchToolsInjectionByAgentName map into the builder"
        )
    }

    // MARK: - helpers (mirror AgentReadinessOverlayWiringTests)

    private func appSource() throws -> String {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("OuroWorkbenchApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceSlice(from startMarker: String, to endMarker: String) throws -> String {
        let source = try appSource()
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
        return String(source[start..<end])
    }
}
