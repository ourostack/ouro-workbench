import XCTest
@testable import OuroWorkbenchCore

/// F7 — durable wiring assertions for the honest headless-clone fix. The App target isn't
/// coverage-gated and can't be click-tested in CI, so we pin the structural wiring the same way
/// `ColdStartHonestWiringTests` does for F1: `cloneAgentHeadless` must fold the run + an agent.json
/// check + a probe through `CloneOutcomeClassifier.classifyClone`, gate the `succeeded: true` log
/// behind the `.ready` arm ONLY, route `.needsVaultUnlock` through F6's `beginCredentialRotation`
/// (no new clone-specific vault command), and never blame the Git remote in the generic
/// sync-failure fold.
final class CloneHonestWiringTests: XCTestCase {

    private func cloneBranch() throws -> String {
        let source = try appSource()
        return try sourceSlice(
            in: source,
            from: "func cloneAgentHeadless(remote: String, agentName: String) async -> CloneAgentFlowState {",
            to: "\n    func selectBoss(agentName: String) {"
        )
    }

    // MARK: - Classify the outcome through the pure seam

    func testCloneClassifiesTheOutcomeViaTheSeam() throws {
        let body = try cloneBranch()
        XCTAssertTrue(
            body.contains("CloneOutcomeClassifier.classifyClone"),
            "cloneAgentHeadless must classify the outcome via CloneOutcomeClassifier.classifyClone"
        )
    }

    func testCloneChecksForAgentJsonPresence() throws {
        let body = try cloneBranch()
        // gap #2 — the clean-exit arm must consult the bundle's agent.json presence. The F7
        // cold-review fix unifies BOTH the named and blank paths through the roster (which IS the
        // on-disk agent.json scan): the resolver reports `agentJsonPresent`, and the clean-exit arm
        // feeds it into the classifier. This replaces the old raw per-name `fileExists` probe — the
        // roster is the consistent presence source for both paths (and the only one that works for
        // the blank-name default).
        XCTAssertTrue(
            body.contains("agentJsonPresent"),
            "the clean-exit arm must consult agent.json presence (now via the resolver, gap #2)"
        )
        XCTAssertTrue(
            body.contains("resolution.agentJsonPresent") || body.contains("resolvedClone.agentJsonPresent"),
            "presence must come from the resolver's roster-derived agentJsonPresent (unifies named + blank paths)"
        )
    }

    // MARK: - The runner no longer throws (B-1: returns CloneRunResult)

    func testCloneRunnerIsAwaitedForItsResultNotTried() throws {
        let body = try cloneBranch()
        // The runner used to THROW CloneFailedError; it now returns a CloneRunResult that gets read.
        XCTAssertFalse(
            body.contains("try await CloneAgentRunner.runHeadless"),
            "runHeadless must no longer throw — F7 reads the CloneRunResult (B-1 timeout distinction)"
        )
        XCTAssertTrue(
            body.contains("await CloneAgentRunner.runHeadless(plan: plan)"),
            "the runner must be awaited for its CloneRunResult"
        )
    }

    // MARK: - Only inspect bundle / probe on a clean exit

    func testCloneInspectsBundleOnlyOnACleanExit() throws {
        let body = try cloneBranch()
        // B-2 — the agent.json check + probe must sit on the `.exited(code: 0)` arm so a wedged /
        // not-yet-flushed bundle isn't probed mid-clone.
        XCTAssertTrue(
            body.contains(".exited(code: 0)"),
            "the bundle inspection + probe must be gated behind the clean-exit arm (.exited(code: 0))"
        )
    }

    // MARK: - succeeded:true gated behind .ready ONLY

    func testSuccessActionLogIsGatedBehindTheReadyBranch() throws {
        let body = try cloneBranch()
        guard let readyRange = body.range(of: "case .ready:") else {
            return XCTFail("the outcome switch must have an explicit .ready arm")
        }
        let beforeReady = String(body[body.startIndex..<readyRange.lowerBound])
        let afterReady = String(body[readyRange.lowerBound...])
        XCTAssertFalse(
            beforeReady.contains("succeeded: true"),
            "no success may be logged before the .ready branch (that was the gap #1 lie)"
        )
        XCTAssertTrue(
            afterReady.contains("succeeded: true"),
            "the success action log must live in/after the .ready branch"
        )
    }

