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

    // MARK: - Unit 3: the harness pill renders via the live-aware seam

    func testHarnessAgentRowNoLongerDerivesReadinessFromConfigOnlyLabelTint() throws {
        let body = try harnessAgentRowDecl()
        XCTAssertFalse(
            body.contains("entry.status.harnessLabel"),
            "the harness pill must NOT label off the config-only OuroAgentBundleStatus.harnessLabel (that was the false green)"
        )
        XCTAssertFalse(
            body.contains("entry.status.harnessTint"),
            "the harness pill/dot must NOT tint off the config-only OuroAgentBundleStatus.harnessTint"
        )
    }

    func testHarnessAgentRowRendersViaLiveReadinessSeam() throws {
        let body = try harnessAgentRowDecl()
        XCTAssertTrue(
            body.contains("entry.liveReadiness"),
            "the row must resolve the live readiness (folds the live outward verdict + in-flight flag through the shared seam)"
        )
        XCTAssertTrue(
            body.contains("InstalledAgentRowPresentation.label(for:"),
            "the pill label must come from the live-aware InstalledAgentRowPresentation.label(for:)"
        )
        XCTAssertTrue(
            body.contains("InstalledAgentRowPresentation.dotColor(for:"),
            "the pill/dot tint must come from the live-aware InstalledAgentRowPresentation.dotColor(for:)"
        )
        XCTAssertTrue(
            body.contains("InstalledAgentRowPresentation.help(for:"),
            "the row tooltip must come from the live-aware InstalledAgentRowPresentation.help(for:detail:)"
        )
    }

    func testConfigOnlyHarnessLabelAndTintExtensionRemoved() throws {
        // Once the row routes through the live seam, the config-only
        // OuroAgentBundleStatus.harnessLabel / harnessTint extension is dead code;
        // an unused private decl breaks -warnings-as-errors, so it must be gone.
        let source = try WorkbenchAppSource.appSource()
        let bundleStatusExtension = "private extension OuroAgentBundleStatus {"
        if let range = source.range(of: bundleStatusExtension) {
            let slice = source[range.lowerBound...]
            // If the extension still exists at all, it must not re-declare the
            // config-only readiness label/tint that the live seam replaced.
            let extBody = String(slice.prefix(400))
            XCTAssertFalse(
                extBody.contains("var harnessLabel"),
                "the config-only OuroAgentBundleStatus.harnessLabel must be removed once the row uses the live seam"
            )
            XCTAssertFalse(
                extBody.contains("var harnessTint"),
                "the config-only OuroAgentBundleStatus.harnessTint must be removed once the row uses the live seam"
            )
        }
    }

    // MARK: - Helpers (mirror AgentReadinessOverlayWiringTests)

    private func harnessAgentRowDecl() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "private struct HarnessAgentRow: View {",
            to: "\n/// A confirm-gated control button"
        )
    }

    private func harnessStatusComputedDecl() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "var harnessStatus: HarnessStatus {",
            to: "\n    func refreshHarnessStatus("
        )
    }

    private func refreshHarnessStatusBody() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func refreshHarnessStatus(",
            to: "\n    var recentActionLogEntries"
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
}
