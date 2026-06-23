import XCTest
@testable import OuroWorkbenchCore

/// Four autonomy/reliability fixes in `OuroWorkbenchApp.swift`. The App target
/// isn't coverage-gated, so the wiring is verified by SOURCE-PINS (same pattern
/// as `BossWatchBackoffBumpWiringTests`); the pure decision seams live in
/// `BossAutonomyGating` (Core, 100% coverage-gated) and are unit-tested
/// exhaustively here.
final class BossAutonomyKillSwitchWiringTests: XCTestCase {

    // MARK: - FIX1 pure seam: the pump's "apply now?" decision

    /// `shouldApplyQueuedActions(bossWatchEnabled:)` is the testable kill-switch
    /// decision: while Boss Watch is PAUSED the pump must NOT drain+apply queued
    /// requests (they stay HELD on disk); while ON it applies as before.
    func testShouldApplyQueuedActionsTrueWhenWatchEnabled() {
        XCTAssertTrue(
            BossAutonomyGating.shouldApplyQueuedActions(bossWatchEnabled: true),
            "with Boss Watch ON the pump must apply queued actions (no regression to normal autonomy)"
        )
    }

    func testShouldApplyQueuedActionsFalseWhenWatchPaused() {
        XCTAssertFalse(
            BossAutonomyGating.shouldApplyQueuedActions(bossWatchEnabled: false),
            "PAUSED Boss Watch is a true kill-switch: the pump must NOT apply queued actions while off"
        )
    }

    // MARK: - FIX1 wiring: the pump gates its drain+apply on the kill-switch

    /// The steady-state pump loop must consult the kill-switch BEFORE draining +
    /// applying. The drain MOVES request files into `processing/`, so the gate has
    /// to skip the drain entirely when paused (NOT drain-then-discard) — that's
    /// what keeps the held requests on disk and lossless.
    func testPumpLoopGatesDrainOnKillSwitch() throws {
        let body = try runExternalActionPumpBody()
        XCTAssertTrue(
            body.contains("shouldApplyQueuedActions(bossWatchEnabled: bossWatchIsEnabled)"),
            "the pump loop must gate its drain/apply on the pure kill-switch seam"
        )
        // The gate must wrap the drain call — when off, the drain is skipped so the
        // request files are HELD in the queue dir (never moved into processing/).
        let gateRange = try XCTUnwrap(
            body.range(of: "shouldApplyQueuedActions(bossWatchEnabled: bossWatchIsEnabled)"),
            "kill-switch gate not found in pump loop"
        )
        let drainRange = try XCTUnwrap(
            body.range(of: "drainExternalActionRequests()"),
            "drain call not found in pump loop"
        )
        XCTAssertTrue(
            gateRange.lowerBound < drainRange.lowerBound,
            "the kill-switch gate must be checked BEFORE the drain, so a paused watch never moves request files into processing/"
        )
    }

    /// The pump must keep its steady-state sleep so a paused watch re-checks the
    /// switch each tick and resumes applying the held queue once re-enabled —
    /// the gate must not turn the loop into a busy-spin or a one-shot.
    func testPumpLoopKeepsSteadyStateSleepWhenGated() throws {
        let body = try runExternalActionPumpBody()
        XCTAssertTrue(
            body.contains("Task.sleep"),
            "the pump must keep its steady-state sleep so a re-enabled watch resumes applying the held queue"
        )
    }

    // MARK: - FIX2: each screen terminator SIGKILLs after the timeout terminate()

    /// The three screen terminators (spawnScreenQuit, listLiveScreenSessionNames,
    /// persistentSessionIsListed) timed out → `terminate()` (SIGTERM) with NO
    /// SIGKILL backstop, so a SIGTERM-ignoring `screen` survived. Each must now
    /// `kill(process.processIdentifier, SIGKILL)` after the timeout terminate().
    func testScreenTerminatorsHaveSigkillBackstop() throws {
        let source = try appSource()
        for fn in ["spawnScreenQuit", "listLiveScreenSessionNames", "persistentSessionIsListed"] {
            let body = try functionBody(named: fn, in: source)
            XCTAssertTrue(
                body.contains("process.terminate()"),
                "\(fn) must still SIGTERM on timeout"
            )
            XCTAssertTrue(
                body.contains("kill(process.processIdentifier, SIGKILL)"),
                "\(fn) must SIGKILL after the timeout terminate() (mirror the boss client forceKill) — a SIGTERM-ignoring screen survives otherwise"
            )
        }
    }

    /// The SIGKILL must follow the `terminate()` inside the timed-out branch — not
    /// precede it (terminate-then-kill is the escalation order).
    func testScreenSigkillFollowsTerminate() throws {
        let source = try appSource()
        for fn in ["spawnScreenQuit", "listLiveScreenSessionNames", "persistentSessionIsListed"] {
            let body = try functionBody(named: fn, in: source)
            let term = try XCTUnwrap(body.range(of: "process.terminate()"), "\(fn): no terminate()")
            let kill = try XCTUnwrap(
                body.range(of: "kill(process.processIdentifier, SIGKILL)"),
                "\(fn): no SIGKILL"
            )
            XCTAssertTrue(
                term.lowerBound < kill.lowerBound,
                "\(fn): SIGKILL must escalate AFTER the SIGTERM terminate()"
            )
        }
    }

    // MARK: - FIX3: one check-in applies + records, then saves ONCE

