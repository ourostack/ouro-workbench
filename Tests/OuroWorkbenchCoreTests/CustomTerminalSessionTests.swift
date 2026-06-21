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

    func testCustomSessionRequiresOnlyWorkingDirectory() {
        let projectId = UUID()
        let factory = CustomTerminalSessionFactory()

        // A blank name is no longer fatal — the factory defaults it (see
        // testBlankCommandProducesLoginShellWithDefaultName). Only a blank
        // working directory is required, since the factory can't invent a
        // sensible default for where the shell should run.
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

    /// Unit 4 / Slice 1: an empty command is the instant-blank-terminal path.
    /// Instead of throwing `.emptyCommand`, the factory produces a bare login
    /// shell (`/bin/zsh -l`) — the same shape `WorkbenchScenarioMatrix` already
    /// uses for `user_shell`. A blank name defaults to "Terminal".
    func testBlankCommandProducesLoginShellWithDefaultName() throws {
        let projectId = UUID()
        let entry = try CustomTerminalSessionFactory().makeEntry(
            projectId: projectId,
            draft: CustomTerminalSessionDraft(
                name: "   ",
                command: "   ",
                workingDirectory: "  /repo  ",
                trust: .trusted,
                autoResume: true
            )
        )

        XCTAssertEqual(entry.projectId, projectId)
        XCTAssertEqual(entry.name, "Terminal")
        XCTAssertEqual(entry.kind, .terminalAgent)
        XCTAssertNil(entry.agentKind)
        XCTAssertEqual(entry.executable, "/bin/zsh")
        XCTAssertEqual(entry.arguments, ["-l"])
        XCTAssertEqual(entry.workingDirectory, "/repo")
        XCTAssertEqual(entry.trust, .trusted)
        XCTAssertTrue(entry.autoResume)
        XCTAssertFalse(entry.isArchived)
        XCTAssertEqual(entry.lastSummary, "Terminal session: login shell")
    }

    /// A blank command with a non-empty name keeps the caller-supplied name but
    /// still produces the bare login shell.
    func testBlankCommandKeepsProvidedName() throws {
        let entry = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "  Scratch  ",
                command: "",
                workingDirectory: "/repo",
                trust: .untrusted,
                autoResume: false
            )
        )

        XCTAssertEqual(entry.name, "Scratch")
        XCTAssertEqual(entry.executable, "/bin/zsh")
        XCTAssertEqual(entry.arguments, ["-l"])
        XCTAssertNil(entry.notes)
    }

    /// A blank-command login shell still carries trimmed notes when supplied.
    func testBlankCommandPreservesNotes() throws {
        let entry = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "",
                command: "",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true,
                notes: "  scratch shell for poking around  "
            )
        )

        XCTAssertEqual(entry.executable, "/bin/zsh")
        XCTAssertEqual(entry.arguments, ["-l"])
        XCTAssertEqual(entry.notes, "scratch shell for poking around")
    }

    /// Round-trip: a `/bin/zsh -l` login-shell entry maps back to an
    /// empty-command draft so editing it doesn't surface `/bin/zsh -l` as a
    /// literal command the user has to clear.
    func testManagerExtractsEmptyCommandDraftFromLoginShellEntry() throws {
        let entry = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Terminal",
                command: "",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            )
        )

        let draft = try CustomTerminalSessionManager().draft(from: entry)

        XCTAssertEqual(draft, CustomTerminalSessionDraft(
            name: "Terminal",
            command: "",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: true
        ))
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

    func testManagerAcceptsPersistedShellAsManagedSession() throws {
        let shell = makeShellEntry()

        XCTAssertTrue(CustomTerminalSessionManager().isCustomSession(shell))
    }

    func testManagerExtractsDraftFromPersistedShellSession() throws {
        let shell = makeShellEntry(
            executable: "/usr/bin/env",
            arguments: ["bash", "-l"],
            trust: .untrusted,
            autoResume: false,
            notes: "Imported from old workbench state."
        )

        let draft = try CustomTerminalSessionManager().draft(from: shell)

        XCTAssertEqual(draft, CustomTerminalSessionDraft(
            name: "User Shell",
            command: "/usr/bin/env bash -l",
            workingDirectory: "/repo",
            trust: .untrusted,
            autoResume: false,
            notes: "Imported from old workbench state."
        ))
    }

    func testManagerUpdatesPersistedShellWhilePreservingKindAndIdentity() throws {
        let friend = SessionFriend(name: "Ari", kind: .human, trust: .family)
        var shell = makeShellEntry(
            trust: .trusted,
            autoResume: true,
            isArchived: true,
            isPinned: true,
            attention: .waitingOnHuman,
            friend: friend,
            owner: .agent(name: "slugger")
        )
        shell.lastSummary = "Waiting on imported shell"

        let updated = try CustomTerminalSessionManager().updatedEntry(
            shell,
            draft: CustomTerminalSessionDraft(
                name: "User Shell Renamed",
                command: "/usr/bin/env bash",
                workingDirectory: "/repo/app",
                trust: .untrusted,
                autoResume: false,
                notes: "Still plain shell."
            )
        )

        XCTAssertEqual(updated.id, shell.id)
        XCTAssertEqual(updated.projectId, shell.projectId)
        XCTAssertEqual(updated.kind, .shell)
        XCTAssertEqual(updated.name, "User Shell Renamed")
        XCTAssertEqual(updated.workingDirectory, "/repo/app")
        XCTAssertEqual(updated.trust, .untrusted)
        XCTAssertFalse(updated.autoResume)
        XCTAssertTrue(updated.isArchived)
        XCTAssertEqual(updated.attention, .waitingOnHuman)
        XCTAssertTrue(updated.isPinned)
        XCTAssertEqual(updated.friend, friend)
        XCTAssertEqual(updated.owner, .agent(name: "slugger"))
        XCTAssertEqual(updated.notes, "Still plain shell.")
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

    func testManagerDuplicatesPersistedShellAsShell() throws {
        let original = makeShellEntry(
            executable: "/usr/bin/env",
            arguments: ["bash", "-l"],
            notes: "Duplicate me too."
        )

        let duplicate = try CustomTerminalSessionManager().duplicateEntry(original, name: "Copy of User Shell")

        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(duplicate.projectId, original.projectId)
        XCTAssertEqual(duplicate.name, "Copy of User Shell")
        XCTAssertEqual(duplicate.kind, .shell)
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

    func testManagerArchivesAndRestoresPersistedShellSession() throws {
        let original = makeShellEntry(attention: .blocked)

        let archived = try CustomTerminalSessionManager().archivedEntry(original)
        let restored = try CustomTerminalSessionManager().restoredEntry(archived)

        XCTAssertEqual(archived.kind, .shell)
        XCTAssertTrue(archived.isArchived)
        XCTAssertEqual(archived.attention, .idle)
        XCTAssertEqual(archived.lastSummary, "Archived custom terminal session")
        XCTAssertEqual(restored.kind, .shell)
        XCTAssertFalse(restored.isArchived)
        XCTAssertEqual(restored.lastSummary, "Restored custom terminal session")
    }

    func testManagerRejectsCommandEntriesForManagedSessionOperations() throws {
        let command = ProcessEntry(
            projectId: UUID(),
            name: "One Shot",
            kind: .command,
            executable: "/bin/echo",
            arguments: ["hi"],
            workingDirectory: "/repo",
            trust: .trusted
        )
        let manager = CustomTerminalSessionManager()

        XCTAssertFalse(manager.isCustomSession(command))
        XCTAssertThrowsError(try manager.draft(from: command)) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .notCustomSession)
        }
        XCTAssertThrowsError(try manager.archivedEntry(command)) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .notCustomSession)
        }
        XCTAssertThrowsError(try manager.restoredEntry(command)) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .notCustomSession)
        }
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

    func testErrorDescriptionsCoverEveryValidationCase() {
        XCTAssertEqual(CustomTerminalSessionError.emptyName.errorDescription, "Session name is required")
        XCTAssertEqual(CustomTerminalSessionError.emptyCommand.errorDescription, "Session command is required")
        XCTAssertEqual(CustomTerminalSessionError.emptyWorkingDirectory.errorDescription, "Working directory is required")
        XCTAssertEqual(CustomTerminalSessionError.notCustomSession.errorDescription, "Only managed terminal sessions can be managed here")
        XCTAssertEqual(CustomTerminalSessionError.unavailableCommand.errorDescription, "Custom terminal session command is unavailable")
    }

    func testManagerRejectsNonTerminalSessionsForEditOperations() {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Web",
            kind: .command,
            executable: "open",
            workingDirectory: "/repo",
            trust: .trusted
        )
        let manager = CustomTerminalSessionManager()

        XCTAssertThrowsError(try manager.draft(from: entry)) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .notCustomSession)
        }
        XCTAssertThrowsError(try manager.updatedEntry(entry, draft: CustomTerminalSessionDraft(name: "x", command: "x", workingDirectory: "/repo", trust: .trusted, autoResume: true))) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .notCustomSession)
        }
        XCTAssertThrowsError(try manager.archivedEntry(entry)) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .notCustomSession)
        }
        XCTAssertThrowsError(try manager.restoredEntry(entry)) { error in
            XCTAssertEqual(error as? CustomTerminalSessionError, .notCustomSession)
        }
    }

    func testFactoryFallsBackToShellWrapperForUnparseableAndCanonicalizedCommands() throws {
        let factory = CustomTerminalSessionFactory()
        let unparseable = try factory.makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Broken Quote",
                command: "echo hi | claude",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            )
        )
        XCTAssertNil(unparseable.agentKind)
        XCTAssertEqual(unparseable.executable, "/bin/zsh")
        XCTAssertEqual(unparseable.arguments, ["-lc", "echo hi | claude"])
        XCTAssertNil(unparseable.notes)

        let canonicalized = try factory.makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Claude via env",
                command: "/usr/bin/env claude --model opus",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: false
            )
        )
        XCTAssertEqual(canonicalized.agentKind, .claudeCode)
        XCTAssertEqual(canonicalized.executable, "/bin/zsh")
        XCTAssertEqual(canonicalized.arguments, ["-lc", "/usr/bin/env claude --model opus"])
        XCTAssertEqual(canonicalized.lastSummary, "Detected Claude Code: /usr/bin/env claude --model opus")
    }

    func testDraftQuotesEmptyAndShellSensitiveArguments() throws {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Quoted",
            kind: .terminalAgent,
            executable: "/usr/bin/env",
            arguments: ["", "two words", "it's", "$HOME"],
            workingDirectory: "/repo",
            trust: .trusted
        )

        let draft = try CustomTerminalSessionManager().draft(from: entry)

        XCTAssertEqual(draft.command, "/usr/bin/env '' 'two words' 'it'\\''s' '$HOME'")
    }

    // MARK: - Forward memory (Slice 6)

    func testDraftDefaultsForwardMemoryToNil() {
        // A hand-typed draft (operator creating a session) carries no discovery
        // provenance — both forward-memory fields default to nil.
        let draft = CustomTerminalSessionDraft(
            name: "Hand typed",
            command: "claude",
            workingDirectory: "/repo",
            trust: .trusted,
            autoResume: false
        )

        XCTAssertNil(draft.discoveredHarness)
        XCTAssertNil(draft.discoveredSessionId)
    }

    func testFactoryPropagatesForwardMemoryFromDraftToEntry() throws {
        // When the create stems from a discovered session, the draft carries the
        // originating harness + sessionId; makeEntry must stamp them onto the
        // entry so the next scan()'s native path rediscovers it.
        let entry = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Resumed Claude",
                command: "claude --resume abc-123",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: false,
                discoveredHarness: .claudeCode,
                discoveredSessionId: "abc-123"
            )
        )

        XCTAssertEqual(entry.discoveredHarness, .claudeCode)
        XCTAssertEqual(entry.discoveredSessionId, "abc-123")
    }

    func testFactoryLeavesForwardMemoryNilForOrdinaryDraft() throws {
        // No provenance on the draft → no forward memory stamped (the common
        // operator-typed-a-command path).
        let entry = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Plain",
                command: "claude",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: false
            )
        )

        XCTAssertNil(entry.discoveredHarness)
        XCTAssertNil(entry.discoveredSessionId)
    }

    func testManagerUpdatePreservesForwardMemory() throws {
        // Editing a discovered-then-launched session must not wipe its forward
        // memory — the same don't-lose-identity policy as owner/isPinned/friend.
        var original = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Resumed",
                command: "claude",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: false,
                discoveredHarness: .claudeCode,
                discoveredSessionId: "abc-123"
            )
        )
        // makeEntry stamps from the draft; assert the precondition, then confirm
        // an edit (whose draft has NO forward memory) leaves them intact.
        XCTAssertEqual(original.discoveredHarness, .claudeCode)
        original.discoveredSessionId = "abc-123"

        let updated = try CustomTerminalSessionManager().updatedEntry(
            original,
            draft: CustomTerminalSessionDraft(
                name: "Resumed (renamed)",
                command: "claude",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: false
            )
        )

        XCTAssertEqual(updated.name, "Resumed (renamed)")
        XCTAssertEqual(updated.discoveredHarness, .claudeCode)
        XCTAssertEqual(updated.discoveredSessionId, "abc-123")
    }

    func testManagerDuplicatePreservesForwardMemory() throws {
        // Duplicating a discovered-then-launched session keeps the provenance so
        // the copy is still rediscoverable natively.
        let original = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Resumed",
                command: "copilot",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: false,
                discoveredHarness: .githubCopilotCLI,
                discoveredSessionId: "cop-9"
            )
        )

        let duplicate = try CustomTerminalSessionManager().duplicateEntry(original, name: "Copy")

        XCTAssertNotEqual(duplicate.id, original.id)
        XCTAssertEqual(duplicate.discoveredHarness, .githubCopilotCLI)
        XCTAssertEqual(duplicate.discoveredSessionId, "cop-9")
    }

    // MARK: - U13: shared save-validity rule (New & Edit terminal sheets)

    /// The validity rule both the New and Edit terminal sheets gate their primary
    /// button on lives in one place so they can't drift (U4 relaxed New; U13
    /// brought Edit to parity). The rule: only a non-empty working directory is
    /// required — a blank command becomes the login shell, a blank name defaults
    /// to "Terminal" — matching what the factory already accepts.
    func testSaveValidityRequiresOnlyAWorkingDirectory() {
        XCTAssertTrue(CustomTerminalSessionDraft.canSave(workingDirectory: "/repo"))
        XCTAssertTrue(CustomTerminalSessionDraft.canSave(workingDirectory: "  /repo  "))
    }

    func testSaveValidityRejectsABlankWorkingDirectory() {
        XCTAssertFalse(CustomTerminalSessionDraft.canSave(workingDirectory: ""))
        XCTAssertFalse(CustomTerminalSessionDraft.canSave(workingDirectory: "   "))
        XCTAssertFalse(CustomTerminalSessionDraft.canSave(workingDirectory: "\n\t "))
    }

    /// U13 round-trip: editing the blank login-shell terminal U4 creates yields a
    /// draft with an empty command (the manager round-trips `/bin/zsh -l` → ""),
    /// and saving that edit must re-produce the same login-shell entry — Save is
    /// no longer wrongly gated, and a blank-command edit doesn't degrade the
    /// session. The save path routes through the same factory `makeEntry` the New
    /// sheet uses, so an empty command → `/bin/zsh -l` + defaulted name.
    func testEditingBlankLoginShellRoundTripsToLoginShellEntry() throws {
        let manager = CustomTerminalSessionManager()
        let original = try CustomTerminalSessionFactory().makeEntry(
            projectId: UUID(),
            draft: CustomTerminalSessionDraft(
                name: "Terminal",
                command: "",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true
            )
        )

        // Edit opens with the round-tripped draft: blank command, present dir.
        let draft = try manager.draft(from: original)
        XCTAssertEqual(draft.command, "")
        // The relaxed Save gate must accept this draft (only the dir is required).
        XCTAssertTrue(CustomTerminalSessionDraft.canSave(workingDirectory: draft.workingDirectory))

        // Saving the unchanged blank-command edit re-creates the login shell.
        let saved = try manager.updatedEntry(original, draft: draft)
        XCTAssertEqual(saved.id, original.id)
        XCTAssertEqual(saved.executable, "/bin/zsh")
        XCTAssertEqual(saved.arguments, ["-l"])
        XCTAssertEqual(saved.name, "Terminal")
        XCTAssertEqual(saved.workingDirectory, "/repo")
    }

    /// Clearing the Command field on a real-command session and saving converts it
    /// to the login shell (parity with New Terminal) — the relaxed gate doesn't
    /// require a command, and the factory does the rest.
    func testEditingClearsCommandToLoginShell() throws {
        let manager = CustomTerminalSessionManager()
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

        var cleared = try manager.draft(from: original)
        cleared.command = ""
        XCTAssertTrue(CustomTerminalSessionDraft.canSave(workingDirectory: cleared.workingDirectory))

        let saved = try manager.updatedEntry(original, draft: cleared)
        XCTAssertEqual(saved.executable, "/bin/zsh")
        XCTAssertEqual(saved.arguments, ["-l"])
        XCTAssertEqual(saved.name, "Aider")
    }

    /// Editing a real-command session and keeping a command still saves it as that
    /// command — the relax doesn't break the normal edit path.
    func testEditingRealCommandSessionIsUnaffected() throws {
        let manager = CustomTerminalSessionManager()
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

        var edited = try manager.draft(from: original)
        edited.command = "codex --yolo"
        XCTAssertTrue(CustomTerminalSessionDraft.canSave(workingDirectory: edited.workingDirectory))

        let saved = try manager.updatedEntry(original, draft: edited)
        XCTAssertEqual(saved.agentKind, .openAICodex)
        XCTAssertEqual(saved.executable, "codex")
        XCTAssertEqual(saved.arguments, ["--yolo"])
    }

    private func makeShellEntry(
        executable: String = "/bin/zsh",
        arguments: [String] = ["-l"],
        trust: ProcessTrust = .trusted,
        autoResume: Bool = true,
        isArchived: Bool = false,
        isPinned: Bool = false,
        attention: AttentionState = .idle,
        notes: String? = nil,
        friend: SessionFriend? = nil,
        owner: SessionOwner = .human
    ) -> ProcessEntry {
        ProcessEntry(
            projectId: UUID(),
            name: "User Shell",
            kind: .shell,
            executable: executable,
            arguments: arguments,
            workingDirectory: "/repo",
            trust: trust,
            autoResume: autoResume,
            isArchived: isArchived,
            isPinned: isPinned,
            attention: attention,
            notes: notes,
            friend: friend,
            owner: owner
        )
    }
}
