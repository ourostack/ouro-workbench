import XCTest
@testable import OuroWorkbenchCore

/// F12a Gap 5 — how the checkpoint recovery prompt is delivered on a respawn.
///
/// The planner used to append the checkpoint prompt as the LAST positional argv
/// token. Copilot's launch (`gh copilot -- --yolo "<prompt>"`) ignores anything
/// after `--`, so the TUI opened with no recovery context — the "Copilot dead-ends
/// despite CLI flags" symptom. This resolver decides, per agent kind, whether the
/// prompt is delivered positionally (generic argv-reading TUIs) or typed AFTER the
/// TUI is interactive (Copilot).
final class CheckpointPromptDeliveryResolverTests: XCTestCase {
    private let resolver = CheckpointPromptDeliveryResolver()

    func testCopilotDeliversThePromptAfterLaunchNotPositionally() {
        let delivery = resolver.delivery(for: .githubCopilotCLI, prompt: "recover me")
        XCTAssertEqual(delivery, .sendAfterLaunch("recover me"))
    }

    func testGenericDetectedNilAgentKeepsThePositionalPath() {
        // A custom argv-reading TUI (detection returned nil) reads an argv prompt —
        // keep delivering it positionally so we don't regress those agents.
        let delivery = resolver.delivery(for: nil, prompt: "recover me")
        XCTAssertEqual(delivery, .positional)
    }

    func testCustomKindKeepsThePositionalPath() {
        let delivery = resolver.delivery(for: .custom, prompt: "recover me")
        XCTAssertEqual(delivery, .positional)
    }

    func testNativeResumeAgentsHaveNoCheckpointDelivery() {
        // Claude / Codex use .nativeResumeCommand on respawn, never the checkpoint
        // prompt — so the resolver returns nil (no checkpoint delivery applies).
        XCTAssertNil(resolver.delivery(for: .claudeCode, prompt: "x"))
        XCTAssertNil(resolver.delivery(for: .openAICodex, prompt: "x"))
    }
}
