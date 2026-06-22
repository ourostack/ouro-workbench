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
        let source = try appSource()
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

    // MARK: - Helpers (mirror ColdStartHonestWiringTests)

    private func refreshOuroAgentsBody() throws -> String {
        let source = try appSource()
        return try sourceSlice(
            in: source,
            from: "func refreshOuroAgents() {",
            to: "\n    func "
        )
    }

    private func refreshAgentOutwardReadinessBody() throws -> String {
        let source = try appSource()
        return try sourceSlice(
            in: source,
            from: "func refreshAgentOutwardReadiness(",
            to: "\n    private func runColdStartProviderCheck"
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
