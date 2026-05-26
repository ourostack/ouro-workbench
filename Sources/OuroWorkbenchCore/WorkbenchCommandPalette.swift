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
}

public struct WorkbenchCommandDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: WorkbenchCommandID
    public var title: String
    public var detail: String
    public var systemImage: String
    public var keywords: [String]

    public init(
        id: WorkbenchCommandID,
        title: String,
        detail: String,
        systemImage: String,
        keywords: [String] = []
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
        self.keywords = keywords
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
