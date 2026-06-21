import XCTest
@testable import OuroWorkbenchCore

/// U23(a): the operator-facing Decision Log shows plain language, not raw
/// developer telemetry. The footer used to print "status: <rawValue>" (the
/// boss-side lifecycle enum) and "source: <actor id like boss:slugger>", and the
/// Teach button's polarity silently inverted by kind. This phrasebook is the
/// single pure place that vocabulary lives so the log row and any other surface
/// agree, while the raw value stays available for a power-user disclosure.
final class DecisionLogPhrasebookTests: XCTestCase {
    private let book = DecisionLogPhrasebook()

    // MARK: - Status → plain words

    func testRecordedReadsAsLoggedNotSent() {
        XCTAssertEqual(book.statusPhrase(.recorded), "Logged (not sent)")
    }

    func testAppliedReadsAsHandled() {
        XCTAssertEqual(book.statusPhrase(.applied), "Sent")
    }

    func testOverriddenReadsAsCorrected() {
        XCTAssertEqual(book.statusPhrase(.overridden), "You corrected it")
    }

    // MARK: - Source actor id → "decided by"

    func testBossActorReadsAsBossWatch() {
        XCTAssertEqual(book.decidedBy(source: "boss:slugger"), "Boss Watch")
    }

    func testBossActorIsCaseAndWhitespaceInsensitive() {
        XCTAssertEqual(book.decidedBy(source: "  Boss:Slugger "), "Boss Watch")
    }

    func testNonBossSourceFallsBackToTheBareName() {
        // An operator-driven entry (no boss: prefix) names the actor plainly,
        // never a raw colon-delimited id.
        XCTAssertEqual(book.decidedBy(source: "operator"), "operator")
    }

    func testEmptySourceReadsAsUnknown() {
        XCTAssertEqual(book.decidedBy(source: "   "), "Unknown")
    }

    // MARK: - Teach control presents both intents explicitly

    func testTeachOptionsAlwaysOfferBothIntentsRegardlessOfKind() {
        // The segmented control offers the SAME two explicit choices for every
        // kind — the operator never has to decode which one reinforces.
        for kind in BossDecisionKind.allCases {
            let options = book.teachOptions(for: kind)
            XCTAssertEqual(options.map(\.title), ["Do this automatically next time", "Always ask me"])
            // The "automatic" option reinforces (auto-advance == true); "ask me"
            // corrects (auto-advance == false). Stable mapping, kind-independent.
            XCTAssertEqual(options[0].reinforces, true)
            XCTAssertEqual(options[1].reinforces, false)
        }
    }

    func testTeachOptionIdentityIsItsReinforcePolarity() {
        // The two options are distinguished by `reinforces`, which is also their
        // Identifiable id — so a ForEach renders exactly two stable rows.
        let options = book.teachOptions(for: .escalate)
        XCTAssertEqual(options.map(\.id), [true, false])
    }

    func testTeachOptionMarksTheCurrentDefaultForTheKind() {
        // For an auto-advance decision, "do automatically" is already what the
        // boss did — mark it as current so the operator sees which is in effect.
        let auto = book.teachOptions(for: .autoAdvance)
        XCTAssertEqual(auto.first(where: \.isCurrent)?.title, "Do this automatically next time")
        // For an escalate/hold, the boss asked — "always ask me" is current.
        for kind in [BossDecisionKind.escalate, .hold] {
            let opts = book.teachOptions(for: kind)
            XCTAssertEqual(opts.first(where: \.isCurrent)?.title, "Always ask me")
        }
    }
}
