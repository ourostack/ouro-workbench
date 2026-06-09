import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class AgentRepairTests: XCTestCase {
    // MARK: - Recovery-truth classification (from the POST-command probe, never the exit code)

    func testClassifyRepairedWhenProbeReadsHealthy() {
        XCTAssertEqual(
            AgentRepairTruth.classify(probe: .healthy),
            .repaired
        )
    }

    func testClassifyStillDegradedWhenProbeReadsDegraded() {
        XCTAssertEqual(
            AgentRepairTruth.classify(probe: .degraded),
            .stillDegraded
        )
    }

    func testClassifyNeedsManualWhenProbeUnreachable() {
        XCTAssertEqual(
            AgentRepairTruth.classify(probe: .unreachable),
            .needsManual
        )
    }

    func testNeedsManualRecoveryFlagOnlyOnNeedsManual() {
        XCTAssertFalse(AgentRepairTruth.repaired.needsManualRecovery)
        XCTAssertFalse(AgentRepairTruth.stillDegraded.needsManualRecovery)
        XCTAssertTrue(AgentRepairTruth.needsManual.needsManualRecovery)
    }

    // MARK: - Human-facing copy is seam-free; audit copy carries the raw verb

    func testHumanFacingLineNeverLeaksCLISeams() {
        for truth in [AgentRepairTruth.repaired, .stillDegraded, .needsManual] {
            let line = truth.humanFacingLine(agentName: "slugger")
            XCTAssertFalse(line.lowercased().contains("ouro"), "human line leaked an ouro seam: \(line)")
            XCTAssertFalse(line.lowercased().contains("daemon"), "human line leaked a daemon seam: \(line)")
            XCTAssertFalse(line.contains("--agent"), "human line leaked a flag seam: \(line)")
        }
    }

    func testHumanFacingLineNamesTheAgent() {
        XCTAssertTrue(AgentRepairTruth.repaired.humanFacingLine(agentName: "slugger").contains("slugger"))
        XCTAssertTrue(AgentRepairTruth.needsManual.humanFacingLine(agentName: "ouroboros").contains("ouroboros"))
    }

    func testAuditDetailCarriesRawVerbAndExplicitAgent() {
        // Every recovery-truth's audit detail carries the raw verb + explicit agent name.
        for truth in [AgentRepairTruth.repaired, .stillDegraded, .needsManual] {
            XCTAssertTrue(
                truth.auditDetail(agentName: "slugger").contains("ouro repair --agent slugger"),
                "audit detail for \(truth.rawValue) must carry the explicit ouro verb"
            )
        }
        // And each is distinct (no copy collision between classifications).
        XCTAssertNotEqual(
            AgentRepairTruth.repaired.auditDetail(agentName: "slugger"),
            AgentRepairTruth.stillDegraded.auditDetail(agentName: "slugger")
        )
        XCTAssertNotEqual(
            AgentRepairTruth.stillDegraded.auditDetail(agentName: "slugger"),
            AgentRepairTruth.needsManual.auditDetail(agentName: "slugger")
        )
    }

    // MARK: - Runner: explicit agent-name guard (never default-agent resolution)

    func testRunnerRejectsEmptyAgentNameWithoutRunningCommand() async {
        let didRun = BoolFlag()
        let runner = AgentRepairRunner(
            runRepair: { _ in didRun.set() },
            verifyProbe: { _ in .healthy }
        )

        let outcome = await runner.repair(agentName: "   ")

        XCTAssertFalse(didRun.value, "command must NOT run without an explicit agent name")
        XCTAssertEqual(outcome.truth, .needsManual)
        XCTAssertFalse(outcome.commandAttempted)
    }

    func testRunnerClassifiesRepairedFromProbeNotExitCode() async {
        // The run closure "fails" (throws) but the post-command probe reads healthy:
        // recovery truth must come from the PROBE, so this is `repaired`, not a failure.
        let runner = AgentRepairRunner(
            runRepair: { _ in throw AgentRepairTestError.boom },
            verifyProbe: { _ in .healthy }
        )

        let outcome = await runner.repair(agentName: "slugger")

        XCTAssertTrue(outcome.commandAttempted)
        XCTAssertEqual(outcome.truth, .repaired)
        XCTAssertEqual(outcome.agentName, "slugger")
    }

    func testRunnerClassifiesStillDegradedWhenProbeStillDegraded() async {
        // The run closure succeeds (exit 0) but the probe still reads degraded:
        // a zero exit must NEVER produce a false "repaired".
        let runner = AgentRepairRunner(
            runRepair: { _ in },
            verifyProbe: { _ in .degraded }
        )

        let outcome = await runner.repair(agentName: "slugger")

        XCTAssertEqual(outcome.truth, .stillDegraded)
    }

    func testRunnerClassifiesNeedsManualWhenProbeUnreachable() async {
        let runner = AgentRepairRunner(
            runRepair: { _ in },
            verifyProbe: { _ in .unreachable }
        )

        let outcome = await runner.repair(agentName: "slugger")

        XCTAssertEqual(outcome.truth, .needsManual)
    }

    func testRunnerPassesExplicitAgentNameToBothRunAndProbe() async {
        let ranWith = StringBox()
        let probedWith = StringBox()
        let runner = AgentRepairRunner(
            runRepair: { name in ranWith.set(name) },
            verifyProbe: { name in
                probedWith.set(name)
                return .healthy
            }
        )

        _ = await runner.repair(agentName: "slugger")

        XCTAssertEqual(ranWith.value, "slugger")
        XCTAssertEqual(probedWith.value, "slugger")
    }

    func testOutcomeResultLineIsSeamFreeAndAuditDetailRaw() async {
        let runner = AgentRepairRunner(
            runRepair: { _ in },
            verifyProbe: { _ in .healthy }
        )

        let outcome = await runner.repair(agentName: "slugger")

        XCTAssertFalse(outcome.humanFacingLine.lowercased().contains("ouro"))
        XCTAssertTrue(outcome.auditDetail.contains("ouro repair --agent slugger"))
    }
}

private enum AgentRepairTestError: Error {
    case boom
}

private final class BoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

private final class StringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?

    func set(_ value: String) {
        lock.lock()
        stored = value
        lock.unlock()
    }

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
