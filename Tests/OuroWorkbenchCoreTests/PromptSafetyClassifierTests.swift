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

    private func gate(
        enabled: Bool = true,
        running: Bool = true,
        waiting: Bool = true,
        trusted: Bool = true,
        friend: SessionFriend? = nil,
        prompt: String = "Run tests? (y/N)",
        input: String? = "y"
    ) -> AutoAdvanceGate {
        evaluateAutoAdvanceGate(
            enabled: enabled,
            sessionRunning: running,
            sessionWaiting: waiting,
            sessionTrusted: trusted,
            friend: friend ?? trustedFriend,
            prompt: prompt,
            proposedInput: input
        )
    }

    func testGateAllowsWhenEverythingTrustedRunningWaitingAndSafe() {
        XCTAssertTrue(gate().allows)
    }

    func testGateBlocksWhenDisabled() {
        XCTAssertEqual(gate(enabled: false).blockedReason, "auto-advance disabled")
    }

    func testGateBlocksWhenNotRunningOrNotWaiting() {
        XCTAssertEqual(gate(running: false).blockedReason, "session not running")
        XCTAssertEqual(gate(waiting: false).blockedReason, "session no longer waiting")
    }

    func testGateBlocksUntrustedSession() {
        XCTAssertEqual(gate(trusted: false).blockedReason, "session not trusted")
    }

    func testGateBlocksUntrustedFriendAndMissingFriend() {
        let acquaintance = SessionFriend(id: "x", name: "X", kind: .agent, trust: .acquaintance)
        XCTAssertEqual(gate(friend: acquaintance).blockedReason, "friend trust is acquaintance")
        XCTAssertEqual(
            evaluateAutoAdvanceGate(enabled: true, sessionRunning: true, sessionWaiting: true, sessionTrusted: true, friend: nil, prompt: "ok?", proposedInput: "y").blockedReason,
            "session has no friend"
        )
    }

    func testGateBlocksMissingInputShortPromptAndUnsafePrompt() {
        XCTAssertEqual(gate(input: "  ").blockedReason, "no proposed input")
        XCTAssertEqual(gate(prompt: "?", input: "y").blockedReason, "prompt too short to classify safely")
        XCTAssertEqual(gate(prompt: "Run rm -rf build? (y/N)").blockedReason, "unsafe prompt: destructive command")
    }

    // MARK: - Auto-advance outcome (what recordBossDecisions does)

    func testAllowedAutoAdvanceExecutesAndIsApplied() {
        let outcome = resolveAutoAdvanceOutcome(kind: .autoAdvance, gate: .allow)
        XCTAssertTrue(outcome.execute)
        XCTAssertEqual(outcome.status, .applied)
        XCTAssertEqual(outcome.reasoningNote, "")
    }

    func testBlockedAutoAdvanceRecordsWithReasonAndDoesNotExecute() {
        let outcome = resolveAutoAdvanceOutcome(kind: .autoAdvance, gate: .block("session not trusted"))
        XCTAssertFalse(outcome.execute)
        XCTAssertEqual(outcome.status, .recorded)
        XCTAssertEqual(outcome.reasoningNote, "[not auto-advanced: session not trusted]")
    }

    func testEscalateAndHoldNeverExecute() {
        for kind in [BossDecisionKind.escalate, .hold] {
            // Even if a gate somehow says allow, a non-autoAdvance kind never sends.
            let outcome = resolveAutoAdvanceOutcome(kind: kind, gate: .allow)
            XCTAssertFalse(outcome.execute, "\(kind) must never execute")
            XCTAssertEqual(outcome.status, .recorded)
            XCTAssertEqual(outcome.reasoningNote, "")
        }
    }
}
