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

    func testQuitHelperExistsAndConsultsTheReaperSeam() throws {
        let body = try quitHelper()
        XCTAssertTrue(
            body.contains("ScreenSessionReaper.quitArguments"),
            "quitPersistentScreenIfNeeded must ask the pure reaper for the quit arguments (nil when not live)"
        )
        XCTAssertTrue(
            body.contains("liveScreenSessionNames"),
            "the quit helper must read the cached live-session set (no second screen -ls probe)"
        )
        XCTAssertTrue(
            body.contains("spawnScreenQuit"),
            "the quit helper must spawn via the shared spawnScreenQuit (off-main + watchdog), not a bespoke spawn"
        )
    }

    func testSharedSpawnHelperExists() throws {
        let source = try appSource()
        XCTAssertTrue(
            source.contains("func spawnScreenQuit"),
            "a shared spawnScreenQuit must factor the off-main + 1.5s watchdog so it isn't copy-pasted"
        )
        let spawn = try sourceSlice(
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
        let body = try sourceSlice(
            in: try appSource(),
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
        let body = try sourceSlice(
            in: try appSource(),
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
        let source = try appSource()
        // The startup task: order is load (in init) → refreshLiveScreenSessions
        // → reapOrphanedScreenSessions. Pin that the reaper call sits AFTER the
        // live-session refresh so the cache is populated when it runs.
        let startup = try sourceSlice(
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
        let load = try sourceSlice(
            in: try appSource(),
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
        try sourceSlice(
            in: try appSource(),
            from: "func quitPersistentScreenIfNeeded",
            to: "\n    func "
        )
    }

    private func reaper() throws -> String {
        try sourceSlice(
            in: try appSource(),
            from: "func reapOrphanedScreenSessions",
            to: "\n    func "
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