    // MARK: - needsVaultUnlock reuses F6 (no new clone vault-create)

    func testNeedsVaultUnlockReusesBeginCredentialRotation() throws {
        let body = try cloneBranch()
        XCTAssertTrue(
            body.contains("case .needsVaultUnlock:"),
            "the outcome switch must have an explicit .needsVaultUnlock arm"
        )
        XCTAssertTrue(
            body.contains("beginCredentialRotation"),
            "the .needsVaultUnlock arm must reuse F6's beginCredentialRotation (no new clone vault flow)"
        )
        // No clone-specific vault-CREATE: the cloned vault already exists; we unlock/reconnect it.
        XCTAssertFalse(
            body.contains("vault create"),
            "the clone path must NOT create a vault — it reuses F6's unlock/reconnect chain"
        )
    }

    func testNeedsVaultUnlockSetsTheRotationFlavorBeforeLaunch() throws {
        let body = try cloneBranch()
        // B-5 — the rotation reuses the shared vault-onboarding markers; flavor it as a rotation so
        // the reconnect copy reads correctly (beginCredentialRotation itself sets .rotation, but the
        // arm must route through it rather than the cold-start onboarding flavor).
        guard let unlockRange = body.range(of: "case .needsVaultUnlock:") else {
            return XCTFail("the outcome switch must have an explicit .needsVaultUnlock arm")
        }
        let afterUnlock = String(body[unlockRange.lowerBound...])
        XCTAssertTrue(
            afterUnlock.contains("beginCredentialRotation"),
            "the .needsVaultUnlock arm must drive beginCredentialRotation (which sets the .rotation flavor + F6 markers)"
        )
    }

    // MARK: - Honest failure: no "Git remote" in the generic fold

    func testHumanFacingLineDrivesNonReadyOutcomes() throws {
        let body = try cloneBranch()
        XCTAssertTrue(
            body.contains("humanFacingLine"),
            "non-ready outcomes must surface the seam-free humanFacingLine to the sheet"
        )
    }

    func testGenericFailureFoldDoesNotHardcodeTheGitRemoteCopy() throws {
        let body = try cloneBranch()
        // gap #3 — "Check the Git remote" must come ONLY from the classifier's .cloneNonZeroExit
        // copy, never from a hardcoded App-side fold that mis-maps a 120s wedge. The legacy
        // `CloneAgentFlowState.failureReason(forRemoteLabel:)` mapping (which blamed the remote for
        // EVERY non-zero/timeout) must be gone from the run-outcome fold.
        guard let runRange = body.range(of: "CloneOutcomeClassifier.classifyClone") else {
            return XCTFail("expected the classify fold")
        }
        let afterClassify = String(body[runRange.lowerBound...])
        XCTAssertFalse(
            afterClassify.contains("failureReason(forRemoteLabel:"),
            "the run-outcome fold must use the classifier's per-cause copy, not the remote-blaming legacy fold"
        )
    }

    func testAlwaysRefreshesTheAgentRoster() throws {
        let body = try cloneBranch()
        // A non-ready outcome must still refresh inventory so a dead/needs-credentials bundle
        // surfaces honestly rather than as ready (or vanishing).
        XCTAssertTrue(
            body.contains("refreshOuroAgents()"),
            "the branch must refresh the agent roster on every outcome"
        )
    }

    // MARK: - F7 cold-review CRITICAL: resolve the cloned agent from the refreshed roster

    /// The blank-name false-red fix routes the clean-exit arm through the pure
    /// `ClonedAgentResolver.resolveClonedAgent` seam instead of deriving + assuming. BOTH the named
    /// and blank paths must use it (the roster IS the consistent on-disk agent.json source).
    func testCloneResolvesTheClonedAgentViaTheResolverSeam() throws {
        let body = try cloneBranch()
        XCTAssertTrue(
            body.contains("ClonedAgentResolver.resolveClonedAgent"),
            "the clean-exit arm must resolve the cloned agent via ClonedAgentResolver.resolveClonedAgent"
        )
    }

