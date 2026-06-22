import XCTest
@testable import OuroWorkbenchCore

/// F11a Defect 1 — pure reaper that decides which live `screen` sessions are
/// orphans (no known workbench entry hashes to them) and the quit arguments for
/// a single entry's session.
///
/// The CRITICAL arm is the no-kill one: a live session whose name is the forward
/// hash of a KNOWN entry id must NEVER be returned as an orphan — that's the
/// F8-class "kill the wrong thing" defect. Derivation is FORWARD only (hash each
/// known id to a name and subtract), never parsing a uuid back out of a name.
final class ScreenSessionReaperTests: XCTestCase {
    func testOrphanSessionWithNoKnownEntryIsReturned() {
        let orphanId = UUID()
        let orphanName = PersistentTerminalSession.sessionName(for: orphanId)
        let orphans = ScreenSessionReaper.orphanedSessionNames(
            liveSessionNames: [orphanName],
            knownEntryIds: []
        )
        XCTAssertEqual(orphans, [orphanName])
    }

    func testKnownEntrysLiveSessionIsNeverReturned() {
        // The no-kill arm: a known id's session is a reattachable survivor.
        let knownId = UUID()
        let knownName = PersistentTerminalSession.sessionName(for: knownId)
        let orphans = ScreenSessionReaper.orphanedSessionNames(
            liveSessionNames: [knownName],
            knownEntryIds: [knownId]
        )
        XCTAssertTrue(orphans.isEmpty, "a session a known id hashes to must be spared")
    }

    func testEmptyLiveSessionsYieldsEmpty() {
        let orphans = ScreenSessionReaper.orphanedSessionNames(
            liveSessionNames: [],
            knownEntryIds: [UUID(), UUID()]
        )
        XCTAssertTrue(orphans.isEmpty)
    }

    func testKnownEntriesWithNoLiveSessionsYieldsEmpty() {
        let orphans = ScreenSessionReaper.orphanedSessionNames(
            liveSessionNames: [],
            knownEntryIds: [UUID()]
        )
        XCTAssertTrue(orphans.isEmpty)
    }

    func testMixedTwoLiveOneKnownReturnsOnlyTheUnknown() {
        let knownId = UUID()
        let knownName = PersistentTerminalSession.sessionName(for: knownId)
        let orphanId = UUID()
        let orphanName = PersistentTerminalSession.sessionName(for: orphanId)
        let orphans = ScreenSessionReaper.orphanedSessionNames(
            liveSessionNames: [knownName, orphanName],
            knownEntryIds: [knownId]
        )
        XCTAssertEqual(orphans, [orphanName])
    }

    func testQuitArgumentsForLiveEntryReturnsTerminateArguments() {
        let entryId = UUID()
        let name = PersistentTerminalSession.sessionName(for: entryId)
        let args = ScreenSessionReaper.quitArguments(
            forEntryId: entryId,
            liveSessionNames: [name]
        )
        XCTAssertEqual(args, PersistentTerminalSession.terminateArguments(sessionName: name))
    }

    func testQuitArgumentsForEntryNotLiveReturnsNil() {
        // Avoid a "No screen session found" by not issuing a quit for a dead one.
        let entryId = UUID()
        let args = ScreenSessionReaper.quitArguments(
            forEntryId: entryId,
            liveSessionNames: [PersistentTerminalSession.sessionName(for: UUID())]
        )
        XCTAssertNil(args)
    }

    func testForwardDerivationMatchesSessionNameForId() {
        // Round-trip guard: the reaper's spare-set must be derived from the SAME
        // forward hash the rest of the app uses, so a known id always shields its
        // own session.
        let id = UUID()
        let name = PersistentTerminalSession.sessionName(for: id)
        let orphans = ScreenSessionReaper.orphanedSessionNames(
            liveSessionNames: [name],
            knownEntryIds: [id]
        )
        XCTAssertTrue(orphans.isEmpty)
        XCTAssertNotNil(
            ScreenSessionReaper.quitArguments(forEntryId: id, liveSessionNames: [name])
        )
    }
}
