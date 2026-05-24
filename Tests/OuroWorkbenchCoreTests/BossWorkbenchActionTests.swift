import XCTest
@testable import OuroWorkbenchCore

final class BossWorkbenchActionTests: XCTestCase {
    func testParsesFencedBossActions() throws {
        let reply = """
        I will move Codex forward now.

        ```ouro-workbench-actions
        [
          { "action": "recover", "entry": "OpenAI Codex" },
          { "action": "sendInput", "entry": "Claude Code", "text": "continue", "appendNewline": true }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(action: .recover, entry: "OpenAI Codex"),
            BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "continue", appendNewline: true),
        ])
    }

    func testNoActionBlockReturnsEmptyList() throws {
        XCTAssertEqual(try BossWorkbenchActionParser().parse("No action needed."), [])
    }

    func testSendInputRequiresNonEmptyTextBeforeQueueing() {
        let action = BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "   ")

        XCTAssertThrowsError(try action.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingTextForSendInput)
        }
    }

    func testNonInputActionsDoNotRequireTextBeforeQueueing() throws {
        let action = BossWorkbenchAction(action: .launch, entry: "Claude Code")

        XCTAssertNoThrow(try action.validateForQueueing())
    }
}
