import XCTest
@testable import OuroWorkbenchCore

final class PromptSafetyClassifierTests: XCTestCase {
    private func assertUnsafe(_ prompt: String, input: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(PromptSafetyClassifier.classify(prompt: prompt, proposedInput: input).isSafe, prompt, file: file, line: line)
    }

    private func assertSafe(_ prompt: String, input: String? = nil, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(PromptSafetyClassifier.classify(prompt: prompt, proposedInput: input).isSafe, prompt, file: file, line: line)
    }

    func testSafeEverydayPromptsAutoAdvance() {
        assertSafe("Do you want to make this edit? ❯ 1. Yes", input: "1")
        assertSafe("Run tests? (y/N)", input: "y")
        assertSafe("Continue? ", input: "")
        assertSafe("Press enter to continue", input: "\n")
        assertSafe("Select an option:\n❯ 1. Refactor\n  2. Skip", input: "1")
    }

    func testDestructivePromptsEscalate() {
        assertUnsafe("Proceed to run `rm -rf build/`? (y/N)")
        assertUnsafe("Force-push to origin/main? This rewrites history.")
        assertUnsafe("Run `git reset --hard HEAD~5`? (y/N)")
        assertUnsafe("This will git clean -fd untracked files. Continue?")
        assertUnsafe("DROP TABLE users; proceed?")
        assertUnsafe("Permanently delete 240 records?")
    }

    func testSecretPromptsEscalate() {
        assertUnsafe("Enter passphrase for key '/Users/me/.ssh/id_ed25519': ")
        assertUnsafe("Password:")
        assertUnsafe("Paste your API key to continue:")
        assertUnsafe("Enter the 2FA code from your authenticator")
    }

    func testPrivilegeAndDeployAndFinancialEscalate() {
        assertUnsafe("Run `sudo rm /etc/hosts`?")
        assertUnsafe("Deploy to production now? (y/N)")
        assertUnsafe("Run npm publish for @ouro/cli?")
        assertUnsafe("Confirm purchase of 1 seat for $20/mo?")
    }

    func testAgreementPromptsEscalate() {
        assertUnsafe("Do you accept the terms of service? (y/n)")
        assertUnsafe("I agree to the license agreement [y/N]")
    }

    func testDangerInProposedInputAlsoEscalates() {
        // The prompt looks benign but the boss proposes a destructive answer.
        assertUnsafe("What should I run next?", input: "rm -rf /tmp/cache")
    }

    func testReasonAccompaniesUnsafe() {
        let result = PromptSafetyClassifier.classify(prompt: "Force push? ", proposedInput: nil)
        XCTAssertFalse(result.isSafe)
        XCTAssertEqual(result.reason, "force push")
    }

    // MARK: - Auto-advance gate

    private let trustedFriend = SessionFriend(id: "ari", name: "Ari", kind: .human, trust: .family)

    func testGateAllowsWhenEverythingTrustedAndSafe() {
        let gate = evaluateAutoAdvanceGate(enabled: true, sessionTrusted: true, friend: trustedFriend, prompt: "Run tests? (y/N)", proposedInput: "y")
        XCTAssertTrue(gate.allows)
    }

    func testGateBlocksWhenDisabled() {
        XCTAssertEqual(evaluateAutoAdvanceGate(enabled: false, sessionTrusted: true, friend: trustedFriend, prompt: "ok?", proposedInput: "y").blockedReason, "auto-advance disabled")
    }

    func testGateBlocksUntrustedSession() {
        XCTAssertEqual(evaluateAutoAdvanceGate(enabled: true, sessionTrusted: false, friend: trustedFriend, prompt: "ok?", proposedInput: "y").blockedReason, "session not trusted")
    }

    func testGateBlocksUntrustedFriendAndMissingFriend() {
        let acquaintance = SessionFriend(id: "x", name: "X", kind: .agent, trust: .acquaintance)
        XCTAssertEqual(evaluateAutoAdvanceGate(enabled: true, sessionTrusted: true, friend: acquaintance, prompt: "ok?", proposedInput: "y").blockedReason, "friend trust is acquaintance")
        XCTAssertEqual(evaluateAutoAdvanceGate(enabled: true, sessionTrusted: true, friend: nil, prompt: "ok?", proposedInput: "y").blockedReason, "session has no friend")
    }

    func testGateBlocksMissingInputAndUnsafePrompt() {
        XCTAssertEqual(evaluateAutoAdvanceGate(enabled: true, sessionTrusted: true, friend: trustedFriend, prompt: "ok?", proposedInput: "  ").blockedReason, "no proposed input")
        XCTAssertEqual(evaluateAutoAdvanceGate(enabled: true, sessionTrusted: true, friend: trustedFriend, prompt: "Run rm -rf build? (y/N)", proposedInput: "y").blockedReason, "unsafe prompt: destructive command")
    }
}
