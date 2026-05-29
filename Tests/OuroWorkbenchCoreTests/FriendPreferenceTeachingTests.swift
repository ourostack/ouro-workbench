import XCTest
@testable import OuroWorkbenchCore

final class FriendPreferenceTeachingTests: XCTestCase {
    private func decision(kind: BossDecisionKind, prompt: String = "Run tests? (y/N)", input: String? = "y") -> BossInboxDecision {
        BossInboxDecision(
            source: "boss:slugger",
            sessionName: "Codex",
            friendName: "Ari",
            friendId: "ari",
            prompt: prompt,
            kind: kind,
            proposedInput: input,
            reasoning: "x"
        )
    }

    func testReinforceAutoAdvanceProducesApprovalPreference() {
        let teaching = FriendPreferenceTeaching.reinforcement(for: decision(kind: .escalate), autoAdvance: true)
        XCTAssertEqual(teaching.friendName, "Ari")
        XCTAssertEqual(teaching.friendId, "ari")
        XCTAssertTrue(teaching.preference.contains("OK to auto-advance"))
        XCTAssertTrue(teaching.preference.contains("Run tests? (y/N)"))
        XCTAssertTrue(teaching.preference.contains("\"y\""), "carries the proposed answer")
    }

    func testCorrectionProducesEscalatePreference() {
        let teaching = FriendPreferenceTeaching.reinforcement(for: decision(kind: .autoAdvance), autoAdvance: false)
        XCTAssertTrue(teaching.preference.contains("do NOT auto-advance"))
        XCTAssertTrue(teaching.preference.contains("always escalate"))
    }

    func testFallsBackWhenFriendAndPromptMissing() {
        let bare = BossInboxDecision(source: "boss", prompt: "", kind: .hold, reasoning: "")
        let teaching = FriendPreferenceTeaching.reinforcement(for: bare, autoAdvance: true)
        XCTAssertEqual(teaching.friendName, "the operator")
        XCTAssertNil(teaching.friendId)
        XCTAssertTrue(teaching.preference.contains("this kind of prompt"))
    }

    func testBossDirectiveCarriesFriendAndPreferenceAndPersistInstruction() {
        let teaching = FriendPreferenceTeaching(friendName: "Ari", friendId: "ari", preference: "auto-approve test runs")
        let directive = teaching.bossDirective()
        XCTAssertTrue(directive.contains("Ari"))
        XCTAssertTrue(directive.contains("id ari"))
        XCTAssertTrue(directive.contains("auto-approve test runs"))
        XCTAssertTrue(directive.lowercased().contains("persist"))
        XCTAssertTrue(directive.lowercased().contains("notes tools"))
    }

    func testBossDirectiveOmitsIdClauseWhenAbsent() {
        let directive = FriendPreferenceTeaching(friendName: "Ari", preference: "p").bossDirective()
        XCTAssertFalse(directive.contains("(id"))
    }
}
