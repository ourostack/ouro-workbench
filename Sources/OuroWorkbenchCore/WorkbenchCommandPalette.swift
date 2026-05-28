import Foundation

public enum WorkbenchCommandID: String, Codable, CaseIterable, Sendable {
    case newSession
    case bossCheckIn
    case bossQuickWhatsGoingOn
    case bossQuickWaitingOnMe
    case bossQuickKeepMoving
    case bossQuickRespondForMe
    case toggleBossWatch
    case toggleBossPane
    case openOnboarding
    case installOuroAgent
    case refreshWorkspace
    case refreshOuroAgents
    case refreshWorkbenchMCP
    case installWorkbenchMCPForBoss
    case launchSelectedSession
    case focusSelectedSession
    case askBossAboutSelectedSession
    case redrawSelectedSession
    case sendControlCToSelectedSession
    case sendEscapeToSelectedSession
    case sendEOFToSelectedSession
    case copySelectedLaunchCommand
    case openSelectedWorkingDirectory
    case revealSelectedTranscript
    case stopSelectedSession
    case recoverSelectedSession
    case searchTranscripts
    case runRecoveryDrill
    case collectSupportDiagnostics
    case revealSupportDiagnostics
    case copySupportDiagnosticsPath
    case openSupportDiagnosticsFolder
    case checkReleaseUpdates
    case openReleaseUpdate
    case manageAgents
    case selectAgent
    case useSelectedAgentAsBoss
    case openSelectedAgentConfig
    case revealSelectedAgentBundle
    case repairSelectedAgent
    case installMCPForSelectedAgent
    case showKeyboardShortcutHelp
    case openWorkspaceConfig
    case saveWorkspaceConfig
    case openSettings
    case openAbout
    case stopAllRunningSessions
}

public struct WorkbenchCommandDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: WorkbenchCommandID
    public var title: String
    public var detail: String
    public var systemImage: String
    public var keywords: [String]
    /// Optional payload that lets one command ID address many concrete targets.
    /// Used by per-agent palette entries (e.g. `selectAgent` with `payload: "slugger"`)
    /// so the execute step doesn't need a separate command ID per agent.
    public var payload: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case detail
        case systemImage
        case keywords
        case payload
    }

    public init(
        id: WorkbenchCommandID,
        title: String,
        detail: String,
        systemImage: String,
        keywords: [String] = [],
        payload: String? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.keywords = keywords
        self.payload = payload
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(WorkbenchCommandID.self, forKey: .id)
        self.title = try container.decode(String.self, forKey: .title)
        self.detail = try container.decode(String.self, forKey: .detail)
        self.systemImage = try container.decode(String.self, forKey: .systemImage)
        self.keywords = try container.decodeIfPresent([String].self, forKey: .keywords) ?? []
        self.payload = try container.decodeIfPresent(String.self, forKey: .payload)
    }
}

public struct WorkbenchCommandPalette: Sendable {
    public init() {}

    public func filter(_ commands: [WorkbenchCommandDescriptor], query: String) -> [WorkbenchCommandDescriptor] {
        let tokens = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        guard !tokens.isEmpty else {
            return commands
        }
        return commands.filter { command in
            let searchableText = ([command.id.rawValue, command.title, command.detail] + command.keywords)
                .joined(separator: " ")
            return tokens.allSatisfy { token in
                searchableText.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }
}
