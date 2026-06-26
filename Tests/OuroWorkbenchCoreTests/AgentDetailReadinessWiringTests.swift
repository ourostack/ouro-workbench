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

    func testAgentStatusCardHeadlineRoutesThroughTheLiveSeam() throws {
        let body = try agentStatusCardDecl()
        // The headline must derive from the live readiness via the Core seam, not from a
        // raw config-status switch — the residual the #261/#262 sweep missed: a config-`.ready`
        // agent with a live `.authExpired` verdict still read the prominent title "Bundle ready".
        XCTAssertTrue(
            body.contains("InstalledAgentRowPresentation.headline(for: liveReadiness"),
            "AgentStatusCard's statusHeadline must come from the live-aware headline(for:detail:) seam"
        )
        // Locate the statusHeadline computed property and prove it no longer switches on
        // agent.status and no longer hardcodes the "Bundle ready" title off raw config.
        // `statusHeadline` is now the last member of AgentStatusCard (the verdict-aware
        // MCP-pill fix removed the trailing `mcpPillText`/`mcpPillColor` helpers that this
        // slice used to anchor on), so end the slice at the struct's closing brace.
        let headlineDecl = try WorkbenchAppSource.sourceSlice(
            in: body,
            from: "private var statusHeadline: String {",
            to: "\n}"
        )
        XCTAssertFalse(
            headlineDecl.contains("switch agent.status"),
            "statusHeadline must NOT switch on the config-only agent.status (that was the residual false 'ready')"
        )
        XCTAssertFalse(
            headlineDecl.contains("\"Bundle ready\""),
            "statusHeadline must NOT return the prominent \"Bundle ready\" title off a raw agent.status switch independent of the live verdict"
        )
    }

    // MARK: - Helpers (mirror AgentReadinessOverlayWiringTests)

    private func ouroAgentRowDecl() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "struct OuroAgentRowView: View {",
            to: "\n/// The native provider-config form"
        )
    }

    private func agentTitleStripDecl() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            // `AgentTitleStrip` was widened `private`→`internal` (C7-2, the SU-E / C0 SU-3
            // precedent — the agent-title-strip snapshot test reaches it via `@testable
            // import`), so its declaration line dropped the `private` keyword.
            from: "\nstruct AgentTitleStrip: View {",
            // `AgentInspectorPanel` was likewise widened `private`→`internal` (C0 SU-3), so
            // its declaration line dropped `private`. The slice still bounds the
            // `AgentTitleStrip` declaration at where `AgentInspectorPanel` begins.
            to: "\nstruct AgentInspectorPanel: View {"
        )
    }

    private func agentStatusCardDecl() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "private struct AgentStatusCard: View {",
            to: "\nprivate struct AgentLanesCard: View {"
        )
    }
}
