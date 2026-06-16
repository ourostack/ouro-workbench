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

    func testParserReturnsNilForBlankCommandAndPreservesTrailingBackslash() {
        XCTAssertNil(TerminalCommandParser.parse("   \n\t  "))

        let parsed = TerminalCommandParser.parse("claude path\\")
        XCTAssertEqual(parsed?.executable, "claude")
        XCTAssertEqual(parsed?.arguments, ["path\\"])
    }

    func testParserAppliesMidTokenBackslashEscapes() {
        // A backslash before a non-terminal character escapes it: an escaped
        // space joins the surrounding token instead of splitting it.
        let escapedSpace = TerminalCommandParser.parse("claude a\\ b")
        XCTAssertEqual(escapedSpace?.executable, "claude")
        XCTAssertEqual(escapedSpace?.arguments, ["a b"])

        // An escaped ordinary character contributes literally to the token.
        let escapedLetter = TerminalCommandParser.parse("cl\\aude --model opus")
        XCTAssertEqual(escapedLetter?.executable, "claude")
        XCTAssertEqual(escapedLetter?.arguments, ["--model", "opus"])
    }

    func testCanonicalTokensLeaveUnparseableWrappersUntouched() {
        let shellMissingCommand = TerminalAgentDetector.canonicalTokens(executable: "sh", arguments: ["-c"])
        XCTAssertEqual(shellMissingCommand, TerminalCommandTokens(executable: "sh", arguments: ["-c"]))

        let envWithOnlyOptions = TerminalAgentDetector.canonicalTokens(executable: "env", arguments: ["-u", "PATH", "--ignore-environment"])
        XCTAssertEqual(envWithOnlyOptions, TerminalCommandTokens(executable: "env", arguments: ["-u", "PATH", "--ignore-environment"]))

        let execWithoutTarget = TerminalAgentDetector.canonicalTokens(executable: "exec", arguments: [])
        XCTAssertEqual(execWithoutTarget, TerminalCommandTokens(executable: "exec", arguments: []))
    }

    func testEnvUnwrapSkipsUnsetOptionsAndRejectsInvalidAssignments() {
        let unwrapped = TerminalAgentDetector.canonicalTokens(
            executable: "env",
            arguments: ["-u", "PATH", "--debug", "FOO_1=bar", "codex", "--yolo"]
        )
        XCTAssertEqual(unwrapped, TerminalCommandTokens(executable: "codex", arguments: ["--yolo"]))

        let invalidAssignmentIsExecutable = TerminalAgentDetector.canonicalTokens(
            executable: "env",
            arguments: ["1BAD=value", "claude"]
        )
        XCTAssertEqual(invalidAssignmentIsExecutable, TerminalCommandTokens(executable: "1BAD=value", arguments: ["claude"]))

        let invalidAssignmentCharacterIsExecutable = TerminalAgentDetector.canonicalTokens(
            executable: "env",
            arguments: ["BAD-NAME=value", "claude"]
        )
        XCTAssertEqual(invalidAssignmentCharacterIsExecutable, TerminalCommandTokens(executable: "BAD-NAME=value", arguments: ["claude"]))
    }

    func testDisplayNameHandlesNilKind() {
        XCTAssertNil(TerminalAgentDetector.displayName(for: nil))
        XCTAssertEqual(TerminalAgentDetector.displayName(for: .custom), "custom")
    }
}
