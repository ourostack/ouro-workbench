import XCTest
@testable import OuroWorkbenchCore

/// Durable wiring assertions for the F2 false-green Connect fix. The App target isn't
/// coverage-gated and can't be click-tested in CI, so we pin the structural wiring instead
/// (mirrors `BossForwardStatusWiringTests`): the onboarding provider check and the
/// onboarding-doctor diagnostic must both classify the Connect result from the OUTPUT via
/// `ProviderCheckClassifier`, NEVER from the process exit code — and ONLY `.working` maps to a
/// passed/ok readiness.
final class ProviderCheckClassifierWiringTests: XCTestCase {
    // MARK: - runOnboardingProviderCheck (OuroWorkbenchApp.swift)

    func testOnboardingProviderCheckClassifiesFromOutputNotExitCode() throws {
        let source = try WorkbenchAppSource.appSource()
        let body = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "private func runOnboardingProviderCheck(agentName: String, lane: String) async",
            to: "func scanForOnboardingSessions()"
        )

        // The verdict comes from the classifier, fed the captured output.
        XCTAssertTrue(
            body.contains("ProviderCheckClassifier()"),
            "runOnboardingProviderCheck must classify via ProviderCheckClassifier"
        )
        // The output is captured by the bounded runner and passed to the classifier.
        XCTAssertFalse(
            body.contains("readDataToEndOfFile()"),
            "provider checks must not block on readDataToEndOfFile before observing the timeout"
        )
        XCTAssertTrue(
            body.contains("Self.runProviderCheckProcess("),
            "runOnboardingProviderCheck must use the bounded provider-check process runner"
        )
        XCTAssertTrue(
            body.contains("stdout: result.output"),
            "the bounded runner's captured output must be handed to the classifier"
        )
        XCTAssertTrue(
            body.contains(".classify("),
            "the captured output must be handed to the classifier's classify(...)"
        )
        // The readiness must NOT be derived from the exit code.
        XCTAssertFalse(
            body.contains("process.terminationStatus == 0"),
            "readiness must not be derived from terminationStatus — that is the F2 bug"
        )
    }

    func testOnlyWorkingVerdictMapsToPassed() throws {
        let source = try WorkbenchAppSource.appSource()
        let body = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "private func runOnboardingProviderCheck(agentName: String, lane: String) async",
            to: "func scanForOnboardingSessions()"
        )

        // Exactly one `.passed` mapping, gated on `.working`.
        XCTAssertTrue(
            body.contains("case .working:"),
            "the verdict switch must have an explicit .working arm"
        )
        let passedOccurrences = body.components(separatedBy: "state: .passed").count - 1
        XCTAssertEqual(
            passedOccurrences, 1,
            "exactly one result may be .passed — only the .working verdict"
        )
        // Every non-working verdict has a distinct, seam-free failed detail.
        for verdict in ["vaultLocked", "unauthorized", "unreachable", "indeterminate"] {
            XCTAssertTrue(
                body.contains("case .\(verdict):"),
                "the verdict switch must handle .\(verdict) explicitly"
            )
        }
    }

    func testNonWorkingFailureCopyIsSeamFree() throws {
        let source = try WorkbenchAppSource.appSource()
        let body = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "private func runOnboardingProviderCheck(agentName: String, lane: String) async",
            to: "func scanForOnboardingSessions()"
        )

        // Pull only the verdict-switch detail strings (the user-facing failure copy) and assert
        // they never leak a CLI seam. The audit comments in the function legitimately mention
        // `ouro`, so we scope the seam check to the `detail:` string literals.
        let detailLines = body
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains("detail:") && $0.contains("\"") }
        XCTAssertFalse(detailLines.isEmpty, "expected detail copy lines in the function body")
        for line in detailLines {
            let lowered = line.lowercased()
            XCTAssertFalse(lowered.contains("ouro"), "failure copy leaked an ouro seam: \(line)")
            XCTAssertFalse(lowered.contains("--lane"), "failure copy leaked a lane flag seam: \(line)")
            XCTAssertFalse(lowered.contains("--agent"), "failure copy leaked an agent flag seam: \(line)")
        }
    }

    func testProviderCheckProcessRunnerBoundsPipeAndProcessLifetime() throws {
        let source = try WorkbenchAppSource.appSource()
        let body = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "private static func runProviderCheckProcess(",
            to: "/// F7"
        )

        XCTAssertTrue(
            body.contains("readabilityHandler"),
            "provider-check output must be drained asynchronously so the pipe cannot block timeout handling"
        )
        XCTAssertTrue(
            body.contains("XCTestConfigurationFilePath"),
            "ordinary unit tests must not run live provider checks against the operator's real Ouro agent state"
        )
        XCTAssertTrue(
            body.contains("NSClassFromString(\"XCTest"),
            "the unit-test guard must detect SwiftPM XCTest even when the environment key is absent"
        )
        XCTAssertTrue(
            body.contains("OURO_WORKBENCH_LIVE_PROVIDER_CHECKS"),
            "live provider-check tests must require an explicit opt-in environment variable"
        )
        XCTAssertTrue(
            body.contains("terminationHandler"),
            "the runner must observe process exit without blocking on pipe EOF"
        )
        XCTAssertTrue(
            body.contains("outputEOF.wait(timeout: .now() + 1)"),
            "the runner must wait briefly for pipe EOF after process exit so fast final output is not dropped"
        )
        XCTAssertTrue(
            body.contains("exitSemaphore.wait(timeout: .now() + timeoutSeconds)"),
            "the runner must enforce the configured provider-check timeout"
        )
        XCTAssertTrue(
            body.contains("process.terminate()"),
            "the runner must terminate a provider check that exceeds its budget"
        )
        XCTAssertTrue(
            body.contains("kill(process.processIdentifier, SIGKILL)"),
            "the runner must force-kill a provider check that ignores terminate()"
        )
        XCTAssertFalse(
            body.contains("readDataToEndOfFile()"),
            "the bounded runner must not wait for pipe EOF before enforcing the process timeout"
        )
    }

    // MARK: - onboarding-doctor diagnostic (main.swift)

    func testOnboardingDoctorDiagnosticClassifiesFromOutput() throws {
        let source = try mainSource()

        // The doctor diagnostic loop must classify via the same seam, not `exit == 0`.
        XCTAssertTrue(
            source.contains("ProviderCheckClassifier().classify("),
            "the onboarding-doctor diagnostic must classify the check via ProviderCheckClassifier"
        )
        XCTAssertTrue(
            source.contains("verdict == .working"),
            "ok must be derived from the .working verdict"
        )
        XCTAssertFalse(
            source.contains("let ok = exit == 0"),
            "the onboarding-doctor diagnostic must not derive ok from the exit code — that is the F2 bug"
        )
    }

    // MARK: - Helpers (mirror BossForwardStatusWiringTests)

    private func mainSource() throws -> String {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("main.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
