import Foundation

public enum TerminalAgentKind: String, Codable, CaseIterable, Sendable {
    case claudeCode
    case githubCopilotCLI
    case openAICodex
    case custom

    // Unknown raw values (an agent kind added by a newer build) decode to
    // `.custom` rather than throwing — keeps the terminal, defaults the kind.
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TerminalAgentKind(rawValue: raw) ?? .custom
    }
}

public enum ResumeStrategyKind: String, Codable, Sendable {
    case nativeResumeCommand
    case checkpointPrompt
    case manual
}

public struct ResumeStrategy: Codable, Equatable, Sendable {
    public var kind: ResumeStrategyKind
    public var commandTemplate: [String]
    public var fallbackCommandTemplate: [String]
    public var notes: String

    public init(
        kind: ResumeStrategyKind,
        commandTemplate: [String] = [],
        fallbackCommandTemplate: [String] = [],
        notes: String
    ) {
        self.kind = kind
        self.commandTemplate = commandTemplate
        self.fallbackCommandTemplate = fallbackCommandTemplate
        self.notes = notes
    }
}

public struct TerminalAgentPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: TerminalAgentKind
    public var displayName: String
    public var executable: String
    public var defaultArguments: [String]
    public var yoloArguments: [String]
    public var resumeStrategy: ResumeStrategy

    public init(
        id: TerminalAgentKind,
        displayName: String,
        executable: String,
        defaultArguments: [String],
        yoloArguments: [String],
        resumeStrategy: ResumeStrategy
    ) {
        self.id = id
        self.displayName = displayName
        self.executable = executable
        self.defaultArguments = defaultArguments
        self.yoloArguments = yoloArguments
        self.resumeStrategy = resumeStrategy
    }
}

public enum TerminalAgentPresets {
    public static let all: [TerminalAgentPreset] = [
        TerminalAgentPreset(
            id: .claudeCode,
            displayName: "Claude Code",
            executable: "claude",
            defaultArguments: [],
            yoloArguments: ["--dangerously-skip-permissions"],
            resumeStrategy: ResumeStrategy(
                kind: .nativeResumeCommand,
                commandTemplate: ["claude", "--resume", "{{sessionId}}"],
                fallbackCommandTemplate: ["claude", "--continue"],
                notes: "Use Claude Code native resume when a session id is known; otherwise continue the most recent conversation in the working directory."
            )
        ),
        TerminalAgentPreset(
            id: .githubCopilotCLI,
            displayName: "GitHub Copilot CLI",
            executable: "gh",
            defaultArguments: ["copilot"],
            yoloArguments: ["copilot", "--", "--yolo"],
            resumeStrategy: ResumeStrategy(
                kind: .checkpointPrompt,
                notes: "Launch through the GitHub CLI Copilot bridge; persist transcript and checkpoint state until a native resume command is verified."
            )
        ),
        TerminalAgentPreset(
            id: .openAICodex,
            displayName: "OpenAI Codex",
            executable: "codex",
            defaultArguments: [],
            yoloArguments: ["--yolo"],
            resumeStrategy: ResumeStrategy(
                kind: .nativeResumeCommand,
                commandTemplate: ["codex", "resume", "{{sessionId}}"],
                fallbackCommandTemplate: ["codex", "resume", "--last"],
                notes: "Use Codex native resume when a session id is known; otherwise continue the most recent interactive session."
            )
        )
    ]

    public static func preset(for kind: TerminalAgentKind) -> TerminalAgentPreset? {
        all.first { $0.id == kind }
    }
}
