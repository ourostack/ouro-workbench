import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class ProviderRefreshTests: XCTestCase {
    // MARK: - Recovery-truth classification (from the POST-command probe, never the exit code)

    func testClassifyRefreshedWhenProbeReadsHealthy() {
        XCTAssertEqual(ProviderRefreshTruth.classify(probe: .healthy), .refreshed)
    }

    func testClassifyStillDegradedWhenProbeReadsDegraded() {
        XCTAssertEqual(ProviderRefreshTruth.classify(probe: .degraded), .stillDegraded)
    }

    func testClassifyNeedsManualWhenProbeUnreachable() {
        XCTAssertEqual(ProviderRefreshTruth.classify(probe: .unreachable), .needsManual)
    }

    func testNeedsManualRecoveryFlagOnlyOnNeedsManual() {
        XCTAssertFalse(ProviderRefreshTruth.refreshed.needsManualRecovery)
        XCTAssertFalse(ProviderRefreshTruth.stillDegraded.needsManualRecovery)
        XCTAssertTrue(ProviderRefreshTruth.needsManual.needsManualRecovery)
    }

    // MARK: - Cohesive copy

    func testHumanFacingLineNeverLeaksCLISeams() {
        for truth in [ProviderRefreshTruth.refreshed, .stillDegraded, .needsManual] {
            let line = truth.humanFacingLine(agentName: "slugger")
            XCTAssertFalse(line.lowercased().contains("ouro"))
            XCTAssertFalse(line.lowercased().contains("daemon"))
            XCTAssertFalse(line.contains("--agent"))
            XCTAssertFalse(line.lowercased().contains("provider refresh"))
        }
    }

    func testHumanFacingLineNamesTheAgent() {
        XCTAssertTrue(ProviderRefreshTruth.refreshed.humanFacingLine(agentName: "slugger").contains("slugger"))
        XCTAssertTrue(ProviderRefreshTruth.needsManual.humanFacingLine(agentName: "ouroboros").contains("ouroboros"))
    }

    func testAuditDetailCarriesRawVerbAndExplicitAgent() {
        for truth in [ProviderRefreshTruth.refreshed, .stillDegraded, .needsManual] {
            XCTAssertTrue(
                truth.auditDetail(agentName: "slugger").contains("ouro provider refresh --agent slugger"),
                "audit detail for \(truth.rawValue) must carry the explicit ouro verb"
            )
        }
        XCTAssertNotEqual(
            ProviderRefreshTruth.refreshed.auditDetail(agentName: "slugger"),
            ProviderRefreshTruth.stillDegraded.auditDetail(agentName: "slugger")
        )
        XCTAssertNotEqual(
            ProviderRefreshTruth.stillDegraded.auditDetail(agentName: "slugger"),
            ProviderRefreshTruth.needsManual.auditDetail(agentName: "slugger")
        )
    }

    // MARK: - Runner

    func testRunnerRejectsEmptyAgentNameWithoutRunningCommand() async {
        let didRun = RefreshBoolFlag()
        let runner = ProviderRefreshRunner(
            runRefresh: { _ in didRun.set() },
            verifyProbe: { _ in .healthy }
        )
        let outcome = await runner.refresh(agentName: " ")
        XCTAssertFalse(didRun.value)
        XCTAssertEqual(outcome.truth, .needsManual)
        XCTAssertFalse(outcome.commandAttempted)
    }

    func testRunnerClassifiesRefreshedFromProbeNotExitCode() async {
        let runner = ProviderRefreshRunner(
            runRefresh: { _ in throw RefreshTestError.boom },
            verifyProbe: { _ in .healthy }
        )
        let outcome = await runner.refresh(agentName: "slugger")
        XCTAssertTrue(outcome.commandAttempted)
        XCTAssertEqual(outcome.truth, .refreshed)
        XCTAssertEqual(outcome.agentName, "slugger")
    }

    func testRunnerClassifiesStillDegradedWhenProbeDegraded() async {
        let runner = ProviderRefreshRunner(runRefresh: { _ in }, verifyProbe: { _ in .degraded })
        let outcome = await runner.refresh(agentName: "slugger")
        XCTAssertEqual(outcome.truth, .stillDegraded)
    }

    func testRunnerClassifiesNeedsManualWhenProbeUnreachable() async {
        let runner = ProviderRefreshRunner(runRefresh: { _ in }, verifyProbe: { _ in .unreachable })
        let outcome = await runner.refresh(agentName: "slugger")
        XCTAssertEqual(outcome.truth, .needsManual)
    }

    func testRunnerPassesExplicitAgentNameToBothRunAndProbe() async {
        let ranWith = RefreshStringBox()
        let probedWith = RefreshStringBox()
        let runner = ProviderRefreshRunner(
            runRefresh: { name in ranWith.set(name) },
            verifyProbe: { name in probedWith.set(name); return .healthy }
        )
        _ = await runner.refresh(agentName: "slugger")
        XCTAssertEqual(ranWith.value, "slugger")
        XCTAssertEqual(probedWith.value, "slugger")
    }

    func testOutcomeResultLineIsSeamFreeAndAuditDetailRaw() async {
        let runner = ProviderRefreshRunner(runRefresh: { _ in }, verifyProbe: { _ in .healthy })
        let outcome = await runner.refresh(agentName: "slugger")
        XCTAssertFalse(outcome.humanFacingLine.lowercased().contains("ouro"))
        XCTAssertTrue(outcome.auditDetail.contains("ouro provider refresh --agent slugger"))
    }
}

private enum RefreshTestError: Error { case boom }

private final class RefreshBoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.lock(); stored = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class RefreshStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ value: String) { lock.lock(); stored = value; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
}
