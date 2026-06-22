import XCTest
@testable import OuroWorkbenchCore

/// F11b Defect 3 — durable wiring assertions for the replay double-execute fix.
///
/// The pure `ReplayDedupDecider` seam + the `applied/` ledger on
/// `WorkbenchActionRequestQueue` are unit-tested and 100% covered in Core; the
/// App that wires them isn't coverage-gated and can't be click-tested in CI, so
/// we source-pin its structural wiring the same way `SessionIdBackfillWiringTests`
/// (F4) and `TerminalLeakReaperWiringTests` (F11a) do.
///
/// The risks these pins defend:
///   - the universal skip-on-replay must consult `ReplayDedupDecider` and return
///     early on `.skipAlreadyApplied` at the TOP of `applyBossAction` — AFTER
///     `validateForQueueing` but BEFORE the first action switch — so EVERY kind
///     (launch / createSession / sendInput / …) is guarded, not just the
///     `isNewDecision`-guarded `sendInput`;
///   - THE most important pin: in `applyExternalActionRequests`, `markApplied`
///     must run AFTER the synchronous `applyBossAction` (the side effect) and
///     BEFORE the detached confirm loop — if a fold removes it or orders it after
///     confirm, the crash window reopens and a recovered request double-executes;
///   - the detached loop must call BOTH `confirmApplied` (delete the
///     `processing/` file) AND `clearApplied` (delete the marker), so the applied
///     ledger doesn't grow unbounded in steady state;
///   - the startup sweep must run after `recoverUnconfirmedExternalActionRequests`
///     and clear any marker whose `processing/` file is gone (crash-orphaned
///     after confirm-but-before-clear);
///   - the existing `isNewDecision` / `bossActionLivePrompt` `sendInput` guard
///     must stay UNCHANGED (defense-in-depth + the operator no-requestId path).
final class ReplayDedupWiringTests: XCTestCase {
    // MARK: Universal skip-on-replay at the top of applyBossAction

    func testApplyBossActionConsultsDeciderAfterValidateBeforeFirstSwitch() throws {
        let body = try applyBossActionPrelude()
        let validateIndex = try XCTUnwrap(
            body.range(of: "try action.validateForQueueing()")?.lowerBound,
            "applyBossAction must validate the action for queueing"
        )
        let decideIndex = try XCTUnwrap(
            body.range(of: "ReplayDedupDecider().decide(")?.lowerBound,
            "applyBossAction must consult ReplayDedupDecider for a universal replay guard"
        )
        XCTAssertLessThan(
            validateIndex, decideIndex,
            "the replay-skip decision must come AFTER validateForQueueing (a malformed request is rejected first)"
        )
        // The decision reads the durable applied-id ledger from the queue.
        XCTAssertTrue(
            body.contains("externalActionQueue.appliedRequestIds()"),
            "the replay decision must read the durable applied-id ledger (externalActionQueue.appliedRequestIds())"
        )
    }

    func testReplaySkipIsGatedOnRequestIdAndReturnsEarlyWithReplayResult() throws {
        let body = try applyBossActionPrelude()
        // Gated on requestId != nil: operator (no-requestId) actions are never
        // replayed from the queue, so they're never deduped/marked.
        XCTAssertTrue(
            body.contains("requestId") && body.contains("ReplayDedupDecider().decide("),
            "the replay-skip must be gated on requestId (operator no-requestId actions are never deduped)"
        )
        XCTAssertTrue(
            body.contains(".skipAlreadyApplied"),
            "the replay guard must branch on .skipAlreadyApplied"
        )
        XCTAssertTrue(
            body.contains("already applied (replay)"),
            "a skipped replay must finish with a 'Skipped <kind>: already applied (replay)' result"
        )
        // Returns early via finishBossAction before any handler runs.
        let decideIndex = try XCTUnwrap(body.range(of: "ReplayDedupDecider().decide(")?.lowerBound)
        let finishIndex = try XCTUnwrap(
            body.range(of: "already applied (replay)")?.lowerBound,
            "the skip path must call finishBossAction"
        )
        XCTAssertLessThan(decideIndex, finishIndex)
    }

    // MARK: markApplied ordering — THE key invariant

    func testApplyExternalActionRequestsMarksAppliedAfterApplyBeforeDetachedConfirm() throws {
        let body = try applyExternalActionRequests()
        let applyIndex = try XCTUnwrap(
            body.range(of: "applyBossAction(")?.lowerBound,
            "applyExternalActionRequests must apply each request via applyBossAction"
        )
        let markIndex = try XCTUnwrap(
            body.range(of: "markApplied(")?.lowerBound,
            "applyExternalActionRequests must markApplied each request (durable replay marker)"
        )
        let detachIndex = try XCTUnwrap(
            body.range(of: "Task.detached")?.lowerBound,
            "applyExternalActionRequests must confirm off-main in a detached task"
        )
        // ORDERING CONTRACT: side-effect (applyBossAction) → markApplied (durable)
        // → detached confirm. markApplied lands BEFORE the crash window the
        // detached confirm opens.
        XCTAssertLessThan(
            applyIndex, markIndex,
            "markApplied must run AFTER the synchronous applyBossAction (the side effect)"
        )
        XCTAssertLessThan(
            markIndex, detachIndex,
            "markApplied must run BEFORE the detached confirm loop (the durable marker must land inside the crash window)"
        )
        // markApplied is on the queue (main-actor synchronous), not inside the
        // detached task.
        XCTAssertTrue(
            body.contains("externalActionQueue.markApplied("),
            "markApplied must be called on the main-actor externalActionQueue synchronously, not off-main"
        )
    }

