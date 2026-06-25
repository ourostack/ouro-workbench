import XCTest
@testable import OuroWorkbenchCore

/// F11a Defect 1 — durable wiring assertions for the terminal-leak fix and the
/// startup reaper. The pure `ScreenSessionReaper` seam is unit-tested + 100%
/// covered in Core; the App that invokes it isn't coverage-gated and can't be
/// click-tested in CI, so we source-pin its structural wiring the same way
/// `SessionIdBackfillWiringTests` (F4) does.
///
/// The risks these pins defend:
///   - delete/archive must QUIT the `ouro-wb-<id>` screen — before they mutate
///     state away the id (removeAll / replaceEntry) — or a detached-but-alive
///     session leaks its screen + process forever;
///   - the startup reaper must derive `knownEntryIds` from `state.processEntries`
///     and run AFTER `refreshLiveScreenSessions` populates the cache AND only
///     when state-load SUCCEEDED — if it ran before load (or on a failed load),
///     `knownEntryIds` would be empty and it would quit EVERY live session,
///     including reattachable survivors (F8-class "kill the wrong thing");
///   - both the per-entry quit and the reaper reuse the SAME off-main + watchdog
///     spawn (`spawnScreenQuit`) rather than copy-pasting the watchdog;
///   - the reaper reuses the cached `liveScreenSessionNames` (no second
///     `screen -ls` probe).
final class TerminalLeakReaperWiringTests: XCTestCase {
    // MARK: Per-entry quit helper

    func testQuitHelperQuitsUnconditionallyAndIsNotGatedOnTheStaleCache() throws {
        // HIGH cold-review fix: the per-entry quit MUST be unconditional. The old
        // shape gated the quit on `ScreenSessionReaper.quitArguments(...,
        // liveSessionNames: liveScreenSessionNames)`, which returns nil unless the
        // name is in the startup-only `liveScreenSessionNames` cache. That cache is
        // populated EXACTLY once (refreshLiveScreenSessions at launch) and never
        // refreshed, so a session created THIS run is never in it → the quit was
        // silently skipped. For archive (the entry keeps its id and stays in
        // state.processEntries) that leaks the screen PERMANENTLY. The quit must be
        // issued for `sessionName(for: entryId)` with NO liveness gate.
        let body = try quitHelper()
        XCTAssertTrue(
            body.contains("spawnScreenQuit"),
            "the quit helper must spawn via the shared spawnScreenQuit (off-main + watchdog), not a bespoke spawn"
        )
        XCTAssertTrue(
            body.contains("PersistentTerminalSession.terminateArguments(") &&
                body.contains("PersistentTerminalSession.sessionName(for: entryId)"),
            "the quit helper must issue terminateArguments(sessionName: sessionName(for: entryId)) UNCONDITIONALLY for the entry"
        )
        // Regression guards: re-introducing the stale-cache liveness gate must trip
        // this. The helper must NOT consult the startup-only cache and must NOT
        // route the decision through the nil-gated reaper seam.
        XCTAssertFalse(
            body.contains("liveScreenSessionNames"),
            "the per-entry quit must NOT be gated on the startup-only liveScreenSessionNames cache (a within-run session is never in it → quit silently skipped → permanent archive leak)"
        )
        XCTAssertFalse(
            body.contains("ScreenSessionReaper.quitArguments"),
            "the per-entry quit must NOT route through the nil-gated quitArguments seam (that seam re-introduces the stale-cache liveness gate)"
        )
    }

