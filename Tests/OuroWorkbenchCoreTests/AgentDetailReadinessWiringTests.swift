import XCTest
@testable import OuroWorkbenchCore

/// Durable wiring assertions for the agent DETAIL-pane false-green sweep (Unit 2).
///
/// PRs #261/#262 made the sidebar / home rows + the harness diagnostic live-aware,
/// but a grep sweep found the agent detail pane (`OuroAgentRowView`,
/// `AgentTitleStrip`, `AgentStatusCard`) STILL deriving its dot color / icon / pill
/// / help from raw config `agent.status` — so an expired-token agent (config-`.ready`,
/// live `.authExpired`) drew a green dot, a `checkmark.seal.fill`, and a "ready" pill.
///
/// The App target isn't coverage-gated and can't be click-tested in CI, so — exactly
/// like `AgentReadinessOverlayWiringTests` (the #261 sibling) — we PIN the structural
/// wiring in source: each of these structs must resolve a live `liveReadiness`
/// (folding in `model.agentOutwardVerdicts[agent.name]` + `model.agentChecksInFlight`)
/// and derive its readiness surface from that seam, NOT from `agent.status`.
final class AgentDetailReadinessWiringTests: XCTestCase {

    // MARK: - Surface 1: OuroAgentRowView (empty-state "Installed agents" row)

    func testOuroAgentRowResolvesLiveReadinessThreadingTheViewModelMaps() throws {
        let body = try ouroAgentRowDecl()
        XCTAssertTrue(
            body.contains("InstalledAgentRowPresentation.liveReadiness"),
            "OuroAgentRowView must resolve a live readiness via the Core seam"
        )
        XCTAssertTrue(
            body.contains("model.agentOutwardVerdicts[agent.name]"),
            "OuroAgentRowView must thread the live per-agent outward verdict from the viewmodel"
        )
        XCTAssertTrue(
            body.contains("model.agentChecksInFlight.contains(agent.name)"),
            "OuroAgentRowView must thread the in-flight flag so a mid-check agent reads 'checking…'"
        )
    }

    func testOuroAgentRowDotNoLongerDerivedFromConfigStatus() throws {
        let body = try ouroAgentRowDecl()
        XCTAssertFalse(
            body.contains("switch agent.status"),
            "OuroAgentRowView must NOT switch on the config-only agent.status for its color/icon (that was the false green)"
        )
        XCTAssertTrue(
            body.contains("dotColor(for: liveReadiness)"),
            "the dot color must come from the live readiness via the Core seam"
        )
    }

    func testOuroAgentRowIconRoutesThroughTheSharedIconSeam() throws {
        let body = try ouroAgentRowDecl()
        XCTAssertTrue(
            body.contains("InstalledAgentRowPresentation.iconSystemName(for: liveReadiness)"),
            "OuroAgentRowView's icon must come from the shared iconSystemName seam (success glyph only from .ready)"
        )
    }

    func testOuroAgentRowHelpNoLongerRawDetail() throws {
        let body = try ouroAgentRowDecl()
        XCTAssertFalse(
            body.contains(".help(agent.detail)"),
            "the readiness tooltip must no longer be the raw config detail (which said 'ready' for a dead agent)"
        )
        XCTAssertTrue(
            body.contains("help(for: liveReadiness"),
            "the tooltip must come from the live-aware InstalledAgentRowPresentation.help(for:detail:)"
        )
    }

    // MARK: - Surface 2: AgentTitleStrip (detail-pane title bar dot)

    func testAgentTitleStripResolvesLiveReadinessThreadingTheViewModelMaps() throws {
        let body = try agentTitleStripDecl()
        XCTAssertTrue(
            body.contains("InstalledAgentRowPresentation.liveReadiness"),
            "AgentTitleStrip must resolve a live readiness via the Core seam"
        )
        XCTAssertTrue(
            body.contains("model.agentOutwardVerdicts[agent.name]"),
            "AgentTitleStrip must thread the live per-agent outward verdict from the viewmodel"
        )
        XCTAssertTrue(
            body.contains("model.agentChecksInFlight.contains(agent.name)"),
            "AgentTitleStrip must thread the in-flight flag"
        )
    }

    func testAgentTitleStripDotNoLongerDerivedFromConfigStatus() throws {
        let body = try agentTitleStripDecl()
        XCTAssertFalse(
            body.contains("switch agent.status"),
            "AgentTitleStrip must NOT switch on the config-only agent.status for its dot color"
        )
        XCTAssertTrue(
            body.contains("dotColor(for: liveReadiness)"),
            "AgentTitleStrip's dot color must come from the live readiness via the Core seam"
        )
    }

    // MARK: - Surface 3: AgentStatusCard (detail-pane status card icon + pill)

    func testAgentStatusCardResolvesLiveReadinessThreadingTheViewModelMaps() throws {
        let body = try agentStatusCardDecl()
        XCTAssertTrue(
            body.contains("InstalledAgentRowPresentation.liveReadiness"),
            "AgentStatusCard must resolve a live readiness via the Core seam"
        )
        XCTAssertTrue(
            body.contains("model.agentOutwardVerdicts[agent.name]"),
            "AgentStatusCard must thread the live per-agent outward verdict from the viewmodel"
        )
        XCTAssertTrue(
            body.contains("model.agentChecksInFlight.contains(agent.name)"),
            "AgentStatusCard must thread the in-flight flag"
        )
    }

    func testAgentStatusCardIconRoutesThroughTheSharedIconSeam() throws {
        let body = try agentStatusCardDecl()
        XCTAssertTrue(
            body.contains("InstalledAgentRowPresentation.iconSystemName(for: liveReadiness)"),
            "AgentStatusCard's icon must come from the shared iconSystemName seam — checkmark.seal.fill reachable ONLY from .ready"
        )
        XCTAssertFalse(
            body.contains("return \"checkmark.seal.fill\""),
            "AgentStatusCard must NOT hardcode the success seal off config .ready (that was the false green)"
        )
    }

    func testAgentStatusCardPillRoutesThroughTheLiveLabel() throws {
        let body = try agentStatusCardDecl()
        XCTAssertTrue(
            body.contains("label(for: liveReadiness)"),
            "AgentStatusCard's bundle-status pill text must come from the live-aware label(for:) seam"
        )
        XCTAssertFalse(
            body.contains("bundleStatusPillText"),
            "the config-only bundleStatusPillText switch must be gone — the pill reads the live label now"
        )
    }

    func testAgentStatusCardColorNoLongerDerivedFromConfigStatus() throws {
        let body = try agentStatusCardDecl()
        XCTAssertTrue(
            body.contains("dotColor(for: liveReadiness)"),
            "AgentStatusCard's color must come from the live readiness via the Core seam"
        )
    }

    // MARK: - Helpers (mirror AgentReadinessOverlayWiringTests)

    private func ouroAgentRowDecl() throws -> String {
        let source = try appSource()
        return try sourceSlice(
            in: source,
            from: "struct OuroAgentRowView: View {",
            to: "\n/// The native provider-config form"
        )
    }

    private func agentTitleStripDecl() throws -> String {
        let source = try appSource()
        return try sourceSlice(
            in: source,
            from: "private struct AgentTitleStrip: View {",
            to: "\nprivate struct AgentInspectorPanel: View {"
        )
    }

    private func agentStatusCardDecl() throws -> String {
        let source = try appSource()
        return try sourceSlice(
            in: source,
            from: "private struct AgentStatusCard: View {",
            to: "\nprivate struct AgentLanesCard: View {"
        )
    }

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

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
        return String(source[start..<end])
    }
}