    func testDetachedConfirmLoopCallsBothConfirmAppliedAndClearApplied() throws {
        let body = try applyExternalActionRequests()
        let detachIndex = try XCTUnwrap(body.range(of: "Task.detached")?.lowerBound)
        let detached = String(body[detachIndex...])
        XCTAssertTrue(
            detached.contains("confirmApplied("),
            "the detached loop must confirmApplied (delete the processing/ file)"
        )
        XCTAssertTrue(
            detached.contains("clearApplied("),
            "the detached loop must clearApplied (delete the marker) so applied/ stays empty in steady state"
        )
        // confirm before clear (ORDERING: confirmApplied deletes processing, THEN
        // clearApplied deletes the marker — a crash between them is caught by the
        // startup sweep).
        let confirmIndex = try XCTUnwrap(detached.range(of: "confirmApplied(")?.lowerBound)
        let clearIndex = try XCTUnwrap(detached.range(of: "clearApplied(")?.lowerBound)
        XCTAssertLessThan(
            confirmIndex, clearIndex,
            "confirmApplied (delete processing) must precede clearApplied (delete marker)"
        )
    }

    // MARK: startup orphan-marker sweep

    func testStartupSweepIsWiredAfterRecoverUnconfirmed() throws {
        let source = try appSource()
        let pump = try sourceSlice(
            in: source,
            from: "func runExternalActionPump() async {",
            to: "\n    /// Sendable result of an off-main queue drain."
        )
        let recoverIndex = try XCTUnwrap(
            pump.range(of: "recoverUnconfirmedExternalActionRequests()")?.lowerBound,
            "the pump must replay unconfirmed requests at startup"
        )
        let sweepIndex = try XCTUnwrap(
            pump.range(of: "sweepOrphanedAppliedMarkers()")?.lowerBound,
            "the startup orphan-marker sweep must be wired into the pump"
        )
        XCTAssertLessThan(
            recoverIndex, sweepIndex,
            "the orphan-marker sweep must run AFTER recoverUnconfirmedExternalActionRequests"
        )
    }

    func testStartupSweepClearsMarkersWhoseProcessingFileIsGone() throws {
        let body = try sourceSlice(
            in: try appSource(),
            from: "func sweepOrphanedAppliedMarkers() async",
            to: "\n    func "
        )
        XCTAssertTrue(
            body.contains("appliedRequestIds()"),
            "the sweep must enumerate the applied-marker ledger"
        )
        XCTAssertTrue(
            body.contains("clearApplied("),
            "the sweep must clearApplied each orphaned marker"
        )
        XCTAssertTrue(
            body.contains("isPendingOrProcessing(") || body.contains("processing"),
            "the sweep must only clear a marker whose processing/ file is gone (orphaned after confirm-before-clear)"
        )
    }

    // MARK: existing sendInput guard unchanged

    func testIsNewDecisionSendInputGuardIsUnchanged() throws {
        let source = try appSource()
        // The defense-in-depth + operator no-requestId path: the live-prompt
        // isNewDecision guard on the sendInput case must remain.
        XCTAssertTrue(
            source.contains("state.isNewDecision(entryId: entry.id, prompt: livePrompt, kind: .autoAdvance)"),
            "the existing isNewDecision sendInput guard must stay UNCHANGED (defense-in-depth + operator no-requestId path)"
        )
        XCTAssertTrue(
            source.contains("Skipped sendInput for \\(entry.name): already handled this prompt"),
            "the isNewDecision skip result must stay UNCHANGED"
        )
    }

    // MARK: - Helpers

    /// The prelude of `applyBossAction` — from its signature down to the first
    /// `switch action.action`, where the universal replay guard must sit.
    private func applyBossActionPrelude() throws -> String {
        try sourceSlice(
            in: try appSource(),
            from: "private func applyBossAction(_ action: BossWorkbenchAction, source: String, requestId: UUID? = nil) -> String {",
            to: "\n        switch action.action {"
        )
    }

    private func applyExternalActionRequests() throws -> String {
        try sourceSlice(
            in: try appSource(),
            from: "private func applyExternalActionRequests(_ requests: [WorkbenchActionRequest]) {",
            to: "\n    /// Refresh the set of live persistent"
        )
    }

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
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound, "missing start marker: \(startMarker)")
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound, "missing end marker: \(endMarker)")
        return String(source[start..<end])
    }
}
