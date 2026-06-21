import XCTest
@testable import OuroWorkbenchCore

/// The terminals-first empty-state copy lives in Core so the headline / subtext that carry the
/// subtractive-FRE message ("Your terminals. An agent runs them.") are pinned by tests rather
/// than buried as App-target view literals. The App view renders these verbatim.
final class AgentHomeEmptyStateCopyTests: XCTestCase {
    func testHeadlineLeadsWithPurpose() {
        XCTAssertEqual(
            AgentHomeEmptyStateCopy.headline,
            "Your terminals. An agent runs them."
        )
    }

    func testSubtextFramesTheBossAsOptional() {
        XCTAssertEqual(
            AgentHomeEmptyStateCopy.subtext,
            "Your terminal agents stay real terminals — open one and go. When you "
                + "want a boss watching the whole Mac and keeping work moving, set one up. No setup "
                + "required to start."
        )
    }

    func testButtonTitlesMatchTheNewHierarchy() {
        // Primary first, boss opt-in second, create-agent lowest weight.
        XCTAssertEqual(AgentHomeEmptyStateCopy.newTerminalButton, "New Terminal")
        XCTAssertEqual(AgentHomeEmptyStateCopy.setUpBossButton, "Set up a boss")
        // U18: the create action leads with plain language a newcomer can parse — no
        // undefined "hatch"/"bundle" as the only words.
        XCTAssertEqual(AgentHomeEmptyStateCopy.createAgentButton, "Create an Agent")
    }

    func testCreateAgentHelpGlossesHatchInPlainLanguage() {
        // U18: a one-line "why" that glosses the Ouro "hatch" flavor on first encounter,
        // so the lowest-weight action is still legible to someone who's never used Ouro.
        XCTAssertEqual(
            AgentHomeEmptyStateCopy.createAgentHelp,
            "Create a new Ouro agent (\u{201C}hatch\u{201D}) — name it, pick a provider, and add credentials."
        )
    }
}