    func testSharedSpawnHelperExists() throws {
        let source = try WorkbenchAppSource.appSource()
        XCTAssertTrue(
            source.contains("func spawnScreenQuit"),
            "a shared spawnScreenQuit must factor the off-main + 1.5s watchdog so it isn't copy-pasted"
        )
        let spawn = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func spawnScreenQuit",
            to: "\n    func "
        )
        XCTAssertTrue(
            spawn.contains("DispatchSemaphore") && spawn.contains("1500"),
            "spawnScreenQuit must carry the bounded 1.5s watchdog (wedged screen socket must not hang a worker thread forever)"
        )
    }

    // MARK: delete / archive call the quit BEFORE mutating state

    func testDeleteCustomSessionQuitsScreenBeforeRemovingTheEntry() throws {
        let body = try WorkbenchAppSource.sourceSlice(
            in: try WorkbenchAppSource.appSource(),
            from: "func deleteCustomSession(_ entry: ProcessEntry)",
            to: "\n    private func recover(_ entry: ProcessEntry, recoveryPlan:"
        )
        let quitIndex = try XCTUnwrap(
            body.range(of: "quitPersistentScreenIfNeeded")?.lowerBound,
            "deleteCustomSession must quit the persistent screen"
        )
        let removeIndex = try XCTUnwrap(
            body.range(of: "state.processEntries.removeAll")?.lowerBound,
            "deleteCustomSession must remove the entry"
        )
        XCTAssertLessThan(
            quitIndex, removeIndex,
            "the quit must run BEFORE processEntries.removeAll while the entry id is still derivable"
        )
    }

    func testArchiveCustomSessionQuitsScreenBeforeReplacingTheEntry() throws {
        let body = try WorkbenchAppSource.sourceSlice(
            in: try WorkbenchAppSource.appSource(),
            from: "func archiveCustomSession(_ entry: ProcessEntry",
            to: "\n    func restoreCustomSession"
        )
        let quitIndex = try XCTUnwrap(
            body.range(of: "quitPersistentScreenIfNeeded")?.lowerBound,
            "archiveCustomSession must quit the persistent screen"
        )
        let replaceIndex = try XCTUnwrap(
            body.range(of: "replaceEntry(")?.lowerBound,
            "archiveCustomSession must replace the entry with the archived form"
        )
        XCTAssertLessThan(
            quitIndex, replaceIndex,
            "the quit must run BEFORE replaceEntry (the entry id is still derivable)"
        )
    }

    // MARK: startup reaper

    func testReaperExistsAndDerivesKnownEntryIdsFromState() throws {
        let body = try reaper()
        XCTAssertTrue(
            body.contains("ScreenSessionReaper.orphanedSessionNames"),
            "the reaper must consult the pure ScreenSessionReaper seam"
        )
        XCTAssertTrue(
            body.contains("state.processEntries.map(\\.id)"),
            "knownEntryIds must be derived FORWARD from state.processEntries (so a session a known id hashes to is spared)"
        )
        XCTAssertTrue(
            body.contains("liveScreenSessionNames"),
            "the reaper must reuse the cached live-session set (no second screen -ls probe)"
        )
        XCTAssertTrue(
            body.contains("spawnScreenQuit"),
            "the reaper must quit each orphan via the shared spawnScreenQuit"
        )
    }

    func testReaperIsGatedOnStateLoadSuccess() throws {
        let body = try reaper()
        XCTAssertTrue(
            body.contains("stateLoadSucceeded"),
            "the reaper must NO-OP unless state-load SUCCEEDED — a failed load looks identical to 'no entries', and an empty knownEntryIds would quit EVERY live session (incl. reattachable survivors, F8-class)"
        )
    }

    func testReaperIsWiredAfterRefreshLiveScreenSessionsAtStartup() throws {
        let source = try WorkbenchAppSource.appSource()
        // The startup task: order is load (in init) → refreshLiveScreenSessions
        // → reapOrphanedScreenSessions. Pin that the reaper call sits AFTER the
        // live-session refresh so the cache is populated when it runs.
        let startup = try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "await model.refreshLiveScreenSessions()",
            to: "model.recoverEligibleSessionsOnStartup()"
        )
        XCTAssertTrue(
            startup.contains("reapOrphanedScreenSessions"),
            "the reaper must be invoked at startup AFTER refreshLiveScreenSessions populates liveScreenSessionNames"
        )
    }

    func testStateLoadFlagIsSetOnlyOnTheSuccessPath() throws {
        let load = try WorkbenchAppSource.sourceSlice(
            in: try WorkbenchAppSource.appSource(),
            from: "private func load() {",
            to: "\n    /// Rebuild the in-memory detail split"
        )
        XCTAssertTrue(
            load.contains("stateLoadSucceeded = true"),
            "load() must record success so the reaper can gate on it"
        )
    }

    // MARK: - Helpers

    private func quitHelper() throws -> String {
        // Slice exactly the helper's signature + body. Stop at its closing brace
        // (the blank line before the NEXT member's doc comment) so the reaper's
        // docstring — which legitimately mentions liveScreenSessionNames — can't
        // bleed in and mask the stale-cache regression guard below.
        try WorkbenchAppSource.sourceSlice(
            in: try WorkbenchAppSource.appSource(),
            from: "func quitPersistentScreenIfNeeded",
            to: "\n    }\n"
        )
    }

    private func reaper() throws -> String {
        try WorkbenchAppSource.sourceSlice(
            in: try WorkbenchAppSource.appSource(),
            from: "func reapOrphanedScreenSessions",
            to: "\n    func "
        )
    }
}