    /// `recordBossDecisions` must no longer carry its own `save()` — the single
    /// check-in folds the per-action `recordActionLog` saves and the decision save
    /// into ONE trailing save via a batched-save scope. Otherwise a crash mid
    /// check-in (or a zero-change decisions batch) leaves executed actions without
    /// their decision/audit rows.
    func testCheckInWrapsApplyAndRecordInOneSaveBatch() throws {
        let body = try runBossCheckInPrivateBody()
        // The apply + record pair must be wrapped in the batched-save scope so the
        // individual saves are suppressed and a single trailing save persists both.
        XCTAssertTrue(
            body.contains("withBatchedSave"),
            "the check-in must wrap applyBossActions + recordBossDecisions in a batched-save scope so they persist in ONE save()"
        )
        let batchRange = try XCTUnwrap(
            body.range(of: "withBatchedSave"),
            "batched-save scope not found in the check-in"
        )
        let applyRange = try XCTUnwrap(
            body.range(of: "applyBossActions(from: answer)"),
            "applyBossActions not found in the check-in"
        )
        let recordRange = try XCTUnwrap(
            body.range(of: "recordBossDecisions(from: answer)"),
            "recordBossDecisions not found in the check-in"
        )
        XCTAssertTrue(
            batchRange.lowerBound < applyRange.lowerBound && batchRange.lowerBound < recordRange.lowerBound,
            "applyBossActions + recordBossDecisions must both run INSIDE the batched-save scope"
        )
    }

    /// The batched-save scope must respect the existing suppression guards: it
    /// flushes through the model's `save()` (which already honors
    /// `isLoadingState` / `isResettingToFirstRun`), and during the batch the
    /// per-call saves are no-ops.
    func testBatchedSaveRespectsSuppressionGuardsAndSavesOnce() throws {
        let source = try appSource()
        let batchBody = try functionBody(named: "withBatchedSave", in: source)
        XCTAssertTrue(
            batchBody.contains("save()"),
            "the batched-save helper must perform exactly the single trailing save() (which honors the existing suppression guards)"
        )
        // recordBossDecisions must drop its own inline save — the batch owns it now.
        let decisions = try functionBody(named: "recordBossDecisions", in: source)
        XCTAssertFalse(
            decisions.contains("if changed > 0 {\n            save()"),
            "recordBossDecisions must no longer save() on its own — the single check-in batch owns the trailing save"
        )
    }

    // MARK: - FIX4: the boss-watch loop doesn't wake-spin while OFF

    /// The loop used to sleep+wake every 60s forever even while Watch is OFF, just
    /// to `continue`. The loop is now started/cancelled by `setBossWatchEnabled`
    /// (a held task handle), so it only runs while enabled — no idle wakeups.
    func testWatchLoopStartStopDrivenByEnableToggle() throws {
        let setter = try functionBody(named: "setBossWatchEnabled", in: try appSource())
        XCTAssertTrue(
            setter.contains("bossWatchLoopTask"),
            "setBossWatchEnabled must own the loop's lifecycle via a held task handle (start on enable, cancel on disable)"
        )
        XCTAssertTrue(
            setter.contains("runBossWatchLoop()"),
            "enabling must START the loop"
        )
        XCTAssertTrue(
            setter.contains(".cancel()"),
            "disabling must CANCEL the loop so it stops waking"
        )
    }

    /// The loop body must no longer carry the wake-then-`continue`-while-off
    /// busy pattern (sleep, then `guard bossWatchIsEnabled else { continue }`).
    func testWatchLoopNoLongerBusyWakesWhenOff() throws {
        let loop = try functionBody(named: "runBossWatchLoop", in: try appSource())
        XCTAssertFalse(
            loop.contains("guard bossWatchIsEnabled else {\n                continue"),
            "the loop must not wake every interval just to continue while Watch is OFF — its start/stop is driven by setBossWatchEnabled"
        )
    }

    /// FIX4 must NOT re-introduce the unconditional `.task { await model.runBossWatchLoop() }`
    /// at the view root — the loop is now owned by the enable toggle.
    func testWatchLoopNotLaunchedUnconditionallyAtViewRoot() throws {
        let source = try appSource()
        XCTAssertFalse(
            source.contains(".task {\n            await model.runBossWatchLoop()\n        }"),
            "the boss-watch loop must no longer be an unconditional .task — setBossWatchEnabled owns its lifecycle"
        )
    }

    // MARK: - source-pin helpers (App is not coverage-gated)

    private func runExternalActionPumpBody() throws -> String {
        try functionBody(named: "runExternalActionPump", in: try appSource())
    }

    private func runBossCheckInPrivateBody() throws -> String {
        let source = try appSource()
        let start = try XCTUnwrap(
            source.range(of: "private func runBossCheckIn(")?.upperBound,
            "could not find private runBossCheckIn in the App source"
        )
        let tail = source[start...]
        let end = tail.range(of: "\n    func ")?.lowerBound ?? tail.endIndex
        return String(tail[tail.startIndex..<end])
    }

    /// Extract a function body by matching `func <name>(` (or the generic
    /// `func <name><…>(`) and reading to the next top-level
    /// `func `/`private func `/`nonisolated` boundary. Good enough for a source-pin
    /// (we only assert on tokens within the body).
    private func functionBody(named name: String, in source: String) throws -> String {
        let start = try XCTUnwrap(
            source.range(of: "func \(name)(")?.upperBound
                ?? source.range(of: "func \(name)<")?.upperBound,
            "could not find func \(name)( in the App source"
        )
        let tail = source[start...]
        let end = tail.range(of: "\n    func ")?.lowerBound
            ?? tail.range(of: "\n    private func ")?.lowerBound
            ?? tail.range(of: "\n    nonisolated ")?.lowerBound
            ?? tail.endIndex
        return String(tail[tail.startIndex..<end])
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
}
