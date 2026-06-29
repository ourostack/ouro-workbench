import XCTest
@testable import OuroWorkbenchCore

/// F1 — durable wiring assertions for the cold-start honest-failure fix. The App target isn't
/// coverage-gated and can't be click-tested in CI, so we pin the structural wiring the same way
/// `ProviderCheckClassifierWiringTests` does for F2: the `.coldStartHatch` submit branch must no
/// longer report success synchronously, must classify the outcome from the hatch exit + a probe,
/// and must gate the success side-effects behind the `.ready` branch only.
final class ColdStartHonestWiringTests: XCTestCase {
    /// The synchronous span of the `.coldStartHatch` case: everything BEFORE the detached `Task`.
    /// The bug was that dismiss + success-log happened here, before the hatch even ran.
    private func coldStartSynchronousPrefix(in body: String) throws -> String {
        let taskStart = try XCTUnwrap(
            body.range(of: "Task {")?.lowerBound,
            "expected a detached Task in the .coldStartHatch branch"
        )
        return String(body[body.startIndex..<taskStart])
    }

    private func coldStartBranch() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "case let .coldStartHatch(plan):",
            to: "/// Open the native provider-config form in response to a non-secret-bearing"
        )
    }

    func testColdStartDoesNotDismissOrLogSuccessSynchronously() throws {
        let body = try coldStartBranch()
        let prefix = try coldStartSynchronousPrefix(in: body)

        // The dismiss must NOT happen in the synchronous pre-Task span (that was the lie: the form
        // closed reporting success before the hatch ran).
        XCTAssertFalse(
            prefix.contains("isProviderConfigPresented = false"),
            "the form must not dismiss synchronously before the hatch outcome is known"
        )
    }

    func testColdStartClassifiesTheOutcome() throws {
        let body = try coldStartBranch()
        XCTAssertTrue(
            body.contains("classifyColdStart"),
            "the .coldStartHatch branch must classify the outcome via ProviderConfigForm.classifyColdStart"
        )
    }

    func testColdStartNoLongerSwallowsTheRunnerResult() throws {
        let body = try coldStartBranch()
        // The `try?` that swallowed the runner outcome is gone — runHeadless now returns a result
        // that gets read, not discarded.
        XCTAssertFalse(
            body.contains("try? await ColdStartHatchRunner.runHeadless"),
            "the runner result must no longer be swallowed with try? — F1 reads the exit"
        )
        XCTAssertTrue(
            body.contains("await self?.runColdStartHatch(plan)"),
            "the cold-start branch must still await the runner result through the injectable seam"
        )
        XCTAssertFalse(
            body.contains("ColdStartHatchRunner.runHeadless(plan: plan)"),
            "the cold-start branch must not call the live runner directly; tests inject the seam"
        )
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("var runColdStartHatch") && source.contains("await ColdStartHatchRunner.runHeadless(plan: plan)"),
            "the injectable hatch seam must default to the production runner"
        )
    }

    func testColdStartOnlyRunsLiveProviderProbeAfterCleanHatchExit() throws {
        let body = try coldStartBranch()
        XCTAssertTrue(
            body.contains("if exit == 0"),
            "the branch must only run the live post-hatch provider probe after a clean hatch exit"
        )

        let probeCallCount = body.components(separatedBy: "runColdStartProviderCheck(agentName: resolvedAgent, lane: \"outward\")").count - 1
        XCTAssertEqual(
            probeCallCount,
            1,
            "the cold-start branch should have one live provider probe call, inside the clean-exit guard"
        )

        let guardSlice = try WorkbenchAppSource.sourceSlice(
            in: body,
            from: "if exit == 0 {",
            to: "let outcome = ProviderConfigForm.classifyColdStart"
        )
        XCTAssertTrue(
            guardSlice.contains("runColdStartProviderCheck(agentName: resolvedAgent, lane: \"outward\")"),
            "the provider probe must sit inside the clean-exit guard"
        )
        XCTAssertTrue(
            guardSlice.contains("verdict = nil"),
            "failed or unlaunched hatches must classify without attempting a live provider check"
        )
    }

    func testSuccessActionLogIsGatedBehindTheReadyBranch() throws {
        let body = try coldStartBranch()
        // There must be NO `succeeded: true` in the synchronous prefix...
        let prefix = try coldStartSynchronousPrefix(in: body)
        XCTAssertFalse(
            prefix.contains("succeeded: true"),
            "success must not be logged synchronously before the outcome is known"
        )
        // ...and the only `succeeded: true` literal in the whole branch must sit after a `.ready`
        // arm (the success side-effects are gated behind the ready outcome).
        guard let readyRange = body.range(of: "case .ready:") else {
            return XCTFail("the outcome switch must have an explicit .ready arm")
        }
        let afterReady = String(body[readyRange.lowerBound...])
        let beforeReady = String(body[body.startIndex..<readyRange.lowerBound])
        XCTAssertFalse(
            beforeReady.contains("succeeded: true"),
            "no success may be logged before the .ready branch"
        )
        XCTAssertTrue(
            afterReady.contains("succeeded: true"),
            "the success action log must live in/after the .ready branch"
        )
    }

    func testColdStartSurfacesTheHumanFacingLineForNonReadyOutcomes() throws {
        let body = try coldStartBranch()
        XCTAssertTrue(
            body.contains("humanFacingLine"),
            "non-ready outcomes must surface the seam-free humanFacingLine to the user"
        )
        // A non-ready outcome must still refresh inventory/readiness so the dead bundle surfaces as
        // needs-credentials rather than ready.
        XCTAssertTrue(
            body.contains("refreshOnboardingReadiness()"),
            "the branch must refresh onboarding readiness so a non-ready bundle surfaces honestly"
        )
    }

    func testColdStartProbeRunsAShortBudgetCheck() throws {
        // The post-hatch probe lives in a dedicated short-budget method. Pin that it exists and is
        // wired into the cold-start branch, and that it classifies via the F2 classifier.
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("func runColdStartProviderCheck"),
            "a dedicated short-budget cold-start probe method must exist"
        )
        let probe = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "private func runColdStartProviderCheck",
            to: "\n    private func "
        )
        XCTAssertTrue(
            probe.contains("ProviderCheckClassifier"),
            "the cold-start probe must classify via ProviderCheckClassifier (F2 seam)"
        )
        // Short budget: a flaky-daemon hang must degrade fast, not freeze creation for 90s.
        XCTAssertTrue(
            probe.contains("timeout") || probe.contains("Deadline") || probe.contains("15"),
            "the cold-start probe must use a short watchdog budget"
        )
    }

    // MARK: - Helpers (mirror ProviderCheckClassifierWiringTests)
}
