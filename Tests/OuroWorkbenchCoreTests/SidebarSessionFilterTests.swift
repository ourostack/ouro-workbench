import XCTest
@testable import OuroWorkbenchCore

final class SidebarSessionFilterTests: XCTestCase {
    private let filter = SidebarSessionFilter()

    private func matches(
        name: String = "session",
        group: String = "group",
        owner: SessionOwner = .human,
        attention: AttentionState = .idle,
        query: String
    ) -> Bool {
        filter.matches(name: name, groupName: group, owner: owner, attention: attention, query: query)
    }

    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(matches(name: "anything", group: "whatever", query: ""))
        XCTAssertTrue(matches(name: "anything", group: "whatever", query: "   "))
        XCTAssertTrue(matches(name: "anything", group: "whatever", owner: .agent(name: "slugger"), query: "\n\t "))
    }

    func testSubstringMatchesNameCaseInsensitively() {
        XCTAssertTrue(matches(name: "Recipe Importer", group: "spoonjoy", query: "recipe"))
        XCTAssertTrue(matches(name: "Recipe Importer", group: "spoonjoy", query: "IMPORT"))
        XCTAssertFalse(matches(name: "Recipe Importer", group: "spoonjoy", query: "nginx"))
    }

    func testSubstringMatchesGroupName() {
        XCTAssertTrue(matches(name: "build", group: "Spoonjoy API", query: "spoonjoy"))
        XCTAssertTrue(matches(name: "build", group: "Spoonjoy API", query: "api"))
        // A token matching neither the name nor the group hides the row.
        XCTAssertFalse(matches(name: "build", group: "Spoonjoy API", query: "deploy"))
    }

    func testAllTokensMustMatch() {
        // "spoon" matches the group, "build" matches the name — both present.
        XCTAssertTrue(matches(name: "build", group: "spoonjoy", query: "spoon build"))
        // "build" matches but "missing" matches nothing → overall no match.
        XCTAssertFalse(matches(name: "build", group: "spoonjoy", query: "build missing"))
    }

    func testOwnerAgentMatchesOnlyAgentOwned() {
        XCTAssertTrue(matches(owner: .agent(name: "slugger"), query: "owner:agent"))
        XCTAssertTrue(matches(owner: .agent(name: "caretaker"), query: "owner:agent"))
        XCTAssertFalse(matches(owner: .human, query: "owner:agent"))
    }

    func testOwnerHumanMatchesOnlyHuman() {
        XCTAssertTrue(matches(owner: .human, query: "owner:human"))
        XCTAssertTrue(matches(owner: .human, query: "owner:you"))
        XCTAssertFalse(matches(owner: .agent(name: "slugger"), query: "owner:human"))
        XCTAssertFalse(matches(owner: .agent(name: "slugger"), query: "owner:you"))
    }

    func testOwnerByNameMatchesThatAgent() {
        XCTAssertTrue(matches(owner: .agent(name: "slugger"), query: "owner:slugger"))
        // Substring of the agent name still matches.
        XCTAssertTrue(matches(owner: .agent(name: "slugger"), query: "owner:slug"))
        // A different agent does not match.
        XCTAssertFalse(matches(owner: .agent(name: "caretaker"), query: "owner:slugger"))
        // Human is never matched by an agent-name token.
        XCTAssertFalse(matches(owner: .human, query: "owner:slugger"))
    }

    func testOwnerTokenIsCaseInsensitive() {
        XCTAssertTrue(matches(owner: .agent(name: "Slugger"), query: "OWNER:slugger"))
        XCTAssertTrue(matches(owner: .agent(name: "Slugger"), query: "owner:SLUG"))
        XCTAssertTrue(matches(owner: .human, query: "Owner:Human"))
    }

    func testStatusTokenMatchesAttention() {
        XCTAssertTrue(matches(attention: .waitingOnHuman, query: "status:waiting"))
        XCTAssertTrue(matches(attention: .active, query: "status:active"))
        XCTAssertTrue(matches(attention: .blocked, query: "status:blocked"))
        XCTAssertTrue(matches(attention: .needsBossReview, query: "status:review"))
        XCTAssertTrue(matches(attention: .idle, query: "status:idle"))
        // Raw state name also works.
        XCTAssertTrue(matches(attention: .waitingOnHuman, query: "status:waitingOnHuman"))
        XCTAssertFalse(matches(attention: .idle, query: "status:waiting"))
    }

    func testStatusAttentionAliasMatchesAnyNeedsHumanState() {
        XCTAssertTrue(matches(attention: .waitingOnHuman, query: "status:attention"))
        XCTAssertTrue(matches(attention: .blocked, query: "status:attention"))
        XCTAssertTrue(matches(attention: .needsBossReview, query: "status:attention"))
        XCTAssertFalse(matches(attention: .idle, query: "status:attention"))
        XCTAssertFalse(matches(attention: .active, query: "status:attention"))
    }

    func testUnknownStatusValueFallsBackToRawAttentionStateSubstring() {
        XCTAssertTrue(matches(attention: .waitingOnHuman, query: "status:uman"))
        XCTAssertFalse(matches(attention: .idle, query: "status:uman"))
    }

    func testTokensCombineAcrossDimensions() {
        // Agent-owned AND waiting AND name contains "recipe".
        XCTAssertTrue(matches(
            name: "Recipe Importer",
            group: "spoonjoy",
            owner: .agent(name: "slugger"),
            attention: .waitingOnHuman,
            query: "recipe owner:agent status:waiting"
        ))
        // Same row, but require a human owner → no match.
        XCTAssertFalse(matches(
            name: "Recipe Importer",
            group: "spoonjoy",
            owner: .agent(name: "slugger"),
            attention: .waitingOnHuman,
            query: "recipe owner:human"
        ))
    }

    func testBareOwnerOrStatusTokenIsNeutral() {
        // A half-typed "owner:" / "status:" (nothing after the colon yet)
        // shouldn't blank the list — it matches everything until the operator
        // types the value.
        XCTAssertTrue(matches(name: "session", group: "g", owner: .human, query: "owner:"))
        XCTAssertTrue(matches(name: "session", group: "g", owner: .agent(name: "slugger"), query: "owner:"))
        XCTAssertTrue(matches(name: "session", group: "g", attention: .idle, query: "status:"))
        // It still ANDs with other tokens: bare owner: is neutral, but a
        // non-matching plain token still hides the row.
        XCTAssertFalse(matches(name: "session", group: "g", query: "owner: nomatch"))
    }

    func testConvenienceOverloadReadsProcessEntryFields() {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Recipe Importer",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            workingDirectory: "/tmp",
            attention: .waitingOnHuman,
            owner: .agent(name: "slugger")
        )
        XCTAssertTrue(filter.matches(entry, groupName: "spoonjoy", query: "owner:slugger status:waiting"))
        XCTAssertTrue(filter.matches(entry, groupName: "spoonjoy", query: "spoonjoy"))
        XCTAssertFalse(filter.matches(entry, groupName: "spoonjoy", query: "owner:human"))
    }
}
