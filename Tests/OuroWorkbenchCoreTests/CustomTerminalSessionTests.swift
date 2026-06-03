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
        XCTAssertEqual(entry.lastSummary, "Terminal session: aider --yes")
        XCTAssertEqual(entry.notes, "Use for pair-programming spikes.")
    }

    func testCustomSessionDetectsKnownCLIAndStoresDirectCommand() throws {
        let entry = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Claude",
                command: "claude --dangerously-skip-permissions",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            )
        )

        XCTAssertEqual(entry.agentKind, .claudeCode)
        XCTAssertEqual(entry.executable, "claude")
        XCTAssertEqual(entry.arguments, ["--dangerously-skip-permissions"])
        XCTAssertEqual(entry.lastSummary, "Detected Claude Code: claude --dangerously-skip-permissions")
    }

    func testCustomSessionDetectsKnownCLIWithLeadingEnvironmentWithoutDroppingShellCommand() throws {
        let entry = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Claude With Env",
                command: "ANTHROPIC_MODEL=opus claude --dangerously-skip-permissions",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            )
        )

        XCTAssertEqual(entry.agentKind, .claudeCode)
        XCTAssertEqual(entry.executable, "/bin/zsh")
        XCTAssertEqual(entry.arguments, ["-lc", "ANTHROPIC_MODEL=opus claude --dangerously-skip-permissions"])
        XCTAssertEqual(entry.lastSummary, "Detected Claude Code: ANTHROPIC_MODEL=opus claude --dangerously-skip-permissions")
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
        XCTAssertEqual(updated.agentKind, .openAICodex)
        XCTAssertEqual(updated.executable, "codex")
        XCTAssertEqual(updated.arguments, ["--yolo"])
        XCTAssertEqual(updated.workingDirectory, "/repo/app")
        XCTAssertEqual(updated.trust, .untrusted)
        XCTAssertFalse(updated.autoResume)
        XCTAssertTrue(updated.isArchived)
        XCTAssertEqual(updated.notes, "Scratch lane.")
    }

    func testManagerUpdatePreservesOwnerPinAndFriend() throws {
        // Regression: editing an agent-created (owner: .agent) session through
        // the Edit Session sheet rebuilds the entry from the draft, which
        // doesn't carry owner / isPinned / friend. Before the fix `updatedEntry`
        // only copied id/isArchived/attention back, so these fields silently
        // reverted to their factory defaults (owner -> .human, pin lost, friend
        // dropped). Each must survive an edit.
        var original = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Agent Lane",
                command: "codex --yolo",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: false
            )
        )
        original.owner = .agent(name: "codex")
        original.isPinned = true
        let friend = SessionFriend(name: "Ari", kind: .human, trust: .family)
        original.friend = friend

        let updated = try CustomTerminalSessionManager().updatedEntry(
            original,
            draft: CustomTerminalSessionDraft(
                name: "Agent Lane (renamed)",
                command: "codex --yolo",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: false
            )
        )

        XCTAssertEqual(updated.name, "Agent Lane (renamed)")
        XCTAssertEqual(updated.owner, .agent(name: "codex"))
        XCTAssertEqual(updated.owner.agentName, "codex")
        XCTAssertTrue(updated.isPinned)
        XCTAssertEqual(updated.friend, friend)
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

    func testManagerExtractsDraftFromDetectedAgentTerminal() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Claude",
            kind: .terminalAgent,
            agentKind: .claudeCode,
            executable: "claude",
            workingDirectory: "/repo",
            trust: .trusted
        )

        let draft = try CustomTerminalSessionManager().draft(from: entry)

        XCTAssertEqual(draft.command, "claude")
        XCTAssertEqual(draft.name, "Claude")
    }

    func testManagerExtractsDraftFromDirectGenericTerminal() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Custom",
            kind: .terminalAgent,
            executable: "/usr/bin/env",
            arguments: ["aider"],
            workingDirectory: "/repo",
            trust: .trusted
        )

        let draft = try CustomTerminalSessionManager().draft(from: entry)

        XCTAssertEqual(draft.command, "/usr/bin/env aider")
    }
}
