import Foundation

public enum OuroAgentInstallCommandError: Error, Equatable, LocalizedError, Sendable {
    case emptyAgentName
    case invalidAgentName(String)
    case emptyRemote

    public var errorDescription: String? {
        switch self {
        case .emptyAgentName:
            return "Agent name is required."
        case let .invalidAgentName(agentName):
            return "Agent name cannot be used as a bundle name: \(agentName)"
        case .emptyRemote:
            return "Clone remote is required."
        }
    }
}

public struct OuroAgentInstallPlan: Equatable, Sendable {
    public var sessionName: String
    public var commandLine: String
    public var notes: String

    public init(sessionName: String, commandLine: String, notes: String) {
        self.sessionName = sessionName
        self.commandLine = commandLine
        self.notes = notes
    }
}

public struct OuroAgentInstallCommandBuilder: Sendable {
    public init() {}

    public func hatch() -> OuroAgentInstallPlan {
        return OuroAgentInstallPlan(
            sessionName: "Hatch Ouro Agent",
            commandLine: ShellArgumentEscaper.commandLine(["ouro", "hatch"]),
            notes: "Conversational Ouro hatch flow launched from Workbench."
        )
    }

    public func clone(remote: String, agentName: String?) throws -> OuroAgentInstallPlan {
        let normalizedRemote = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedRemote.isEmpty else {
            throw OuroAgentInstallCommandError.emptyRemote
        }

        var tokens = ["ouro", "clone", normalizedRemote]
        let normalizedAgentName = try agentName.flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : try self.normalizedAgentName(trimmed)
        }
        if let normalizedAgentName {
            tokens += ["--agent", normalizedAgentName]
        }

        return OuroAgentInstallPlan(
            sessionName: normalizedAgentName.map { "Clone \($0)" } ?? "Clone Ouro Agent",
            commandLine: ShellArgumentEscaper.commandLine(tokens),
            notes: "Ouro agent clone flow launched from Workbench."
        )
    }

    private func normalizedAgentName(_ agentName: String) throws -> String {
        let normalizedAgentName = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAgentName.isEmpty else {
            throw OuroAgentInstallCommandError.emptyAgentName
        }
        guard BossWorkbenchMCPRegistrar.isValidAgentBundleName(normalizedAgentName) else {
            throw OuroAgentInstallCommandError.invalidAgentName(normalizedAgentName)
        }
        return normalizedAgentName
    }
}
