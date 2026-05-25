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
            return "Only custom terminal sessions can be managed here"
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
        let detectedAgentKind = parsed.flatMap {
            TerminalAgentDetector.detect(executable: $0.executable, arguments: $0.arguments)
        }
        let executable = detectedAgentKind == nil ? "/bin/zsh" : (parsed?.executable ?? "/bin/zsh")
        let arguments = detectedAgentKind == nil ? ["-lc", command] : (parsed?.arguments ?? ["-lc", command])

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
        entry.kind == .terminalAgent
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
        return next
    }

    public func duplicateEntry(_ entry: ProcessEntry, name: String) throws -> ProcessEntry {
        var draft = try draft(from: entry)
        draft.name = name
        return try factory.makeEntry(projectId: entry.projectId, draft: draft)
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
