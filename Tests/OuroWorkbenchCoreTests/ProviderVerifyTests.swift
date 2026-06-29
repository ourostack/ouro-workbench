import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class ProviderVerifyTests: XCTestCase {
    // MARK: - ProviderLane

    func testProviderLaneRawValues() {
        XCTAssertEqual(ProviderLane.outward.rawValue, "outward")
        XCTAssertEqual(ProviderLane.inner.rawValue, "inner")
    }

    func testProviderLaneFlagTokens() {
        XCTAssertEqual(ProviderLane.outward.checkTokens(agentName: "slugger"),
                       ["ouro", "check", "--agent", "slugger", "--lane", "outward"])
        XCTAssertEqual(ProviderLane.inner.checkTokens(agentName: "slugger"),
                       ["ouro", "check", "--agent", "slugger", "--lane", "inner"])
    }

    // MARK: - Recovery-truth classification (from the POST-command probe, never the exit code)

    func testClassifyVerifiedWhenProbeReadsHealthy() {
        XCTAssertEqual(ProviderVerifyTruth.classify(probe: .healthy), .verified)
    }

    func testClassifyStillUnverifiedWhenProbeReadsDegraded() {
        XCTAssertEqual(ProviderVerifyTruth.classify(probe: .degraded), .stillUnverified)
    }

    func testClassifyNeedsManualWhenProbeUnreachable() {
        XCTAssertEqual(ProviderVerifyTruth.classify(probe: .unreachable), .needsManual)
    }

    func testNeedsManualRecoveryFlagOnlyOnNeedsManual() {
        XCTAssertFalse(ProviderVerifyTruth.verified.needsManualRecovery)
        XCTAssertFalse(ProviderVerifyTruth.stillUnverified.needsManualRecovery)
        XCTAssertTrue(ProviderVerifyTruth.needsManual.needsManualRecovery)
    }

    // MARK: - Human-facing copy is seam-free; audit copy carries the raw verb

    func testHumanFacingLineNeverLeaksCLISeams() {
        for truth in [ProviderVerifyTruth.verified, .stillUnverified, .needsManual] {
            let line = truth.humanFacingLine(agentName: "slugger")
            XCTAssertFalse(line.lowercased().contains("ouro"), "human line leaked an ouro seam: \(line)")
            XCTAssertFalse(line.lowercased().contains("daemon"), "human line leaked a daemon seam: \(line)")
            XCTAssertFalse(line.contains("--agent"), "human line leaked a flag seam: \(line)")
            XCTAssertFalse(line.lowercased().contains("--lane"), "human line leaked a flag seam: \(line)")
        }
    }

    func testHumanFacingLineNamesTheAgent() {
        XCTAssertTrue(ProviderVerifyTruth.verified.humanFacingLine(agentName: "slugger").contains("slugger"))
        XCTAssertTrue(ProviderVerifyTruth.needsManual.humanFacingLine(agentName: "ouroboros").contains("ouroboros"))
    }

    func testAuditDetailCarriesRawVerbAndExplicitAgentNoLane() {
        for truth in [ProviderVerifyTruth.verified, .stillUnverified, .needsManual] {
            let detail = truth.auditDetail(agentName: "slugger", lane: nil)
            XCTAssertTrue(detail.contains("ouro auth verify --agent slugger"),
                          "audit detail for \(truth.rawValue) must carry the explicit ouro verb")
        }
    }

    func testAuditDetailCarriesLaneWhenPresent() {
        let detail = ProviderVerifyTruth.verified.auditDetail(agentName: "slugger", lane: .outward)
        XCTAssertTrue(detail.contains("ouro check --agent slugger --lane outward"),
                      "lane-scoped audit detail must use the check verb with the lane: \(detail)")
    }

    func testAuditDetailsAreDistinctPerClassification() {
        XCTAssertNotEqual(
            ProviderVerifyTruth.verified.auditDetail(agentName: "slugger", lane: nil),
            ProviderVerifyTruth.stillUnverified.auditDetail(agentName: "slugger", lane: nil)
        )
        XCTAssertNotEqual(
            ProviderVerifyTruth.stillUnverified.auditDetail(agentName: "slugger", lane: nil),
            ProviderVerifyTruth.needsManual.auditDetail(agentName: "slugger", lane: nil)
        )
    }

    // MARK: - Runner: explicit agent-name guard (never default-agent resolution)

    func testRunnerRejectsEmptyAgentNameWithoutRunningCommand() async {
        let defaultVerifyRunner = ProviderVerifyRunner(verifyProbe: { _, _ in .healthy })
        let defaultOutcome = await defaultVerifyRunner.verify(agentName: "   ", lane: nil)
        XCTAssertFalse(defaultOutcome.commandAttempted)
        XCTAssertEqual(defaultOutcome.truth, .needsManual)

        let didRunNonEmpty = ProviderVerifyBoolFlag()
        let nonEmptyRunner = ProviderVerifyRunner(
            runVerify: { _, _ in didRunNonEmpty.set() },
            verifyProbe: { _, _ in .healthy }
        )
        let commandOutcome = await nonEmptyRunner.verify(agentName: "slugger", lane: nil)
        XCTAssertTrue(didRunNonEmpty.value)
        XCTAssertTrue(commandOutcome.commandAttempted)
        XCTAssertEqual(commandOutcome.truth, .verified)

        let didRunEmpty = ProviderVerifyBoolFlag()
        let emptyRunner = ProviderVerifyRunner(
            runVerify: { _, _ in didRunEmpty.set() },
            verifyProbe: { _, _ in .healthy }
        )

        let outcome = await emptyRunner.verify(agentName: "   ", lane: nil)

        XCTAssertFalse(didRunEmpty.value, "command must NOT run without an explicit agent name")
        XCTAssertEqual(outcome.truth, .needsManual)
        XCTAssertFalse(outcome.commandAttempted)
    }

    func testRunnerClassifiesVerifiedFromProbeNotExitCode() async {
        let runner = ProviderVerifyRunner(
            runVerify: { _, _ in throw ProviderVerifyTestError.boom },
            verifyProbe: { _, _ in .healthy }
        )

        let outcome = await runner.verify(agentName: "slugger", lane: nil)

        XCTAssertTrue(outcome.commandAttempted)
        XCTAssertEqual(outcome.truth, .verified)
        XCTAssertEqual(outcome.agentName, "slugger")
        XCTAssertNil(outcome.lane)
    }

    func testRunnerClassifiesStillUnverifiedWhenProbeDegraded() async {
        let runner = ProviderVerifyRunner(
            runVerify: { _, _ in },
            verifyProbe: { _, _ in .degraded }
        )

        let outcome = await runner.verify(agentName: "slugger", lane: .inner)

        XCTAssertEqual(outcome.truth, .stillUnverified)
        XCTAssertEqual(outcome.lane, .inner)
    }

    func testRunnerClassifiesNeedsManualWhenProbeUnreachable() async {
        let runner = ProviderVerifyRunner(
            runVerify: { _, _ in },
            verifyProbe: { _, _ in .unreachable }
        )

        let outcome = await runner.verify(agentName: "slugger", lane: nil)

        XCTAssertEqual(outcome.truth, .needsManual)
    }

    func testRunnerPassesExplicitAgentNameAndLaneToBothRunAndProbe() async {
        let ranWith = ProviderVerifyStringBox()
        let probedWith = ProviderVerifyStringBox()
        let runner = ProviderVerifyRunner(
            runVerify: { name, lane in ranWith.set("\(name)|\(lane?.rawValue ?? "nil")") },
            verifyProbe: { name, lane in
                probedWith.set("\(name)|\(lane?.rawValue ?? "nil")")
                return .healthy
            }
        )

        _ = await runner.verify(agentName: "slugger", lane: .outward)

        XCTAssertEqual(ranWith.value, "slugger|outward")
        XCTAssertEqual(probedWith.value, "slugger|outward")
    }

    func testOutcomeResultLineIsSeamFreeAndAuditDetailRaw() async {
        let runner = ProviderVerifyRunner(
            runVerify: { _, _ in },
            verifyProbe: { _, _ in .healthy }
        )

        let outcome = await runner.verify(agentName: "slugger", lane: nil)

        XCTAssertFalse(outcome.humanFacingLine.lowercased().contains("ouro"))
        XCTAssertTrue(outcome.auditDetail.contains("ouro auth verify --agent slugger"))
    }

    func testOutcomeNeedsManualRecoveryDelegatesToTruth() {
        let manual = ProviderVerifyOutcome(agentName: "slugger", lane: nil, truth: .needsManual, commandAttempted: true)
        let verified = ProviderVerifyOutcome(agentName: "slugger", lane: nil, truth: .verified, commandAttempted: true)

        XCTAssertTrue(manual.needsManualRecovery)
        XCTAssertFalse(verified.needsManualRecovery)
    }

    func testDefaultHeadlessVerifyRunsLaneAndWholeAgentCommands() async throws {
        let root = try coverageBatch2TemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let argsFile = root.appendingPathComponent("args.txt")
        let environment = try coverageBatch2FakeOuroEnvironment(
            in: root,
            body: "printf '%s\\n' \"$@\" > '\(argsFile.path)'\nexit 0\n"
        )

        try await ProviderVerifyRunner.headlessVerify(agentName: "slugger", lane: .inner, environment: environment)
        XCTAssertEqual(try String(contentsOf: argsFile, encoding: .utf8), "check\n--agent\nslugger\n--lane\ninner\n")

        try await ProviderVerifyRunner.headlessVerify(agentName: "slugger", lane: nil, environment: environment)
        XCTAssertEqual(try String(contentsOf: argsFile, encoding: .utf8), "auth\nverify\n--agent\nslugger\n")
    }
}

private enum ProviderVerifyTestError: Error {
    case boom
}

private final class ProviderVerifyBoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.lock(); stored = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class ProviderVerifyStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ value: String) { lock.lock(); stored = value; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
}
