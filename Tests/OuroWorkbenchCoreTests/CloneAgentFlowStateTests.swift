import XCTest
@testable import OuroWorkbenchCore

/// U35 — the pure state model behind the native clone flow's inline progress. Replaces
/// the raw `ouro clone` command pane: the sheet drives this state and renders progress /
/// success / failure inline, never spawning a terminal the operator must converse with.
final class CloneAgentFlowStateTests: XCTestCase {
    func testIdleIsTheStartingStateAndAllowsStart() {
        let state = CloneAgentFlowState.idle
        XCTAssertTrue(state.canStart)
        XCTAssertFalse(state.isBusy)
        XCTAssertNil(state.inlineMessage)
    }

    func testCloningIsBusyAndBlocksReentry() {
        // While a clone is in flight the sheet shows progress and the action can't
        // re-fire — exactly the inline-progress posture the raw pane never had.
        let state = CloneAgentFlowState.cloning(remoteLabel: "sprout.ouro")
        XCTAssertFalse(state.canStart)
        XCTAssertTrue(state.isBusy)
        XCTAssertEqual(state.inlineMessage, "Cloning sprout.ouro…")
    }

    func testSucceededReportsInlineAndDoesNotAllowRestart() {
        let state = CloneAgentFlowState.succeeded(agentName: "sprout")
        XCTAssertFalse(state.canStart)
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.inlineMessage, "Cloned sprout.")
    }

    func testSucceededWithoutAResolvedNameStillReadsCleanly() {
        let state = CloneAgentFlowState.succeeded(agentName: nil)
        XCTAssertEqual(state.inlineMessage, "Clone complete.")
        XCTAssertFalse(state.isBusy)
    }

    func testFailedSurfacesTheReasonInlineAndAllowsRetry() {
        // A failure reports inline (not in a CLI pane) and re-enables the action so the
        // operator can fix the remote and try again.
        let state = CloneAgentFlowState.failed(reason: "Couldn't reach the remote.")
        XCTAssertTrue(state.canStart)
        XCTAssertFalse(state.isBusy)
        XCTAssertEqual(state.inlineMessage, "Couldn't reach the remote.")
    }

    func testFailedIsTreatedAsAnErrorWhileSucceededIsNot() {
        XCTAssertTrue(CloneAgentFlowState.failed(reason: "x").isError)
        XCTAssertFalse(CloneAgentFlowState.succeeded(agentName: "a").isError)
        XCTAssertFalse(CloneAgentFlowState.cloning(remoteLabel: "r").isError)
        XCTAssertFalse(CloneAgentFlowState.idle.isError)
    }

    // The progress label shows a short, human-readable remote — the trailing path
    // component without the `.ouro`/`.git` suffixes — not the full URL.
    func testRemoteLabelDerivesAFriendlyShortName() {
        XCTAssertEqual(
            CloneAgentFlowState.remoteLabel(forRemote: "https://github.com/ourostack/sprout.ouro.git"),
            "sprout"
        )
        XCTAssertEqual(
            CloneAgentFlowState.remoteLabel(forRemote: "git@github.com:ourostack/recipe-bot.ouro"),
            "recipe-bot"
        )
        XCTAssertEqual(
            CloneAgentFlowState.remoteLabel(forRemote: "https://example.com/team/widget.git"),
            "widget"
        )
    }

    func testRemoteLabelFallsBackToTheTrimmedRemoteWhenNoPathComponent() {
        XCTAssertEqual(CloneAgentFlowState.remoteLabel(forRemote: "  sprout  "), "sprout")
        XCTAssertEqual(CloneAgentFlowState.remoteLabel(forRemote: ""), "the remote")
        XCTAssertEqual(CloneAgentFlowState.remoteLabel(forRemote: "   "), "the remote")
    }

    func testFailureReasonIsSeamFreeAndNeverLeaksRawArgv() {
        // Whatever the runner throws, the operator sees a calm seam-free line — no
        // `ouro clone …` argv, no `--agent` flag, no shell jargon. ("Clone" as plain
        // English is fine; the raw verb `ouro clone` and flags are what must not leak.)
        let reason = CloneAgentFlowState.failureReason(forRemoteLabel: "sprout")
        XCTAssertEqual(reason, "Couldn't clone sprout. Check the Git remote and try again.")
        XCTAssertFalse(reason.contains("ouro"))
        XCTAssertFalse(reason.contains("--agent"))
    }

    func testRemoteLabelOfPureSeparatorsFallsBackToTheTrimmedRemote() {
        // A remote that's only separators ("/") has no path component — fall back to the
        // trimmed remote rather than crashing or returning empty.
        XCTAssertEqual(CloneAgentFlowState.remoteLabel(forRemote: "/"), "/")
        XCTAssertEqual(CloneAgentFlowState.remoteLabel(forRemote: ":"), ":")
    }

    func testRemoteLabelOfBareSuffixFallsBackWhenStrippingEmptiesIt() {
        // ".git" / ".ouro" strip down to an empty name — fall back to the trimmed remote.
        XCTAssertEqual(CloneAgentFlowState.remoteLabel(forRemote: ".git"), ".git")
        XCTAssertEqual(CloneAgentFlowState.remoteLabel(forRemote: ".ouro"), ".ouro")
    }

    func testRunnerExecutesAFiniteHeadlessCloneCommandAndReportsCleanExit() async {
        // F7 — the runner no longer throws; it REPORTS the outcome. A finite command that exits 0
        // returns `.exited(code: 0)` (no pane spawned). Mirrors ColdStartHatchRunner's coverage.
        let result = await CloneAgentRunner.runHeadless(
            plan: OuroAgentInstallPlan(sessionName: "t", commandLine: "true", notes: "", tokens: ["true"])
        )
        XCTAssertEqual(result, .exited(code: 0))
    }

    func testRunnerReportsExitedWithTheCodeOnNonZeroExit() async {
        // F7 — a non-zero clone returns `.exited(code:)` (NOT a throw, NOT a timeout). The
        // classifier maps that to `.cloneNonZeroExit`. `false` exits 1.
        let result = await CloneAgentRunner.runHeadless(
            plan: OuroAgentInstallPlan(sessionName: "t", commandLine: "false", notes: "", tokens: ["false"])
        )
        XCTAssertEqual(result, .exited(code: 1))
    }

    func testRunnerReportsLaunchFailedWhenTheBinaryCannotStart() async {
        // F7 — when the process can't even launch, the runner returns `.launchFailed` (distinct
        // from a non-zero exit: nothing was cloned). Point at a non-existent binary to exercise it.
        let result = await CloneAgentRunner.runHeadless(
            plan: OuroAgentInstallPlan(sessionName: "t", commandLine: "x", notes: "", tokens: ["x"]),
            executableURL: URL(fileURLWithPath: "/nonexistent/definitely-not-a-binary")
        )
        XCTAssertEqual(result, .launchFailed)
    }

    func testRunnerReportsTimedOutWhenAWedgedCloneExceedsTheBudget() async throws {
        // B-1 — the LOAD-BEARING regression: a 120s watchdog kill must surface as `.timedOut`, NOT
        // as a non-zero `.exited` that the classifier would mis-map to "Check the Git remote". A
        // watchdog kill and a real git failure BOTH exit non-zero, so the only honest way to tell
        // them apart is the runner reading `waitUntilExitReportingTimeout` BEFORE `terminationStatus`.
        // Drive it with a REAL sleeper past a short injected budget (the classifier alone can't prove
        // the runner actually returns `.timedOut` on a wedge — that's tested HERE, end-to-end).
        let result = await CloneAgentRunner.runHeadless(
            plan: OuroAgentInstallPlan(sessionName: "t", commandLine: "sleep 30", notes: "", tokens: ["sleep", "30"]),
            timeoutSeconds: 0.3
        )
        XCTAssertEqual(result, .timedOut)
        // And classifying that result must NOT be the non-zero-exit ("Git remote") reason.
        let outcome = CloneOutcomeClassifier.classifyClone(
            runResult: result,
            agentJsonPresent: false,
            checkVerdict: nil
        )
        XCTAssertEqual(outcome, .failed(reason: .timedOut))
        XCTAssertNotEqual(outcome, .failed(reason: .cloneNonZeroExit))
    }
}
