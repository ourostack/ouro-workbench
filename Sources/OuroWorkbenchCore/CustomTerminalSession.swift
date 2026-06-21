import Foundation

public enum CustomTerminalSessionError: Error, Equatable, LocalizedError {
    case emptyName
    case emptyCommand
    case emptyWorkingDirectory
    case notCustomSession
    case unavailableCommand

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Session name is required"
        case .emptyCommand:
            return "Session command is required"
        case .emptyWorkingDirectory:
            return "Working directory is required"
        case .notCustomSession:
            return "Only managed terminal sessions can be managed here"
        case .unavailableCommand:
            return "Custom terminal session command is unavailable"
        }
    }
}

public struct CustomTerminalSessionDraft: Equatable, Sendable {
    public var name: String
    public var command: String
    public var workingDirectory: String
    public var trust: ProcessTrust
    public var autoResume: Bool
    public var notes: String
    /// FORWARD MEMORY (Slice 6). When a create stems from a DISCOVERED session
    /// (the boss is relaunching something the scanner found), the draft carries
    /// the originating `{harness, sessionId}` so `makeEntry` can stamp them onto
    /// the entry — making the relaunched session natively rediscoverable. Both
    /// default to nil (the ordinary operator-typed-a-command case carries no
    /// provenance), and they're general opaque values Workbench just stores.
    public var discoveredHarness: AgentHarness?
    public var discoveredSessionId: String?

    public init(
        name: String,
        command: String,
        workingDirectory: String,
        trust: ProcessTrust,
        autoResume: Bool,
        notes: String = "",
        discoveredHarness: AgentHarness? = nil,
        discoveredSessionId: String? = nil
    ) {
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.trust = trust
        self.autoResume = autoResume
        self.notes = notes
        self.discoveredHarness = discoveredHarness
        self.discoveredSessionId = discoveredSessionId
    }

    /// Single source of truth for whether a terminal-session draft can be saved,
    /// shared by the New and Edit terminal sheets so they can't drift apart (U4
    /// relaxed New; U13 brought Edit to parity). Only a non-empty working
    /// directory is required: a blank command becomes the `/bin/zsh -l` login
    /// shell and a blank name defaults to "Terminal", both handled by
    /// `CustomTerminalSessionFactory.makeEntry`. The sheets hold their fields as
    /// raw `@State` strings before constructing a draft, so this gates on the raw
    /// working-directory string the same way `makeEntry` trims and validates it.
    public static func canSave(workingDirectory: String) -> Bool {
        !workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct CustomTerminalSessionFactory: Sendable {
    public init() {}

    /// Default name for a blank login-shell session when the draft carries no
    /// name. Mirrors the empty-state "New Terminal" intent: zero required typing.
    public static let defaultBlankSessionName = "Terminal"

    public func makeEntry(projectId: UUID, draft: CustomTerminalSessionDraft) throws -> ProcessEntry {
        let trimmedName = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = draft.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)

        // Unit 4 / Slice 1: an empty command is the instant-blank-terminal path,
        // not an error. We default the name and fall through to a bare login
        // shell below — no required typing for the "open a blank terminal" case.
        // A name is likewise optional (defaulted); only the working directory is
        // required, since there's no sensible default for where to run.
        let name = trimmedName.isEmpty ? Self.defaultBlankSessionName : trimmedName
        guard !workingDirectory.isEmpty else {
            throw CustomTerminalSessionError.emptyWorkingDirectory
        }

        // Blank command → bare login shell (`/bin/zsh -l`), the same shape
        // `WorkbenchScenarioMatrix` already uses for `user_shell`. No detected
        // agent, plain interactive shell.
        guard !command.isEmpty else {
            return ProcessEntry(
                projectId: projectId,
                name: name,
                kind: .terminalAgent,
                agentKind: nil,
                executable: "/bin/zsh",
                arguments: ["-l"],
                workingDirectory: workingDirectory,
                trust: draft.trust,
                autoResume: draft.autoResume,
                attention: .idle,
                lastSummary: "Terminal session: login shell",
                notes: notes.isEmpty ? nil : notes,
                discoveredHarness: draft.discoveredHarness,
                discoveredSessionId: draft.discoveredSessionId
            )
        }

        let parsed = TerminalCommandParser.parse(command)
        let canonical = parsed.map {
            TerminalAgentDetector.canonicalTokens(executable: $0.executable, arguments: $0.arguments)
        }
        let detectedAgentKind = canonical.flatMap {
            TerminalAgentDetector.detect(executable: $0.executable, arguments: $0.arguments)
        }
        let canStoreDirectly = parsed != nil
            && canonical != nil
            && parsed?.executable == canonical?.executable
            && parsed?.arguments == canonical?.arguments
        let executable: String
        let arguments: [String]
        if detectedAgentKind != nil, canStoreDirectly, let parsed {
            executable = parsed.executable
            arguments = parsed.arguments
        } else {
            executable = "/bin/zsh"
            arguments = ["-lc", command]
        }

        return ProcessEntry(
            projectId: projectId,
            name: name,
            kind: .terminalAgent,
            agentKind: detectedAgentKind,
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            trust: draft.trust,
            autoResume: draft.autoResume,
            attention: .idle,
            lastSummary: detectedAgentKind.flatMap(TerminalAgentDetector.displayName).map { "Detected \($0): \(command)" } ?? "Terminal session: \(command)",
            notes: notes.isEmpty ? nil : notes,
            // Forward memory (Slice 6): stamp the discovery provenance the draft
            // carried (nil for the ordinary operator-typed case) so a session
            // Workbench launched from a discovered one is rediscovered natively.
            discoveredHarness: draft.discoveredHarness,
            discoveredSessionId: draft.discoveredSessionId
        )
    }
}

public struct CustomTerminalSessionManager: Sendable {
    private let factory: CustomTerminalSessionFactory

