import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class BossWorkbenchActionAuthorizerTests: XCTestCase {
    func testTrustedEntriesCanReceiveBossActions() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: "status")

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, for: entry)

        XCTAssertTrue(authorization.isAllowed)
        XCTAssertNil(authorization.reason)
    }

    func testUntrustedEntriesCannotReceiveBossActions() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Untrusted",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            workingDirectory: "/repo",
            trust: .untrusted
        )
        let action = BossWorkbenchAction(action: .launch, entry: entry.id.uuidString)

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, for: entry)

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "entry is untrusted")
    }

    func testArchivedEntriesCannotReceiveBossActions() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Archived",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            workingDirectory: "/repo",
            trust: .trusted,
            isArchived: true
        )
        let action = BossWorkbenchAction(action: .launch, entry: entry.id.uuidString)

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, for: entry)

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "entry is archived")
    }

    func testTrustedArchivedEntriesCanBeRestoredByBossActions() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Archived",
            kind: .terminalAgent,
            executable: "/bin/zsh",
            workingDirectory: "/repo",
            trust: .trusted,
            isArchived: true
        )
        let action = BossWorkbenchAction(action: .restore, entry: entry.id.uuidString)

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, for: entry)

        XCTAssertTrue(authorization.isAllowed)
        XCTAssertNil(authorization.reason)
    }

    func testUnsafeSendInputIsWithheldEvenOnTrustedSession() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: "rm -rf /tmp/cache")

        let authorization = BossWorkbenchActionAuthorizer().authorize(action, for: entry)

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "withheld unsafe input (destructive command) — escalated to a human")
    }

    /// P0 regression: the danger of a `sendInput` lives in the live PROMPT, not
    /// the bare input. A boss answering `y` to a `rm -rf /? [y/N]` confirmation
    /// must be withheld + escalated — even though `y` on its own is innocuous.
    func testSendInputToDestructiveLivePromptIsWithheld() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: "y")

        let authorization = BossWorkbenchActionAuthorizer().authorize(
            action,
            for: entry,
            livePrompt: "Run 'rm -rf /'? [y/N]"
        )

        XCTAssertFalse(authorization.isAllowed, "y to an rm -rf prompt must be withheld")
        XCTAssertEqual(authorization.reason, "withheld unsafe input (destructive command) — escalated to a human")
    }

    func testSendInputToSecretBearingLivePromptIsWithheld() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: "hunter2")

        let authorization = BossWorkbenchActionAuthorizer().authorize(
            action,
            for: entry,
            livePrompt: "Enter your password to continue:"
        )

        XCTAssertFalse(authorization.isAllowed)
        XCTAssertEqual(authorization.reason, "withheld unsafe input (credential prompt) — escalated to a human")
    }

    /// Prompt-aware floor: a safe input to a SAFE (or empty) live prompt stays
    /// allowed. This replaces the old input-only assumption — a benign `y`/`1`
    /// is allowed only because the prompt it answers is also benign.
    func testSafeSendInputToSafePromptIsAllowedOnTrustedSession() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let cases: [(input: String, prompt: String)] = [
            ("y", "Run tests? (y/N)"),
            ("1", "Do you want to make this edit?\n❯ 1. Yes\n  2. No"),
            ("continue", "Continue with the refactor?"),
            ("run the tests", "What should I do next?"),
            // No live prompt available (transcript missing): a benign input is
            // still allowed — the floor degrades to input-only, as documented.
            ("y", "")
        ]
        for testCase in cases {
            let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: testCase.input)
            let authorization = BossWorkbenchActionAuthorizer().authorize(
                action,
                for: entry,
                livePrompt: testCase.prompt
            )
            XCTAssertTrue(
                authorization.isAllowed,
                "expected input '\(testCase.input)' to a safe prompt '\(testCase.prompt)' to be allowed"
            )
        }
    }
}
