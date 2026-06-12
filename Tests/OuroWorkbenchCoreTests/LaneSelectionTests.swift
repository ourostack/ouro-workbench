import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class LaneSelectionTests: XCTestCase {
    private func makeSelection() -> LaneSelection {
        LaneSelection(agentName: "slugger", lane: .outward, provider: "anthropic", model: "claude")
    }

    // MARK: - Command tokens (config-only, no secret)

    func testUseTokensCarryAgentLaneProviderModelNoSecret() {
        let tokens = makeSelection().useTokens
        XCTAssertEqual(tokens, [
            "ouro", "use", "--agent", "slugger",
            "--lane", "outward", "--provider", "anthropic", "--model", "claude",
        ])
        // No credential-looking token anywhere.
        for token in tokens {
            for needle in ["key", "token", "secret", "password"] {
                XCTAssertFalse(token.lowercased().contains(needle), "selectLane tokens must carry no secret; found \(token)")
            }
        }
    }

    // MARK: - Recovery-truth classification

    func testClassifySelectedWhenProbeReadsHealthy() {
        XCTAssertEqual(LaneSelectionTruth.classify(probe: .healthy), .selected)
    }

    func testClassifyStillDegradedWhenProbeReadsDegraded() {
        XCTAssertEqual(LaneSelectionTruth.classify(probe: .degraded), .stillDegraded)
    }

    func testClassifyNeedsManualWhenProbeUnreachable() {
        XCTAssertEqual(LaneSelectionTruth.classify(probe: .unreachable), .needsManual)
    }

    func testNeedsManualRecoveryFlagOnlyOnNeedsManual() {
        XCTAssertFalse(LaneSelectionTruth.selected.needsManualRecovery)
        XCTAssertFalse(LaneSelectionTruth.stillDegraded.needsManualRecovery)
        XCTAssertTrue(LaneSelectionTruth.needsManual.needsManualRecovery)
    }

    // MARK: - Cohesive copy

    func testHumanFacingLineNeverLeaksCLISeams() {
        let selection = makeSelection()
        for truth in [LaneSelectionTruth.selected, .stillDegraded, .needsManual] {
            let line = truth.humanFacingLine(selection: selection)
            XCTAssertFalse(line.lowercased().contains("ouro"))
            XCTAssertFalse(line.contains("--lane"))
            XCTAssertFalse(line.lowercased().contains("daemon"))
        }
    }

    func testHumanFacingLineNamesTheAgentAndProvider() {
        let line = LaneSelectionTruth.selected.humanFacingLine(selection: makeSelection())
        XCTAssertTrue(line.contains("slugger"))
        XCTAssertTrue(line.contains("anthropic"))
    }

    func testAuditDetailCarriesRawVerbWithAllFields() {
        for truth in [LaneSelectionTruth.selected, .stillDegraded, .needsManual] {
            let detail = truth.auditDetail(selection: makeSelection())
            XCTAssertTrue(detail.contains("ouro use --agent slugger --lane outward --provider anthropic --model claude"),
                          "audit detail for \(truth.rawValue) must carry the full explicit verb: \(detail)")
        }
    }

    // MARK: - Runner

    func testRunnerRejectsEmptyAgentNameWithoutRunningCommand() async {
        let didRun = LaneBoolFlag()
        let runner = LaneSelectionRunner(
            runSelect: { _ in didRun.set() },
            verifyProbe: { _ in .healthy }
        )
        let selection = LaneSelection(agentName: "  ", lane: .inner, provider: "p", model: "m")
        let outcome = await runner.select(selection)
        XCTAssertFalse(didRun.value)
        XCTAssertEqual(outcome.truth, .needsManual)
        XCTAssertFalse(outcome.commandAttempted)
    }

    func testRunnerClassifiesSelectedFromProbeNotExitCode() async {
        let runner = LaneSelectionRunner(
            runSelect: { _ in throw LaneTestError.boom },
            verifyProbe: { _ in .healthy }
        )
        let outcome = await runner.select(makeSelection())
        XCTAssertTrue(outcome.commandAttempted)
        XCTAssertEqual(outcome.truth, .selected)
        XCTAssertEqual(outcome.selection.agentName, "slugger")
    }

    func testRunnerClassifiesStillDegradedWhenProbeDegraded() async {
        let runner = LaneSelectionRunner(runSelect: { _ in }, verifyProbe: { _ in .degraded })
        let outcome = await runner.select(makeSelection())
        XCTAssertEqual(outcome.truth, .stillDegraded)
    }

    func testRunnerClassifiesNeedsManualWhenProbeUnreachable() async {
        let runner = LaneSelectionRunner(runSelect: { _ in }, verifyProbe: { _ in .unreachable })
        let outcome = await runner.select(makeSelection())
        XCTAssertEqual(outcome.truth, .needsManual)
    }

    func testRunnerPassesExplicitSelectionToBothRunAndProbe() async {
        let ranWith = LaneStringBox()
        let probedWith = LaneStringBox()
        let runner = LaneSelectionRunner(
            runSelect: { s in ranWith.set("\(s.agentName)|\(s.lane.rawValue)|\(s.provider)|\(s.model)") },
            verifyProbe: { name in probedWith.set(name); return .healthy }
        )
        _ = await runner.select(makeSelection())
        XCTAssertEqual(ranWith.value, "slugger|outward|anthropic|claude")
        XCTAssertEqual(probedWith.value, "slugger")
    }

    func testOutcomeResultLineIsSeamFreeAndAuditDetailRaw() async {
        let runner = LaneSelectionRunner(runSelect: { _ in }, verifyProbe: { _ in .healthy })
        let outcome = await runner.select(makeSelection())
        XCTAssertFalse(outcome.humanFacingLine.lowercased().contains("ouro"))
        XCTAssertTrue(outcome.auditDetail.contains("ouro use --agent slugger --lane outward"))
    }
}

private enum LaneTestError: Error { case boom }

private final class LaneBoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.lock(); stored = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class LaneStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ value: String) { lock.lock(); stored = value; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
}
