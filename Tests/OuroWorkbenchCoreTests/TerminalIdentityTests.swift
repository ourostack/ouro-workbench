import XCTest
@testable import OuroWorkbenchCore

final class TerminalIdentityTests: XCTestCase {
    func testParserHandlesQuotedArguments() {
        let parsed = TerminalCommandParser.parse("claude --model 'opus 4' \"two words\"")

        XCTAssertEqual(parsed?.executable, "claude")
        XCTAssertEqual(parsed?.arguments, ["--model", "opus 4", "two words"])
    }

    func testParserPreservesEmptyQuotedArguments() {
        let parsed = TerminalCommandParser.parse("claude --flag '' \"\" tail")

        XCTAssertEqual(parsed?.executable, "claude")
        XCTAssertEqual(parsed?.arguments, ["--flag", "", "", "tail"])
    }

    func testDetectsKnownCLIsFromExecutableAndArguments() {
        XCTAssertEqual(TerminalAgentDetector.detect(executable: "claude", arguments: []), .claudeCode)
        XCTAssertEqual(TerminalAgentDetector.detect(executable: "/opt/homebrew/bin/codex", arguments: ["--yolo"]), .openAICodex)
        XCTAssertEqual(TerminalAgentDetector.detect(executable: "gh", arguments: ["copilot", "--", "--yolo"]), .githubCopilotCLI)
        XCTAssertNil(TerminalAgentDetector.detect(executable: "gh", arguments: ["issue", "list"]))
    }

    func testDetectsKnownCLIFromShellWrappedCommand() {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Wrapped Codex",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            arguments: ["-lc", "codex --yolo"],
            workingDirectory: "/repo"
        )

        XCTAssertEqual(TerminalAgentDetector.detect(entry: entry), .openAICodex)
    }

    func testCanonicalTokensUnwrapShellEnvAndExec() {
        let shellWrapped = TerminalAgentDetector.canonicalTokens(
            executable: "/bin/zsh",
            arguments: ["-lc", "exec env PATH=/custom/bin:$PATH claude --dangerously-skip-permissions"]
        )

        XCTAssertEqual(shellWrapped.executable, "claude")
        XCTAssertEqual(shellWrapped.arguments, ["--dangerously-skip-permissions"])
        XCTAssertEqual(TerminalAgentDetector.detect(executable: "/usr/bin/env", arguments: ["gh", "copilot"]), .githubCopilotCLI)
    }

    func testCanonicalTokensUnwrapLeadingEnvironmentAssignments() {
        let shellWrapped = TerminalAgentDetector.canonicalTokens(
            executable: "/bin/zsh",
            arguments: ["-lc", "ANTHROPIC_MODEL=opus claude --dangerously-skip-permissions"]
        )

        XCTAssertEqual(shellWrapped.executable, "claude")
        XCTAssertEqual(shellWrapped.arguments, ["--dangerously-skip-permissions"])
        XCTAssertEqual(TerminalAgentDetector.detect(executable: shellWrapped.executable, arguments: shellWrapped.arguments), .claudeCode)
    }
}