    /// THE bug: the whole bundle/probe inspection was gated on `!resolvedName.isEmpty`, so a BLANK
    /// agent name (the recommended default) skipped it and a clean successful clone was reported as
    /// the false `.invalidMissingAgentJson`. That gate must be GONE.
    func testCloneNoLongerSkipsInspectionOnABlankName() throws {
        let body = try cloneBranch()
        XCTAssertFalse(
            body.contains("!resolvedName.isEmpty"),
            "the clean-exit arm must NOT gate inspection on a non-blank name — a blank name is the default"
        )
    }

    /// The resolver verifies against REALITY, so the roster must be snapshotted BEFORE the clone (the
    /// diff baseline) and the refresh must precede the resolver read (it's synchronous).
    func testCloneSnapshotsTheRosterBeforeTheClone() throws {
        let body = try cloneBranch()
        guard let runRange = body.range(of: "await CloneAgentRunner.runHeadless(plan: plan)") else {
            return XCTFail("expected the runner await")
        }
        let beforeRun = String(body[body.startIndex..<runRange.lowerBound])
        XCTAssertTrue(
            beforeRun.contains("rosterNamesBefore") || beforeRun.contains("namesBefore"),
            "the roster names must be snapshotted BEFORE the clone runs (the resolver's diff baseline)"
        )
    }

    /// The refresh (which re-scans agent.json) must precede the resolver call so the resolver reads
    /// the post-clone reality, and the resolver call must precede classification.
    func testCloneRefreshesRosterBeforeResolvingAndClassifying() throws {
        let body = try cloneBranch()
        guard let refreshIdx = body.range(of: "refreshOuroAgents()")?.lowerBound,
              let resolveIdx = body.range(of: "ClonedAgentResolver.resolveClonedAgent")?.lowerBound,
              let classifyIdx = body.range(of: "CloneOutcomeClassifier.classifyClone")?.lowerBound
        else {
            return XCTFail("expected refresh, resolve, and classify in the branch")
        }
        XCTAssertTrue(refreshIdx < resolveIdx, "refreshOuroAgents() must run BEFORE the resolver reads the roster")
        XCTAssertTrue(resolveIdx < classifyIdx, "the resolver must run BEFORE classifyClone consumes its result")
    }

    /// The post-clone probe must check the RESOLVED name (what actually landed), not the raw
    /// operator input — a blank input would otherwise probe an empty agent name.
    func testCloneProbeUsesTheResolvedName() throws {
        let body = try cloneBranch()
        guard let probeRange = body.range(of: "runCloneProviderCheck(agentName:") else {
            return XCTFail("expected the clone provider probe call")
        }
        let afterProbe = String(body[probeRange.lowerBound...])
        // The argument must reference the resolution's name, not the raw `resolvedName`/`agentName`.
        let probeCallLine = String(afterProbe.prefix(while: { $0 != ")" }))
        XCTAssertTrue(
            probeCallLine.contains("resolution.name") || probeCallLine.contains("resolvedClone"),
            "the probe must check the resolver's name (the agent that actually landed), not the raw input"
        )
    }

    // MARK: - The dedicated short-budget clone probe

    func testCloneProbeRunsAShortBudgetCheck() throws {
        let source = try appSource()
        XCTAssertTrue(
            source.contains("func runCloneProviderCheck"),
            "a dedicated short-budget clone probe method must exist"
        )
        let probe = try sourceSlice(
            in: source,
            from: "private func runCloneProviderCheck",
            to: "\n    private func "
        )
        XCTAssertTrue(
            probe.contains("ProviderCheckClassifier"),
            "the clone probe must classify via ProviderCheckClassifier (F2 seam)"
        )
        XCTAssertTrue(
            probe.contains("timeout") || probe.contains("Deadline") || probe.contains("15"),
            "the clone probe must use a short watchdog budget"
        )
    }

    // MARK: - Helpers (mirror ColdStartHonestWiringTests)

    private func appSource() throws -> String {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("OuroWorkbenchApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound)
        return String(source[start..<end])
    }
}
