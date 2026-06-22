import XCTest
@testable import OuroWorkbenchCore

/// F7 — the pure classification behind an honest headless-clone outcome. Mirrors F1's
/// `ProviderConfigForm.classifyColdStart` + F13's `VaultOnboardingMachine.afterVaultTerminal`:
/// readiness ONLY on a positive probe; everything else fails safe with a SPECIFIC reason. The
/// three lies this replaces — exit-0-is-success, missing-agent.json-still-succeeds, and a
/// watchdog-kill mis-mapped to "Check the Git remote" — are each pinned by a dedicated arm here.
final class CloneOutcomeClassifierTests: XCTestCase {

    // MARK: - CloneRunResult helpers

    func testExitedCarriesItsCodeAndIsNotATimeout() {
        let run = CloneRunResult.exited(code: 0)
        XCTAssertEqual(run.exitCode, 0)
        XCTAssertFalse(run.watchdogTimedOut)
    }

    func testExitedNonZeroCarriesItsCode() {
        let run = CloneRunResult.exited(code: 1)
        XCTAssertEqual(run.exitCode, 1)
        XCTAssertFalse(run.watchdogTimedOut)
    }

    func testTimedOutHasNoExitCodeAndReportsTimeout() {
        let run = CloneRunResult.timedOut
        XCTAssertNil(run.exitCode)
        XCTAssertTrue(run.watchdogTimedOut)
    }

    func testLaunchFailedHasNoExitCodeAndIsNotATimeout() {
        let run = CloneRunResult.launchFailed
        XCTAssertNil(run.exitCode)
        XCTAssertFalse(run.watchdogTimedOut)
    }

    // MARK: - classifyClone: launch + timeout (matched before any code==0 test)

    func testLaunchFailedClassifiesAsLaunchError() {
        let outcome = CloneOutcomeClassifier.classifyClone(
            runResult: .launchFailed,
            agentJsonPresent: false,
            checkVerdict: nil
        )
        XCTAssertEqual(outcome, .failed(reason: .cloneLaunchError))
    }

    func testTimedOutClassifiesAsTimedOut() {
        let outcome = CloneOutcomeClassifier.classifyClone(
            runResult: .timedOut,
            agentJsonPresent: true,
            checkVerdict: .working
        )
        // STRUCTURAL DEFENSE (B-1): a watchdog kill is matched on the ENUM CASE, BEFORE any
        // `code == 0` test — so it can never be confused with a clean run even if a later
        // present-bundle + .working probe would otherwise look ready.
        XCTAssertEqual(outcome, .failed(reason: .timedOut))
    }

    /// REGRESSION GUARD (gap #3): a 120s watchdog kill must NEVER be classified as the
    /// non-zero-exit ("Check the Git remote") case. These are distinct reasons with distinct copy.
    func testTimedOutIsNotTheNonZeroExitReason() {
        let timedOut = CloneOutcomeClassifier.classifyClone(
            runResult: .timedOut,
            agentJsonPresent: false,
            checkVerdict: nil
        )
        let nonZero = CloneOutcomeClassifier.classifyClone(
            runResult: .exited(code: 1),
            agentJsonPresent: false,
            checkVerdict: nil
        )
        XCTAssertEqual(timedOut, .failed(reason: .timedOut))
        XCTAssertEqual(nonZero, .failed(reason: .cloneNonZeroExit))
        XCTAssertNotEqual(timedOut, nonZero)
    }

    // MARK: - classifyClone: non-zero exit (gap #3 cause — the ONLY "Git remote" copy)

    func testNonZeroExitClassifiesAsCloneNonZeroExit() {
        let outcome = CloneOutcomeClassifier.classifyClone(
            runResult: .exited(code: 128),
            agentJsonPresent: true,
            checkVerdict: .working
        )
        // A non-zero exit is untrustworthy regardless of any later bundle/probe state.
        XCTAssertEqual(outcome, .failed(reason: .cloneNonZeroExit))
    }

    // MARK: - classifyClone: exit-0 + missing agent.json (gap #2)

    func testExitZeroWithMissingAgentJsonIsInvalidEvenWithWorkingProbe() {
        // The original gap #2: a clean clone that produced no bundle still "succeeded". The
        // SAFETY INVARIANT requires agentJsonPresent — so even a .working probe can't rescue it.
        let outcome = CloneOutcomeClassifier.classifyClone(
            runResult: .exited(code: 0),
            agentJsonPresent: false,
            checkVerdict: .working
        )
        XCTAssertEqual(outcome, .failed(reason: .invalidMissingAgentJson))
    }

