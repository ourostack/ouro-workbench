import Foundation

public enum BossWorkbenchActionKind: String, Codable, Sendable, CaseIterable {
    case launch
    case recover
    case terminate
    case sendInput
    case createGroup
    case createTerminal
    case moveSession
    case setTrust
    case setAutoResume
    case archive
    case restore
}

public struct BossWorkbenchAction: Codable, Equatable, Sendable {
    public var action: BossWorkbenchActionKind
    public var entry: String?
    public var text: String?
    public var appendNewline: Bool
    public var group: String?
    public var name: String?
    public var command: String?
    public var workingDirectory: String?
    public var trust: ProcessTrust?
    public var autoResume: Bool?

    private enum CodingKeys: String, CodingKey {
        case action
        case entry
        case text
        case appendNewline
        case group
        case name
        case command
        case workingDirectory
        case trust
        case autoResume
    }

    public init(
        action: BossWorkbenchActionKind,
        entry: String? = nil,
        text: String? = nil,
        appendNewline: Bool = true,
        group: String? = nil,
        name: String? = nil,
        command: String? = nil,
        workingDirectory: String? = nil,
        trust: ProcessTrust? = nil,
        autoResume: Bool? = nil
    ) {
        self.action = action
        self.entry = entry
        self.text = text
        self.appendNewline = appendNewline
        self.group = group
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.trust = trust
        self.autoResume = autoResume
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decode(BossWorkbenchActionKind.self, forKey: .action)
        self.entry = try container.decodeIfPresent(String.self, forKey: .entry)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.appendNewline = try container.decodeIfPresent(Bool.self, forKey: .appendNewline) ?? true
        self.group = try container.decodeIfPresent(String.self, forKey: .group)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.command = try container.decodeIfPresent(String.self, forKey: .command)
        self.workingDirectory = try container.decodeIfPresent(String.self, forKey: .workingDirectory)
        self.trust = try container.decodeIfPresent(ProcessTrust.self, forKey: .trust)
        self.autoResume = try container.decodeIfPresent(Bool.self, forKey: .autoResume)
    }
}

public enum BossWorkbenchActionValidationError: LocalizedError, Equatable, Sendable {
    case missingEntry(BossWorkbenchActionKind)
    case missingTextForSendInput
    case missingName(BossWorkbenchActionKind)
    case missingCommandForCreateTerminal
    case missingWorkingDirectoryForCreateGroup
    case missingGroupForMoveSession
    case missingTrustForSetTrust
    case missingAutoResumeForSetAutoResume

    public var errorDescription: String? {
        switch self {
        case .missingEntry(let action):
            return "\(action.rawValue) requires an entry"
        case .missingTextForSendInput:
            return "sendInput requires non-empty text"
        case .missingName(let action):
            return "\(action.rawValue) requires a non-empty name"
        case .missingCommandForCreateTerminal:
            return "createTerminal requires a non-empty command"
        case .missingWorkingDirectoryForCreateGroup:
            return "createGroup requires a non-empty workingDirectory"
        case .missingGroupForMoveSession:
            return "moveSession requires a target group"
        case .missingTrustForSetTrust:
            return "setTrust requires trust"
        case .missingAutoResumeForSetAutoResume:
            return "setAutoResume requires autoResume"
        }
    }
}

public extension BossWorkbenchAction {
    func validateForQueueing() throws {
        switch action {
        case .launch, .recover, .terminate, .sendInput, .moveSession, .setTrust, .setAutoResume, .archive, .restore:
            guard entry?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingEntry(action)
            }
        case .createGroup, .createTerminal:
            break
        }

        switch action {
        case .sendInput:
            guard text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingTextForSendInput
            }
        case .createGroup:
            guard name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingName(action)
            }
            guard workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingWorkingDirectoryForCreateGroup
            }
        case .createTerminal:
            guard name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingName(action)
            }
            guard command?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingCommandForCreateTerminal
            }
        case .moveSession:
            guard group?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                throw BossWorkbenchActionValidationError.missingGroupForMoveSession
            }
        case .setTrust:
            guard trust != nil else {
                throw BossWorkbenchActionValidationError.missingTrustForSetTrust
            }
        case .setAutoResume:
            guard autoResume != nil else {
                throw BossWorkbenchActionValidationError.missingAutoResumeForSetAutoResume
            }
        case .launch, .recover, .terminate, .archive, .restore:
            break
        }
    }
}

public struct BossWorkbenchActionParser: Sendable {
    public init() {}

    public func parse(_ text: String) throws -> [BossWorkbenchAction] {
        guard let json = fencedActionJSON(in: text) ?? markerActionJSON(in: text) else {
            return []
        }
        // Decode the action array leniently: one malformed action (e.g. the
        // boss emits an unknown action type or a wrong field shape) shouldn't
        // discard the whole batch of otherwise-valid actions. If the payload
        // isn't an array at all, this still throws so the caller can surface a
        // parse error.
        let wrappers = try JSONDecoder().decode([FailableDecodable<BossWorkbenchAction>].self, from: Data(json.utf8))
        return wrappers.compactMap(\.base)
    }

    private func fencedActionJSON(in text: String) -> String? {
        let fence = "```ouro-workbench-actions"
        guard let start = text.range(of: fence) else {
            return nil
        }
        let remainder = text[start.upperBound...]
        guard let end = remainder.range(of: "```") else {
            return nil
        }
        return String(remainder[..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func markerActionJSON(in text: String) -> String? {
        let marker = "OURO_WORKBENCH_ACTIONS:"
        guard let start = text.range(of: marker) else {
            return nil
        }
        return String(text[start.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
