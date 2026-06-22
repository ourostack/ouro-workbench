import XCTest
@testable import OuroWorkbenchCore

/// F11a Defect 2 — durable wiring assertions for the start-race fix. The pure
/// `StartSequencer` seam is unit-tested + 100% covered in Core; the App that
/// invokes it isn't coverage-gated and can't be click-tested in CI, so we
/// source-pin its structural wiring the same way `SessionIdBackfillWiringTests`
/// (F4) does.
///
/// The risks these pins defend:
///   - `start(_:with:)` must consult `StartSequencer` and, when a session is
///     live on the socket, AWAIT the `screen -X quit` to completion BEFORE the
///     `session.start()` that launches `screen -D -RR` — otherwise the old
///     fire-and-forget quit races the relaunch (reattach yanked mid-attach / -RR
///     forks a fresh daemon, losing scrollback);
///   - the awaiting quit (`terminatePersistentSessionAwaiting`) must wrap the
///     spawn in `withCheckedContinuation` and resume from BOTH the process
///     `terminationHandler` AND the 1.5s watchdog — resuming from only one site
///     risks a permanent hang (a wedged socket never terminates) and resuming
///     from both without a SINGLE-SHOT guard crashes (a checked continuation
///     resumed twice traps);
///   - app-exit and the standalone Stop path (`terminate(_ entry:)`) must keep
///     using the NON-awaiting `terminate()` — switching them to await would
///     serialize many quits on the main actor and jank/hang exit.
final class StartSequenceAwaitWiringTests: XCTestCase {
    // MARK: start(_:with:) is async + consults the sequencer + awaits before launch

    func testStartIsAsync() throws {
        let source = try appSource()
        XCTAssertTrue(
            source.contains("private func start(_ entry: ProcessEntry, with plan: TerminalCommandPlan) async"),
            "start(_:with:) must be async so it can await the quit before relaunching"
        )
    }

    func testStartConsultsTheStartSequencer() throws {
        let body = try startMethod()
        XCTAssertTrue(
            body.contains("StartSequencer()") && body.contains(".step("),
            "start must consult the pure StartSequencer for the typed step"
        )
        XCTAssertTrue(
            body.contains("hasActiveSessionOnSocket:"),
            "start must pass whether a session is live on the socket to the sequencer"
        )
    }

    func testStartAwaitsTheAwaitingQuitBeforeSessionStart() throws {
        let body = try startMethod()
        let awaitIndex = try XCTUnwrap(
            body.range(of: "terminatePersistentSessionAwaiting")?.lowerBound,
            "start must await the awaiting-quit when a session is live on the socket"
        )
        XCTAssertTrue(
            body.contains("await") ,
            "the awaiting-quit must be awaited"
        )
        let launchIndex = try XCTUnwrap(
            body.range(of: "session.start()")?.lowerBound,
            "start must launch the new session"
        )
        XCTAssertLessThan(
            awaitIndex, launchIndex,
            "the quit MUST be awaited BEFORE session.start() (the -D -RR relaunch) so it never races the quit"
        )
    }

    func testStartOnlyAwaitsOnTheQuitThenAwaitArm() throws {
        let body = try startMethod()
        XCTAssertTrue(
            body.contains("quitThenAwait") && body.contains("launchImmediately"),
            "start must branch on both StartSequenceStep arms (await only when a live session must be quit first)"
        )
    }

    // MARK: terminatePersistentSessionAwaiting — single-shot continuation

    func testAwaitingQuitUsesCheckedContinuation() throws {
        let body = try awaitingQuit()
        XCTAssertTrue(
            body.contains("withCheckedContinuation"),
            "the awaiting quit must bridge the spawn to async via withCheckedContinuation"
        )
    }

    func testAwaitingQuitResumesFromBothTerminationHandlerAndWatchdog() throws {
        let body = try awaitingQuit()
        XCTAssertTrue(
            body.contains("terminationHandler"),
            "the continuation must be resumable from the process terminationHandler (quit finished)"
        )
        XCTAssertTrue(
            body.contains("1500") || body.contains("asyncAfter"),
            "the continuation must ALSO be resumable from a 1.5s watchdog (a wedged socket never terminates → must not hang the launch forever)"
        )
    }