    // MARK: - classifyClone: exit-0 + present + probe (gap #1 — the readiness invariant)

    func testExitZeroPresentAndWorkingIsTheOnlyReadyArm() {
        let outcome = CloneOutcomeClassifier.classifyClone(
            runResult: .exited(code: 0),
            agentJsonPresent: true,
            checkVerdict: .working
        )
        XCTAssertEqual(outcome, .ready)
    }

    func testExitZeroPresentAndVaultLockedNeedsVaultUnlock() {
        let outcome = CloneOutcomeClassifier.classifyClone(
            runResult: .exited(code: 0),
            agentJsonPresent: true,
            checkVerdict: .vaultLocked
        )
        XCTAssertEqual(outcome, .needsVaultUnlock)
    }

    func testExitZeroPresentAndUnauthorizedNeedsVaultUnlock() {
        let outcome = CloneOutcomeClassifier.classifyClone(
            runResult: .exited(code: 0),
            agentJsonPresent: true,
            checkVerdict: .unauthorized
        )
        XCTAssertEqual(outcome, .needsVaultUnlock)
    }

    /// B-3 — readiness leak on a clean-but-unauthenticated clone (the ORIGINAL bug). A clean exit
    /// with a present bundle is NEVER ready unless the probe positively says `.working`. Every
    /// non-`.working` verdict (and a nil/timed-out probe) must fall short of `.ready`.
    func testExitZeroPresentButNonWorkingProbeIsNeverReady() {
        let verdicts: [ProviderConnectionVerdict?] = [
            .vaultLocked, .unauthorized, .unreachable, .indeterminate, nil,
        ]
        for verdict in verdicts {
            let outcome = CloneOutcomeClassifier.classifyClone(
                runResult: .exited(code: 0),
                agentJsonPresent: true,
                checkVerdict: verdict
            )
            XCTAssertNotEqual(outcome, .ready, "exit-0 + present + \(String(describing: verdict)) must NOT be .ready")
        }
    }

    func testExitZeroPresentAndUnreachableCouldNotConfirm() {
        let outcome = CloneOutcomeClassifier.classifyClone(
            runResult: .exited(code: 0),
            agentJsonPresent: true,
            checkVerdict: .unreachable
        )
        XCTAssertEqual(outcome, .failed(reason: .couldNotConfirm))
    }

    func testExitZeroPresentAndIndeterminateCouldNotConfirm() {
        let outcome = CloneOutcomeClassifier.classifyClone(
            runResult: .exited(code: 0),
            agentJsonPresent: true,
            checkVerdict: .indeterminate
        )
        XCTAssertEqual(outcome, .failed(reason: .couldNotConfirm))
    }

    func testExitZeroPresentAndNilProbeCouldNotConfirm() {
        let outcome = CloneOutcomeClassifier.classifyClone(
            runResult: .exited(code: 0),
            agentJsonPresent: true,
            checkVerdict: nil
        )
        XCTAssertEqual(outcome, .failed(reason: .couldNotConfirm))
    }

    // MARK: - auditReason (stable, non-human tokens for the action log)

    func testAuditReasonForEveryOutcome() {
        XCTAssertEqual(CloneOutcome.ready.auditReason, "ready")
        XCTAssertEqual(CloneOutcome.needsVaultUnlock.auditReason, "needsVaultUnlock")
        XCTAssertEqual(CloneOutcome.failed(reason: .cloneLaunchError).auditReason, "cloneLaunchError")
        XCTAssertEqual(CloneOutcome.failed(reason: .cloneNonZeroExit).auditReason, "cloneNonZeroExit")
        XCTAssertEqual(CloneOutcome.failed(reason: .timedOut).auditReason, "timedOut")
        XCTAssertEqual(CloneOutcome.failed(reason: .invalidMissingAgentJson).auditReason, "invalidMissingAgentJson")
        XCTAssertEqual(CloneOutcome.failed(reason: .couldNotConfirm).auditReason, "couldNotConfirm")
    }

    // MARK: - humanFacingLine (seam-free; only .cloneNonZeroExit keeps "Git remote")

