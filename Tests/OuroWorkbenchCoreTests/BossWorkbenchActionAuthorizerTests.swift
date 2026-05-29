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

    func testSafeSendInputIsAllowedOnTrustedSession() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Trusted",
            kind: .terminalAgent,
            executable: "codex",
            workingDirectory: "/repo",
            trust: .trusted
        )
        for text in ["y", "1", "continue", "run the tests"] {
            let action = BossWorkbenchAction(action: .sendInput, entry: entry.id.uuidString, text: text)
            let authorization = BossWorkbenchActionAuthorizer().authorize(action, for: entry)
            XCTAssertTrue(authorization.isAllowed, "expected '\(text)' to be allowed")
        }
    }
}