    public init(factory: CustomTerminalSessionFactory = CustomTerminalSessionFactory()) {
        self.factory = factory
    }

    public func isCustomSession(_ entry: ProcessEntry) -> Bool {
        entry.kind == .terminalAgent || entry.kind == .shell
    }

    public func draft(from entry: ProcessEntry) throws -> CustomTerminalSessionDraft {
        guard isCustomSession(entry) else {
            throw CustomTerminalSessionError.notCustomSession
        }
        let command: String
        if entry.executable == "/bin/zsh",
           entry.arguments == ["-l"] {
            // Unit 4 / Slice 1: a bare login shell round-trips to an empty
            // command so editing it shows a blank Command field (and re-saving
            // re-creates the same login shell) rather than surfacing the
            // `/bin/zsh -l` internals as a literal command the user must clear.
            command = ""
        } else if entry.executable == "/bin/zsh",
                  entry.arguments.count == 2,
                  entry.arguments[0] == "-lc" {
            command = entry.arguments[1]
        } else {
            command = ([entry.executable] + entry.arguments).map(shellQuote).joined(separator: " ")
        }

        return CustomTerminalSessionDraft(
            name: entry.name,
            command: command,
            workingDirectory: entry.workingDirectory,
            trust: entry.trust,
            autoResume: entry.autoResume,
            notes: entry.notes ?? ""
        )
    }

    public func updatedEntry(_ entry: ProcessEntry, draft: CustomTerminalSessionDraft) throws -> ProcessEntry {
        guard isCustomSession(entry) else {
            throw CustomTerminalSessionError.notCustomSession
        }

        var next = try factory.makeEntry(projectId: entry.projectId, draft: draft)
        next.id = entry.id
        next.isArchived = entry.isArchived
        next.attention = entry.attention
        // Carry over the entry-identity fields that aren't part of the editable
        // draft. `makeEntry` defaults each of these (owner: .human, isPinned:
        // false, friend: nil), so without this an edit silently wipes them —
        // e.g. an agent-created session (owner: .agent) reverts to human, a
        // pinned session loses its pin, and an assigned friend is dropped
        // (which also stops the boss from auto-advancing it).
        next.owner = entry.owner
        next.isPinned = entry.isPinned
        next.friend = entry.friend
        // Forward memory (Slice 6): the editable draft carries no provenance, so
        // copy it back the same way as owner/isPinned/friend — otherwise editing
        // a discovered-then-launched session would silently drop its native
        // rediscoverability.
        next.discoveredHarness = entry.discoveredHarness
        next.discoveredSessionId = entry.discoveredSessionId
        if entry.kind == .shell {
            next.kind = .shell
            next.agentKind = entry.agentKind
        }
        return next
    }

    public func duplicateEntry(_ entry: ProcessEntry, name: String) throws -> ProcessEntry {
        var draft = try draft(from: entry)
        draft.name = name
        var duplicate = try factory.makeEntry(projectId: entry.projectId, draft: draft)
        // Forward memory (Slice 6): `draft(from:)` doesn't carry provenance, so
        // copy it onto the duplicate — a copy of a discovered-then-launched
        // session stays natively rediscoverable.
        duplicate.discoveredHarness = entry.discoveredHarness
        duplicate.discoveredSessionId = entry.discoveredSessionId
        if entry.kind == .shell {
            duplicate.kind = .shell
            duplicate.agentKind = entry.agentKind
        }
        return duplicate
    }

    public func archivedEntry(_ entry: ProcessEntry) throws -> ProcessEntry {
        guard isCustomSession(entry) else {
            throw CustomTerminalSessionError.notCustomSession
        }
        var next = entry
        next.isArchived = true
        next.attention = .idle
        next.lastSummary = "Archived custom terminal session"
        return next
    }

    public func restoredEntry(_ entry: ProcessEntry) throws -> ProcessEntry {
        guard isCustomSession(entry) else {
            throw CustomTerminalSessionError.notCustomSession
        }
        var next = entry
        next.isArchived = false
        next.attention = .idle
        next.lastSummary = "Restored custom terminal session"
        return next
    }
}

private func shellQuote(_ value: String) -> String {
    guard !value.isEmpty else {
        return "''"
    }
    if value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "'\"\\$`"))) == nil {
        return value
    }
    return "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
}
