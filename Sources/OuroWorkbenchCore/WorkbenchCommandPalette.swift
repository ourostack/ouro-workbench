import Foundation

public enum WorkbenchCommandID: String, Codable, CaseIterable, Sendable {
    case newSession
    case bossCheckIn
    case toggleBossWatch
    case launchSelectedSession
    case stopSelectedSession
    case recoverSelectedSession
    case searchTranscripts
}

public struct WorkbenchCommandDescriptor: Codable, Equatable, Identifiable, Sendable {
    public var id: WorkbenchCommandID
    public var title: String
    public var detail: String
    public var systemImage: String

    public init(id: WorkbenchCommandID, title: String, detail: String, systemImage: String) {
        self.id = id
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
    }
}

public struct WorkbenchCommandPalette: Sendable {
    public init() {}

    public func filter(_ commands: [WorkbenchCommandDescriptor], query: String) -> [WorkbenchCommandDescriptor] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return commands
        }
        return commands.filter { command in
            command.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || command.detail.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}
