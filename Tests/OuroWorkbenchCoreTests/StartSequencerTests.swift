import XCTest
@testable import OuroWorkbenchCore

/// F11a Defect 2 — the pure decision seam for sequencing a (re)start of an
/// entry that may already have a live local session on its `screen` socket.
///
/// When a session is already active on the socket, the old fire-and-forget
/// `screen -X quit` raced the immediate `screen -D -RR` relaunch — the reattach
/// got yanked mid-attach or `-RR` forked a fresh daemon and lost scrollback. The
/// sequencer makes that an explicit, typed step: quit-then-await before
/// relaunching when a session is live, or launch immediately when nothing is on
/// the socket.
final class StartSequencerTests: XCTestCase {
    func testActiveSessionYieldsQuitThenAwaitWithTheEntrysSessionName() {
        let entryId = UUID()
        let step = StartSequencer().step(
            forEntryId: entryId,
            hasActiveSessionOnSocket: true
        )
        XCTAssertEqual(
            step,
            .quitThenAwait(sessionName: PersistentTerminalSession.sessionName(for: entryId))
        )
    }

    func testNoActiveSessionYieldsLaunchImmediately() {
        let step = StartSequencer().step(
            forEntryId: UUID(),
            hasActiveSessionOnSocket: false
        )
        XCTAssertEqual(step, .launchImmediately)
    }

    func testQuitThenAwaitSessionNameRoundTripsToSessionNameFor() {
        let entryId = UUID()
        guard case let .quitThenAwait(sessionName) = StartSequencer().step(
            forEntryId: entryId,
            hasActiveSessionOnSocket: true
        ) else {
            return XCTFail("expected .quitThenAwait for an active session")
        }
        XCTAssertEqual(sessionName, PersistentTerminalSession.sessionName(for: entryId))
    }
}
