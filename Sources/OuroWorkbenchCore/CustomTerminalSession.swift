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

    public init(
        name: String,
        command: String,
        workingDirectory: String,
        trust: ProcessTrust,
        autoResume: Bool,
        notes: String = ""
    ) {
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.trust = trust
        self.autoResume = autoResume
        self.notes = notes
    }
}

public struct CustomTerminalSessionFactory: Sendable {
    public init() {}

    public func makeEntry(projectId: UUID, draft: CustomTerminalSessionDraft) throws -> ProcessEntry {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = draft.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        let notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            throw CustomTerminalSessionError.emptyName
        }
        guard !command.isEmpty else {
            throw CustomTerminalSessionError.emptyCommand
        }
        guard !workingDirectory.isEmpty else {
            throw CustomTerminalSessionError.emptyWorkingDirectory
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
            notes: notes.isEmpty ? nil : notes
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
