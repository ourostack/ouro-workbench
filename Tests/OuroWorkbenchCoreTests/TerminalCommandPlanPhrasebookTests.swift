import XCTest
@testable import OuroWorkbenchCore

/// U40: every `TerminalCommandPlanKind` maps to ONE plain operator-facing
/// sentence with no internal jargon. The planner's raw `reason` ("respawn X from
/// persisted workbench context", "prepare X command for manual review") is precise
/// but technical; shown verbatim in the session status line and the boss prompt it
/// reads as debug jargon. This phrasebook is the single place the kind → sentence
/// vocabulary lives, while the raw reason stays available for logs / disclosure —
/// the same shape `RecoveryReasonPhrasebook` established for `RecoveryAction`.
final class TerminalCommandPlanPhrasebookTests: XCTestCase {
    private let book = TerminalCommandPlanPhrasebook()

    func testLaunchReadsPlainly() {
        XCTAssertEqual(book.operatorSentence(for: .launch, entryName: "Codex"), "Started Codex.")
    }

    func testReattachReadsAsReconnect() {
        XCTAssertEqual(book.operatorSentence(for: .reattach, entryName: "Codex"), "Reconnected to Codex.")
    }

    func testResumeReadsAsResume() {
        XCTAssertEqual(book.operatorSentence(for: .resume, entryName: "Codex"), "Resumed Codex.")
    }

    func testRespawnReadsAsReopen() {
        XCTAssertEqual(book.operatorSentence(for: .respawn, entryName: "Codex"), "Reopened Codex from its last checkpoint.")
    }

    func testManualReviewReadsPlainly() {
        XCTAssertEqual(book.operatorSentence(for: .manualReview, entryName: "Codex"), "Opened Codex for you to review.")
    }

    /// Total over every kind — no case may fall through to a raw reason. Adding a
    /// new `TerminalCommandPlanKind` without a sentence here must fail to compile,
    /// so this exhaustiveness is enforced by the switch, not just by this list.
    func testEverySentenceNamesTheEntryAndAvoidsJargon() {
        let banned = [
            "respawn", "persisted", "workbench context", "manual review",
            "checkpoint recovery prompt", "native session metadata",
            "latest-session fallback", "prepare", "configured",
        ]
        for kind in TerminalCommandPlanKind.allCases {
            let sentence = book.operatorSentence(for: kind, entryName: "Aria")
            XCTAssertTrue(sentence.contains("Aria"), "\(kind) sentence dropped the entry name: \(sentence)")
            let lowered = sentence.lowercased()
            for term in banned {
                XCTAssertFalse(
                    lowered.contains(term.lowercased()),
                    "operatorSentence(for: \(kind)) leaked jargon \"\(term)\": \(sentence)"
                )
            }
        }
    }
}
