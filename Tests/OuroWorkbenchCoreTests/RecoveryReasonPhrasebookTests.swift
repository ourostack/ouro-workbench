import XCTest
@testable import OuroWorkbenchCore

/// U8c / U7: every `RecoveryAction` maps to ONE operator-facing sentence with
/// no internal jargon, while the raw planner reason stays available behind a
/// disclosure. These are the pure pieces the Recovery sheet, the inactive
/// surface, and the drill rows all render.
final class RecoveryReasonPhrasebookTests: XCTestCase {
    private let book = RecoveryReasonPhrasebook()

    func testReattachReadsAsLosslessReconnect() {
        let sentence = book.operatorSentence(
            for: .reattach,
            rawReason: "session still running — reconnect the terminal"
        )
        XCTAssertEqual(sentence, "Still running — reconnecting loses nothing.")
    }

    func testAutoResumeReadsAsAutomaticContinue() {
        let sentence = book.operatorSentence(
            for: .autoResume,
            rawReason: "Claude Code can continue the most recent session in this working directory"
        )
        XCTAssertEqual(sentence, "Resumes its last conversation automatically.")
    }

    func testRespawnReadsAsCheckpointReopen() {
        let sentence = book.operatorSentence(
            for: .respawn,
            rawReason: "trusted non-agent process may be respawned by policy"
        )
        XCTAssertEqual(sentence, "Reopens from its saved checkpoint.")
    }

    func testManualActionNeededReadsAsNeedsYou() {
        let sentence = book.operatorSentence(
            for: .manualActionNeeded,
            rawReason: "Claude Code lacks a persisted session id"
        )
        XCTAssertEqual(sentence, "No resumable session — needs you to start it fresh.")
    }

    func testNoActionReadsAsNothingToRecover() {
        let sentence = book.operatorSentence(
            for: .noAction,
            rawReason: "no prior run to recover"
        )
        XCTAssertEqual(sentence, "Nothing to recover.")
    }

    /// No operator-facing sentence may leak internal jargon — across EVERY
    /// action, regardless of the raw reason handed in.
    func testNoOperatorSentenceLeaksInternalJargon() {
        let bannedPhrases = ["by policy", "persisted session id", "needsRecovery", "manualActionNeeded", "rawExitStatus"]
        let rawReasons = [
            "trusted non-agent process may be respawned by policy",
            "Claude Code lacks a persisted session id",
            "latest run status is needsRecovery",
            "latest run already requires manual action",
            "session still running — reconnect the terminal"
        ]
        for action in [RecoveryAction.reattach, .autoResume, .respawn, .manualActionNeeded, .noAction] {
            for raw in rawReasons {
                let sentence = book.operatorSentence(for: action, rawReason: raw).lowercased()
                for banned in bannedPhrases {
                    XCTAssertFalse(
                        sentence.contains(banned.lowercased()),
                        "operatorSentence(for: \(action), rawReason: \"\(raw)\") leaked \"\(banned)\""
                    )
                }
            }
        }
    }

    /// No operator-facing sentence may leak a raw `RecoveryAction` or
    /// `ProcessStatus` rawValue — the drill row, the sheet, and the inactive
    /// surface all phrase via this seam, so the enum jargon must never surface.
    func testNoOperatorSentenceLeaksRawEnumValues() {
        let rawValues = [
            RecoveryAction.reattach.rawValue,
            RecoveryAction.autoResume.rawValue,
            RecoveryAction.manualActionNeeded.rawValue,
            ProcessStatus.needsRecovery.rawValue,
            ProcessStatus.manualActionNeeded.rawValue,
            ProcessStatus.waitingForInput.rawValue
        ]
        for action in [RecoveryAction.reattach, .autoResume, .respawn, .manualActionNeeded, .noAction] {
            let sentence = book.operatorSentence(for: action, rawReason: "")
            for raw in rawValues {
                XCTAssertFalse(
                    sentence.contains(raw),
                    "operatorSentence(for: \(action)) leaked raw enum value \"\(raw)\""
                )
            }
        }
    }

    /// The raw planner reason is preserved verbatim for the on-demand disclosure
    /// / tooltip (power users can still audit the exact classification).
    func testRawReasonIsPreservedForDisclosure() {
        let raw = "trusted non-agent process may be respawned by policy"
        XCTAssertEqual(book.rawReasonForDisclosure(raw), raw)
    }
}
