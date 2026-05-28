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

    func testMalformedActionInBatchIsSkippedNotFatal() throws {
        // The middle action has an unknown `action` kind a newer boss might
        // emit. It should be skipped, the two valid actions still applied —
        // rather than the whole batch being discarded.
        let reply = """
        ```ouro-workbench-actions
        [
          { "action": "recover", "entry": "OpenAI Codex" },
          { "action": "teleport", "entry": "Nowhere" },
          { "action": "sendInput", "entry": "Claude Code", "text": "go", "appendNewline": true }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(action: .recover, entry: "OpenAI Codex"),
            BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "go", appendNewline: true),
        ])
    }

    func testNonArrayActionPayloadStillThrows() {
        // A payload that isn't an array at all should surface as a parse
        // error, not silently return empty.
        let reply = """
        ```ouro-workbench-actions
        { "action": "recover" }
        ```
        """
        XCTAssertThrowsError(try BossWorkbenchActionParser().parse(reply))
    }

    func testSendInputRequiresNonEmptyTextBeforeQueueing() {
        let action = BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "   ")

        XCTAssertThrowsError(try action.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingTextForSendInput)
        }
    }

    func testEntryScopedActionsRequireEntryBeforeQueueing() {
        let action = BossWorkbenchAction(action: .launch)

        XCTAssertThrowsError(try action.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingEntry(.launch))
        }
    }

    func testCreateTerminalRequiresNameAndCommandBeforeQueueing() {
        let missingName = BossWorkbenchAction(action: .createTerminal, command: "codex --yolo")
        let missingCommand = BossWorkbenchAction(action: .createTerminal, name: "Codex")

        XCTAssertThrowsError(try missingName.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingName(.createTerminal))
        }
        XCTAssertThrowsError(try missingCommand.validateForQueueing()) { error in
            XCTAssertEqual(error as? BossWorkbenchActionValidationError, .missingCommandForCreateTerminal)
        }
    }

    func testParsesWorkspaceManagementActions() throws {
        let reply = """
        ```ouro-workbench-actions
        [
          { "action": "createTerminal", "group": "Harness", "name": "Release Codex", "command": "codex --yolo", "workingDirectory": "/repo", "trust": "trusted", "autoResume": true },
          { "action": "moveSession", "entry": "Release Codex", "group": "Website" }
        ]
        ```
        """

        let actions = try BossWorkbenchActionParser().parse(reply)

        XCTAssertEqual(actions, [
            BossWorkbenchAction(
                action: .createTerminal,
                group: "Harness",
                name: "Release Codex",
                command: "codex --yolo",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            ),
            BossWorkbenchAction(action: .moveSession, entry: "Release Codex", group: "Website"),
        ])
    }

    func testNonInputActionsDoNotRequireTextBeforeQueueing() throws {
        let action = BossWorkbenchAction(action: .launch, entry: "Claude Code")

        XCTAssertNoThrow(try action.validateForQueueing())
    }
}
