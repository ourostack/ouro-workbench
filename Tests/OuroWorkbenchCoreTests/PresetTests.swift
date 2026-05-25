import XCTest
@testable import OuroWorkbenchCore

final class PresetTests: XCTestCase {
    func testTerminalAgentPresetsExist() {
        let kinds = Set(TerminalAgentPresets.all.map(\.id))

        XCTAssertTrue(kinds.contains(.claudeCode))
        XCTAssertTrue(kinds.contains(.githubCopilotCLI))
        XCTAssertTrue(kinds.contains(.openAICodex))
    }

    func testTrustedYoloArgumentsAreEncodedForDetectedAgents() throws {
        let claude = try XCTUnwrap(TerminalAgentPresets.preset(for: .claudeCode))
        let copilot = try XCTUnwrap(TerminalAgentPresets.preset(for: .githubCopilotCLI))
        let codex = try XCTUnwrap(TerminalAgentPresets.preset(for: .openAICodex))

        XCTAssertTrue(claude.yoloArguments.contains("--dangerously-skip-permissions"))
        XCTAssertEqual(copilot.executable, "gh")
        XCTAssertEqual(copilot.defaultArguments, ["copilot"])
        XCTAssertEqual(copilot.yoloArguments, ["copilot", "--", "--yolo"])
        XCTAssertTrue(codex.yoloArguments.contains("--yolo"))
    }

    func testNativeResumeFallbacksAvoidManualPickerAfterRestart() throws {
        let claude = try XCTUnwrap(TerminalAgentPresets.preset(for: .claudeCode))
        let codex = try XCTUnwrap(TerminalAgentPresets.preset(for: .openAICodex))

        XCTAssertEqual(claude.resumeStrategy.fallbackCommandTemplate, ["claude", "--continue"])
        XCTAssertEqual(codex.resumeStrategy.fallbackCommandTemplate, ["codex", "resume", "--last"])
    }
}