    func testAwaitingQuitHasSingleShotResumeGuard() throws {
        let body = try awaitingQuit()
        // A checked continuation resumed twice traps; resumed zero times hangs.
        // The resume must be funneled through a single-shot guard so the
        // terminationHandler and the watchdog can't both resume it — the awaiting
        // quit wraps the continuation in a SingleShotContinuation gate and both
        // racing sites call gate.resume().
        XCTAssertTrue(
            body.contains("SingleShotContinuation"),
            "the continuation must be wrapped in a single-shot gate so the two racing resume sites can't double-resume it"
        )
        XCTAssertTrue(
            body.contains(".resume()"),
            "both the terminationHandler and the watchdog must funnel through the single-shot gate's resume()"
        )
        // And the single-shot gate itself must be backed by a real atomic guard
        // (a lock making the check-and-set across the two background closures
        // atomic), not a bare bool that could still race.
        let gate = try sourceSlice(
            in: try appSource(),
            from: "private final class SingleShotContinuation",
            to: "\n@MainActor\nfinal class TerminalSessionController"
        )
        let guarded = gate.contains("os_unfair_lock")
            || gate.contains("OSAllocatedUnfairLock")
            || gate.contains("NSLock")
        XCTAssertTrue(
            guarded,
            "the single-shot gate must use a lock so terminationHandler + watchdog resume the continuation EXACTLY once (double-resume crashes, zero-resume hangs)"
        )
    }

    // MARK: non-awaiting terminate() stays on app-exit / standalone Stop

    func testStandaloneTerminateStaysNonAwaiting() throws {
        // The VM-level Stop path: terminate(_ entry:) must call the controller's
        // NON-awaiting terminate(), never the awaiting variant (blocking the main
        // actor on every Stop would jank the UI).
        let body = try sourceSlice(
            in: try appSource(),
            from: "func terminate(_ entry: ProcessEntry) {",
            to: "\n    /// Terminate every currently-running session."
        )
        XCTAssertTrue(
            body.contains("session.terminate()"),
            "the standalone Stop path must use the non-awaiting session.terminate()"
        )
        XCTAssertFalse(
            body.contains("terminatePersistentSessionAwaiting"),
            "the standalone Stop path must NOT await (would serialize quits on the main actor)"
        )
    }

    func testControllerKeepsNonAwaitingTerminate() throws {
        let source = try appSource()
        // The fire-and-forget terminate() the controller exposes for app-exit /
        // standalone Stop must remain.
        let controllerTerminate = try sourceSlice(
            in: source,
            from: "    func terminate() {",
            to: "\n    private func terminatePersistentSessionIfNeeded"
        )
        XCTAssertTrue(
            controllerTerminate.contains("terminatePersistentSessionIfNeeded()"),
            "the controller's non-awaiting terminate() must stay (used by app-exit + standalone Stop)"
        )
    }

    // MARK: launch / recover route through await start

    func testLaunchRoutesThroughAwaitStart() throws {
        let body = try sourceSlice(
            in: try appSource(),
            from: "func launch(_ entry: ProcessEntry) {",
            to: "\n    func focusTerminal"
        )
        XCTAssertTrue(
            body.contains("await start(entry, with: plan)"),
            "launch must route the start through `await start(...)` now that start is async"
        )
    }

    func testRecoverRoutesThroughAwaitStart() throws {
        let body = try sourceSlice(
            in: try appSource(),
            from: "private func recover(_ entry: ProcessEntry, recoveryPlan: RecoveryPlan) {",
            to: "\n    private func applyBossAction"
        )
        XCTAssertTrue(
            body.contains("await start(entry, with: plan)"),
            "recover must route the start through `await start(...)` now that start is async"
        )
    }

    // MARK: - Helpers

    private func startMethod() throws -> String {
        try sourceSlice(
            in: try appSource(),
            from: "private func start(_ entry: ProcessEntry, with plan: TerminalCommandPlan) async",
            to: "\n    func markStarted(plan: TerminalCommandPlan"
        )
    }

    private func awaitingQuit() throws -> String {
        try sourceSlice(
            in: try appSource(),
            from: "func terminatePersistentSessionAwaiting() async",
            to: "\n    private func recordOutput"
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
