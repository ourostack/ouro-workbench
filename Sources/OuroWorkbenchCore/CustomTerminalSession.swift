import Foundation

public enum CustomTerminalSessionError: Error, Equatable, LocalizedError {
    case emptyName
    case emptyCommand
    case emptyWorkingDirectory

    public var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Session name is required"
        case .emptyCommand:
            return "Session command is required"
        case .emptyWorkingDirectory:
            return "Working directory is required"
        }
    }
}

public struct CustomTerminalSessionDraft: Equatable, Sendable {
    public var name: String
    public var command: String
    public var workingDirectory: String
    public var trust: ProcessTrust
    public var autoResume: Bool

    public init(
        name: String,
        command: String,
        workingDirectory: String,
        trust: ProcessTrust,
        autoResume: Bool
    ) {
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.trust = trust
        self.autoResume = autoResume
    }
}

public struct CustomTerminalSessionFactory: Sendable {
    public init() {}

    public func makeEntry(projectId: UUID, draft: CustomTerminalSessionDraft) throws -> ProcessEntry {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let command = draft.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectory = draft.workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !name.isEmpty else {
            throw CustomTerminalSessionError.emptyName
        }
        guard !command.isEmpty else {
            throw CustomTerminalSessionError.emptyCommand
        }
        guard !workingDirectory.isEmpty else {
            throw CustomTerminalSessionError.emptyWorkingDirectory
        }

        return ProcessEntry(
            projectId: projectId,
            name: name,
            kind: .terminalAgent,
            agentKind: nil,
            executable: "/bin/zsh",
            arguments: ["-lc", command],
            workingDirectory: workingDirectory,
            trust: draft.trust,
            autoResume: draft.autoResume,
            attention: .idle,
            lastSummary: "Custom terminal session: \(command)"
        )
    }
}