    func testReadyHumanLineNamesTheAgentAndIsClean() {
        let line = CloneOutcome.ready.humanFacingLine(agentName: "sprout")
        XCTAssertTrue(line.contains("sprout"))
        assertSeamFree(line)
    }

    func testNeedsVaultUnlockHumanLineNamesTheAgentAndIsClean() {
        let line = CloneOutcome.needsVaultUnlock.humanFacingLine(agentName: "sprout")
        XCTAssertTrue(line.contains("sprout"))
        assertSeamFree(line)
    }

    /// The ONLY "Git remote" copy is `.cloneNonZeroExit` — that's the one cause where the remote is
    /// the likely culprit. The timed-out and missing-agent.json lines must NOT blame the remote.
    func testOnlyCloneNonZeroExitMentionsTheGitRemote() {
        let nonZero = CloneOutcome.failed(reason: .cloneNonZeroExit).humanFacingLine(agentName: "sprout")
        XCTAssertTrue(nonZero.contains("Git remote"), "the non-zero-exit line should point at the remote")
        assertSeamFree(nonZero)

        for reason in [CloneFailureReason.cloneLaunchError, .timedOut, .invalidMissingAgentJson, .couldNotConfirm] {
            let line = CloneOutcome.failed(reason: reason).humanFacingLine(agentName: "sprout")
            XCTAssertFalse(
                line.contains("Git remote"),
                "\(reason.rawValue) must NOT blame the Git remote (wrong cause)"
            )
        }
    }

    /// gap #3 — the timed-out line gets its OWN honest copy: the clone took too long and was
    /// stopped (network / remote size), NOT "Check the Git remote".
    func testTimedOutHumanLineIsAboutTakingTooLongNotTheRemote() {
        let line = CloneOutcome.failed(reason: .timedOut).humanFacingLine(agentName: "sprout")
        let lowered = line.lowercased()
        XCTAssertTrue(lowered.contains("too long") || lowered.contains("stopped"))
        XCTAssertFalse(line.contains("Git remote"))
        assertSeamFree(line)
    }

    func testEveryFailureLineNamesTheAgentAndIsSeamFree() {
        for reason in [
            CloneFailureReason.cloneLaunchError, .cloneNonZeroExit, .timedOut,
            .invalidMissingAgentJson, .couldNotConfirm,
        ] {
            let line = CloneOutcome.failed(reason: reason).humanFacingLine(agentName: "recipe-bot")
            XCTAssertTrue(line.contains("recipe-bot"), "\(reason.rawValue) line should name the agent")
            assertSeamFree(line)
        }
    }

    // MARK: - CloneBundleLocator (pure path convention)

    func testAgentJsonPathFollowsTheBundleConvention() {
        let root = URL(fileURLWithPath: "/Users/x/AgentBundles", isDirectory: true)
        let path = CloneBundleLocator.agentJsonPath(agentName: "sprout", agentBundlesRoot: root)
        XCTAssertEqual(path, "/Users/x/AgentBundles/sprout.ouro/agent.json")
    }

    func testAgentJsonPathTrimsWhitespaceAroundTheName() {
        let root = URL(fileURLWithPath: "/Users/x/AgentBundles", isDirectory: true)
        let path = CloneBundleLocator.agentJsonPath(agentName: "  sprout  ", agentBundlesRoot: root)
        XCTAssertEqual(path, "/Users/x/AgentBundles/sprout.ouro/agent.json")
    }

    // MARK: - Helpers

    /// The human surface must never leak `ouro`/`vault`/`clone` CLI verbs or raw argv flags.
    /// ("Clone" as a plain English noun is fine; the raw verb `ouro clone` and flags are not.)
    private func assertSeamFree(_ line: String, file: StaticString = #filePath, line lineNumber: UInt = #line) {
        let lowered = line.lowercased()
        XCTAssertFalse(lowered.contains("ouro"), "leaked `ouro`: \(line)", file: file, line: lineNumber)
        XCTAssertFalse(lowered.contains("vault"), "leaked `vault`: \(line)", file: file, line: lineNumber)
        XCTAssertFalse(line.contains("--"), "leaked an argv flag: \(line)", file: file, line: lineNumber)
        XCTAssertFalse(lowered.contains("argv"), "leaked `argv`: \(line)", file: file, line: lineNumber)
    }
}
