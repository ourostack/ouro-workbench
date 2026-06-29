import XCTest
@testable import OuroWorkbenchCore

/// Durable wiring assertions for the steady-state agent-readiness fix (live overlay).
/// The App target isn't coverage-gated and can't be click-tested in CI, so — exactly
/// like `ColdStartHonestWiringTests` / `ProviderCheckClassifierWiringTests` — we pin the
/// structural wiring in source: the viewmodel must actually RUN a live `ouro check` for
/// every config-ready agent with a configured outward lane, store the resulting verdict,
/// and feed that into the rows so a config-only `.ready` no longer reads green without a
/// live confirmation.
final class AgentReadinessOverlayWiringTests: XCTestCase {

    // MARK: - Unit 2: viewmodel runs the live check + stores verdicts

    func testViewModelDeclaresOutwardVerdictAndInflightState() throws {
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("@Published var agentOutwardVerdicts: [String: ProviderConnectionVerdict]"),
            "the viewmodel must publish per-agent outward verdicts so rows can render live readiness"
        )
        XCTAssertTrue(
            source.contains("@Published var agentChecksInFlight: Set<String>"),
            "the viewmodel must publish the in-flight set so rows can show a 'checking' state"
        )
    }

    func testRefreshOuroAgentsKicksOffTheLiveReadinessCheck() throws {
        let body = try refreshOuroAgentsBody()
        XCTAssertTrue(
            body.contains("refreshAgentOutwardReadiness"),
            "refreshOuroAgents must trigger the live outward-readiness check (so it fires on launch AND on the Refresh Agents button)"
        )
    }

    func testRefreshAgentOutwardReadinessRunsTheLiveCheck() throws {
        let body = try refreshAgentOutwardReadinessBody()
        XCTAssertTrue(
            body.contains("runColdStartProviderCheck"),
            "the readiness refresh must run the real ouro-check probe (reuse the F1 runner), not synthesize a verdict"
        )
        XCTAssertTrue(
            body.contains("\"outward\""),
            "the readiness check must run the OUTWARD lane (the human-facing lane the rows surface)"
        )
    }

    func testRefreshAgentOutwardReadinessGatesOnReadyStatusAndConfiguredLane() throws {
        let body = try refreshAgentOutwardReadinessBody()
        // Only config-ready agents are worth probing (a disabled / missing / invalid bundle
        // can't connect), and only when the outward lane is actually configured.
        XCTAssertTrue(
            body.contains(".ready"),
            "only config-ready agents should be probed"
        )
        XCTAssertTrue(
            body.contains("humanFacing"),
            "the probe must gate on a configured outward (humanFacing) lane"
        )
    }

    func testRefreshAgentOutwardReadinessStoresVerdictsAndClearsInflight() throws {
        let body = try refreshAgentOutwardReadinessBody()
        XCTAssertTrue(
            body.contains("agentOutwardVerdicts"),
            "the probe result must be stored in agentOutwardVerdicts"
        )
        XCTAssertTrue(
            body.contains("agentChecksInFlight"),
            "the probe must mark/clear in-flight state in agentChecksInFlight"
        )
    }

    func testRefreshAgentOutwardReadinessRunsChecksConcurrently() throws {
        let body = try refreshAgentOutwardReadinessBody()
        XCTAssertTrue(
            body.contains("TaskGroup") || body.contains("withTaskGroup"),
            "per-agent checks must run concurrently (a TaskGroup), not serially, so one slow agent doesn't block the rest"
        )
    }

    // MARK: - Unit 3: rows route through the live-aware seam

    func testSidebarAgentRowTakesLiveReadinessInputs() throws {
        let body = try sidebarAgentRowDecl()
        XCTAssertTrue(
            body.contains("verdict: ProviderConnectionVerdict?"),
            "SidebarAgentRow must accept a live ProviderConnectionVerdict? so the row reflects the real check"
        )
        XCTAssertTrue(
            body.contains("isChecking"),
            "SidebarAgentRow must know whether a live check is in flight (to show 'checking…')"
        )
    }

    func testSidebarAgentRowDotNoLongerDerivedFromConfigStatus() throws {
        let body = try sidebarAgentRowDecl()
        XCTAssertFalse(
            body.contains("dotColor(for: agent.status)"),
            "the dot must NOT be derived from the config-only agent.status (that was the false green)"
        )
    }

    func testSidebarAgentRowDotDerivedFromLiveReadiness() throws {
        let body = try sidebarAgentRowDecl()
        XCTAssertTrue(
            body.contains("liveReadiness"),
            "the row must resolve a live readiness via InstalledAgentRowPresentation.liveReadiness"
        )
        XCTAssertTrue(
            body.contains("dotColor(for: liveReadiness)"),
            "the dot must be derived from the live readiness, not the config status"
        )
    }

    func testSidebarAgentRowTooltipNoLongerRawDetail() throws {
        let body = try sidebarAgentRowDecl()
        XCTAssertFalse(
            body.contains(".help(agent.detail)"),
            "the readiness tooltip must no longer be the raw config detail (which said 'ready' for a dead agent)"
        )
        XCTAssertTrue(
            body.contains("help(for: liveReadiness"),
            "the tooltip must come from the live-aware InstalledAgentRowPresentation.help(for:detail:)"
        )
    }

    func testSidebarAgentRowCallSitesThreadLiveState() throws {
        let source = try WorkbenchAppSource.appSource()
        // Both call sites (home-screen "Installed agents" card + the sidebar list) must thread the
        // per-agent live verdict + in-flight flag from the viewmodel into the row.
        let occurrences = source.components(separatedBy: "agentOutwardVerdicts[").count - 1
        XCTAssertGreaterThanOrEqual(
            occurrences, 2,
            "both SidebarAgentRow call sites must pass model.agentOutwardVerdicts[agent.name]"
        )
        let inflight = source.components(separatedBy: "agentChecksInFlight.contains(").count - 1
        XCTAssertGreaterThanOrEqual(
            inflight, 2,
            "both SidebarAgentRow call sites must pass model.agentChecksInFlight.contains(agent.name)"
        )
    }

    // MARK: - Helpers (mirror ColdStartHonestWiringTests)

    private func sidebarAgentRowDecl() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "struct SidebarAgentRow: View {",
            to: "\nprivate extension InstalledAgentRowPresentation.DotColor {"
        )
    }

    private func refreshOuroAgentsBody() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func refreshOuroAgents() {",
            to: "\n    func "
        )
    }

    private func refreshAgentOutwardReadinessBody() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func refreshAgentOutwardReadiness(",
            // VM-GATE: `private`-agnostic — runColdStartProviderCheck was widened private->internal.
            to: "\n    func runColdStartProviderCheck"
        )
    }
}
