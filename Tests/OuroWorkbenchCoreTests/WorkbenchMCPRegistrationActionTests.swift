import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchMCPRegistrationActionTests: XCTestCase {
    // MARK: - Recovery-truth classification (from the POST-command registrar snapshot, never the exit/throw)

    func testClassifyRegisteredWhenSnapshotRegistered() {
        XCTAssertEqual(WorkbenchMCPRegistrationTruth.classify(status: .registered), .registered)
    }

    func testClassifyStillUnregisteredWhenSnapshotActionable() {
        XCTAssertEqual(WorkbenchMCPRegistrationTruth.classify(status: .notRegistered), .stillUnregistered)
        XCTAssertEqual(WorkbenchMCPRegistrationTruth.classify(status: .needsUpdate), .stillUnregistered)
    }

    func testClassifyNeedsManualWhenSnapshotUnrecoverable() {
        XCTAssertEqual(WorkbenchMCPRegistrationTruth.classify(status: .agentMissing), .needsManual)
        XCTAssertEqual(WorkbenchMCPRegistrationTruth.classify(status: .executableMissing), .needsManual)
        XCTAssertEqual(WorkbenchMCPRegistrationTruth.classify(status: .invalidConfig), .needsManual)
    }

    func testNeedsManualRecoveryFlagOnlyOnNeedsManual() {
        XCTAssertFalse(WorkbenchMCPRegistrationTruth.registered.needsManualRecovery)
        XCTAssertFalse(WorkbenchMCPRegistrationTruth.stillUnregistered.needsManualRecovery)
        XCTAssertTrue(WorkbenchMCPRegistrationTruth.needsManual.needsManualRecovery)
    }

    // MARK: - Cohesive copy

    func testHumanFacingLineNeverLeaksCLISeams() {
        for truth in [WorkbenchMCPRegistrationTruth.registered, .stillUnregistered, .needsManual] {
            let line = truth.humanFacingLine(agentName: "slugger")
            XCTAssertFalse(line.lowercased().contains("ouro"))
            XCTAssertFalse(line.lowercased().contains("mcp"))
            XCTAssertFalse(line.lowercased().contains("daemon"))
        }
    }

    func testHumanFacingLineNamesTheAgent() {
        XCTAssertTrue(WorkbenchMCPRegistrationTruth.registered.humanFacingLine(agentName: "slugger").contains("slugger"))
    }

    func testAuditDetailCarriesRegistrarLanguageAndAgent() {
        for truth in [WorkbenchMCPRegistrationTruth.registered, .stillUnregistered, .needsManual] {
            let detail = truth.auditDetail(agentName: "slugger")
            XCTAssertTrue(detail.contains("slugger"))
            XCTAssertTrue(detail.lowercased().contains("workbench mcp"))
        }
        XCTAssertNotEqual(
            WorkbenchMCPRegistrationTruth.registered.auditDetail(agentName: "slugger"),
            WorkbenchMCPRegistrationTruth.stillUnregistered.auditDetail(agentName: "slugger")
        )
    }

    // MARK: - Runner

    func testRunnerRejectsEmptyAgentNameWithoutRunningCommand() async {
        let didRun = RegBoolFlag()
        let runner = WorkbenchMCPRegistrationRunner(
            runRegister: { _ in didRun.set() },
            snapshotProbe: { _ in .registered }
        )
        let outcome = await runner.register(agentName: " ")
        XCTAssertFalse(didRun.value)
        XCTAssertEqual(outcome.truth, .needsManual)
        XCTAssertFalse(outcome.commandAttempted)
    }

    func testRunnerClassifiesRegisteredFromSnapshotNotThrow() async {
        // The register closure throws, but the post-command snapshot reads registered:
        // recovery truth comes from the SNAPSHOT, not the throw.
        let runner = WorkbenchMCPRegistrationRunner(
            runRegister: { _ in throw RegTestError.boom },
            snapshotProbe: { _ in .registered }
        )
        let outcome = await runner.register(agentName: "slugger")
        XCTAssertTrue(outcome.commandAttempted)
        XCTAssertEqual(outcome.truth, .registered)
        XCTAssertEqual(outcome.agentName, "slugger")
    }

    func testRunnerClassifiesStillUnregisteredWhenSnapshotActionable() async {
        let runner = WorkbenchMCPRegistrationRunner(runRegister: { _ in }, snapshotProbe: { _ in .notRegistered })
        let outcome = await runner.register(agentName: "slugger")
        XCTAssertEqual(outcome.truth, .stillUnregistered)
    }

    func testRunnerClassifiesNeedsManualWhenSnapshotUnrecoverable() async {
        let runner = WorkbenchMCPRegistrationRunner(runRegister: { _ in }, snapshotProbe: { _ in .agentMissing })
        let outcome = await runner.register(agentName: "slugger")
        XCTAssertEqual(outcome.truth, .needsManual)
    }

    func testRunnerPassesExplicitAgentNameToBothRunAndSnapshot() async {
        let ranWith = RegStringBox()
        let probedWith = RegStringBox()
        let runner = WorkbenchMCPRegistrationRunner(
            runRegister: { name in ranWith.set(name) },
            snapshotProbe: { name in probedWith.set(name); return .registered }
        )
        _ = await runner.register(agentName: "slugger")
        XCTAssertEqual(ranWith.value, "slugger")
        XCTAssertEqual(probedWith.value, "slugger")
    }

    func testOutcomeResultLineIsSeamFreeAndAuditDetailNamesAgent() async {
        let runner = WorkbenchMCPRegistrationRunner(runRegister: { _ in }, snapshotProbe: { _ in .registered })
        let outcome = await runner.register(agentName: "slugger")
        XCTAssertFalse(outcome.humanFacingLine.lowercased().contains("ouro"))
        XCTAssertTrue(outcome.auditDetail.contains("slugger"))
    }
}

private enum RegTestError: Error { case boom }

private final class RegBoolFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false
    func set() { lock.lock(); stored = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class RegStringBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: String?
    func set(_ value: String) { lock.lock(); stored = value; lock.unlock() }
    var value: String? { lock.lock(); defer { lock.unlock() }; return stored }
}
