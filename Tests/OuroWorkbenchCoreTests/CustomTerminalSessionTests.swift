import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class CustomTerminalSessionTests: XCTestCase {
    func testCustomSessionCreatesShellWrappedTerminalEntry() throws {
        let projectId = UUID()
        let entry = try CustomTerminalSessionFactory().makeEntry(
            projectId: projectId,
            draft: CustomTerminalSessionDraft(
                name: "  Local Agent  ",
                command: "  aider --yes  ",
                workingDirectory: "  /repo  ",
                trust: .trusted,
                autoResume: true,
                notes: "  Use for pair-programming spikes.  "
            )
        )

        XCTAssertEqual(entry.projectId, projectId)
        XCTAssertEqual(entry.name, "Local Agent")
        XCTAssertEqual(entry.kind, .terminalAgent)
        XCTAssertNil(entry.agentKind)
        XCTAssertEqual(entry.executable, "/bin/zsh")
        XCTAssertEqual(entry.arguments, ["-lc", "aider --yes"])
        XCTAssertEqual(entry.workingDirectory, "/repo")
        XCTAssertEqual(entry.trust, .trusted)
        XCTAssertTrue(entry.autoResume)
        XCTAssertFalse(entry.isArchived)
        XCTAssertEqual(entry.lastSummary, "Custom terminal session: aider --yes")
        XCTAssertEqual(entry.notes, "Use for pair-programming spikes.")
    }

    func testCustomSessionRequiresNameCommandAndWorkingDirectory() {
        let projectId = UUID()
        let factory = CustomTerminalSessionFactory()

        XCTAssertThrowsError(try factory.makeEntry(
            projectId: projectId,
            draft: CustomTerminalSessionDraft(
                name: " ",
                command: "aider",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            )
        )) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .emptyName)
        }

        XCTAssertThrowsError(try factory.makeEntry(
            projectId: projectId,
            draft: CustomTerminalSessionDraft(
                name: "Aider",
                command: " ",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            )
        )) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .emptyCommand)
        }

        XCTAssertThrowsError(try factory.makeEntry(
            projectId: projectId,
            draft: CustomTerminalSessionDraft(
                name: "Aider",
                command: "aider",
                workingDirectory: " ",
                trust: .trusted,
                autoResume: true
            )
        )) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .emptyWorkingDirectory)
        }
    }

    func testManagerExtractsDraftFromCustomSession() throws {
        let entry = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Aider",
                command: "aider --yes",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true,
                notes: "Keep this lane focused on tests."
            )
        )

        let draft = try CustomTerminalSessionManager().draft(from: entry)

        XCTAssertEqual(draft, CustomTerminalSessionDraft(
            name: "Aider",
            command: "aider --yes",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true,
            notes: "Keep this lane focused on tests."
        ))
    }

    func testManagerUpdatesCustomSessionWhilePreservingIdentityAndArchiveState() throws {
        let original = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Aider",
                command: "aider --yes",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            )
        )
        var archived = original
        archived.isArchived = true

        let updated = try CustomTerminalSessionManager().updatedEntry(
            archived,
            draft: CustomTerminalSessionDraft(
                name: "Codex Scratch",
                command: "codex --yolo",
                workingDirectory: "/repo/app",
                trust: .untrusted,
                autoResume: false,
                notes: "Scratch lane."
            )
        )

        XCTAssertEqual(updated.id, original.id)
        XCTAssertEqual(updated.projectId, original.projectId)
        XCTAssertEqual(updated.name, "Codex Scratch")
        XCTAssertEqual(updated.arguments, ["-lc", "codex --yolo"])
        XCTAssertEqual(updated.workingDirectory, "/repo/app")
        XCTAssertEqual(updated.trust, .untrusted)
        XCTAssertFalse(updated.autoResume)
        XCTAssertTrue(updated.isArchived)
        XCTAssertEqual(updated.notes, "Scratch lane.")
    }

    func testManagerDuplicatesCustomSessionWithRequestedName() throws {
        let original = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Aider",
                command: "aider --yes",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true,
                notes: "Duplicate me."
            )
        )

        let duplicate = try CustomTerminalSessionManager().duplicateEntry(original, name: "Copy of Aider")

        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(duplicate.projectId, original.projectId)
        XCTAssertEqual(duplicate.name, "Copy of Aider")
        XCTAssertEqual(duplicate.arguments, original.arguments)
        XCTAssertEqual(duplicate.notes, original.notes)
        XCTAssertFalse(duplicate.isArchived)
    }

    func testManagerArchivesAndRestoresCustomSession() throws {
        let original = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Aider",
                command: "aider --yes",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            )
        )

        let archived = try CustomTerminalSessionManager().archivedEntry(original)
        let restored = try CustomTerminalSessionManager().restoredEntry(archived)

        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(archived.attention, .idle)
        XCTAssertEqual(archived.lastSummary, "Archived custom terminal session")
        XCTAssertFalse(restored.isArchived)
        XCTAssertEqual(restored.lastSummary, "Restored custom terminal session")
    }

    func testManagerRejectsPresetTerminalAgents() {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Claude",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: "/repo",
            trust: .trusted
        )

        XCTAssertThrowsError(try CustomTerminalSessionManager().draft(from: entry)) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .notCustomSession)
        }
    }

    func testManagerRejectsCustomSessionsWithoutShellWrappedCommand() {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Custom",
            kind: .terminalAgent,
            executable: "/usr/bin/env",
            arguments: ["aider"],
            workingDirectory: "/repo",
            trust: .trusted
        )

        XCTAssertThrowsError(try CustomTerminalSessionManager().draft(from: entry)) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .unavailableCommand)
        }
    }
}
