import XCTest
@testable import OuroWorkbenchCore

/// Durable wiring assertions for the Harness Status sheet false-green fix.
///
/// The App target isn't coverage-gated and can't be click-tested in CI, so —
/// exactly like `AgentReadinessOverlayWiringTests` (the #261 sibling) — we pin
/// the structural wiring in source: the harness status build must thread the
/// SAME live `agentOutwardVerdicts` / `agentChecksInFlight` the steady-state
/// rows compute into the `HarnessAgentEntry` construction, and the harness pill
/// must render via the live-aware `liveReadiness` seam rather than the
/// config-only `harnessLabel` / `harnessTint`.
final class HarnessReadinessOverlayWiringTests: XCTestCase {

    // MARK: - Unit 2: the harness build threads the live verdict + in-flight maps

    func testHarnessStatusBuildThreadsLiveOutwardVerdicts() throws {
        let body = try harnessStatusComputedDecl()
        XCTAssertTrue(
            body.contains("outwardVerdicts: agentOutwardVerdicts"),
            "the harness status build must thread the live per-agent outward verdicts (the same map #261 computes) so the pills/rollups reflect a real check, not config-only"
        )
        XCTAssertTrue(
            body.contains("checksInFlight: agentChecksInFlight"),
            "the harness status build must thread the in-flight set so a mid-check agent reads 'checking…' rather than a premature pill"
        )
    }

    func testRefreshHarnessStatusKeepsTheOutwardVerdictDictCurrent() throws {
        // The sheet must NOT permanently show "not verified" because the dict was
        // never populated in its code path. refreshHarnessStatus drives the agent
        // scan, which (via #261) kicks off the live outward readiness check.
        let body = try refreshHarnessStatusBody()
        XCTAssertTrue(
            body.contains("refreshOuroAgents"),
            "refreshHarnessStatus must drive the agent scan path that populates the outward verdict dict (refreshOuroAgents → refreshAgentOutwardReadiness)"
        )
    }

    func testRefreshOuroAgentsTriggersTheOutwardReadinessCheck() throws {
        // Pin the chain that keeps the harness sheet honest: the scan the harness
        // refresh calls must in turn kick off the live readiness probe.
        let body = try refreshOuroAgentsBody()
        XCTAssertTrue(
            body.contains("refreshAgentOutwardReadiness"),
            "refreshOuroAgents (called by refreshHarnessStatus) must trigger the live outward readiness check so the harness sheet's verdict dict is populated"
        )
    }

    // MARK: - Helpers (mirror AgentReadinessOverlayWiringTests)

    private func harnessStatusComputedDecl() throws -> String {
        let source = try appSource()
        return try sourceSlice(
            in: source,
            from: "var harnessStatus: HarnessStatus {",
            to: "\n    func refreshHarnessStatus("
        )
    }

    private func refreshHarnessStatusBody() throws -> String {
        let source = try appSource()
        return try sourceSlice(
            in: source,
            from: "func refreshHarnessStatus(",
            to: "\n    var recentActionLogEntries"
        )
    }

    private func refreshOuroAgentsBody() throws -> String {
        let source = try appSource()
        return try sourceSlice(
            in: source,
            from: "func refreshOuroAgents() {",
            to: "\n    func "
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
