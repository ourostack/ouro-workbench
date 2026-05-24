import Foundation

public enum BossWorkbenchActionKind: String, Codable, Sendable {
    case launch
    case recover
    case terminate
    case sendInput
}

public struct BossWorkbenchAction: Codable, Equatable, Sendable {
    public var action: BossWorkbenchActionKind
    public var entry: String
    public var text: String?
    public var appendNewline: Bool

    private enum CodingKeys: String, CodingKey {
        case action
        case entry
        case text
        case appendNewline
    }

    public init(
        action: BossWorkbenchActionKind,
        entry: String,
        text: String? = nil,
        appendNewline: Bool = true
    ) {
        self.action = action
        self.entry = entry
        self.text = text
        self.appendNewline = appendNewline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.action = try container.decode(BossWorkbenchActionKind.self, forKey: .action)
        self.entry = try container.decode(String.self, forKey: .entry)
        self.text = try container.decodeIfPresent(String.self, forKey: .text)
        self.appendNewline = try container.decodeIfPresent(Bool.self, forKey: .appendNewline) ?? true
    }
}

public enum BossWorkbenchActionValidationError: LocalizedError, Equatable, Sendable {
    case missingTextForSendInput

    public var errorDescription: String? {
        switch self {
        case .missingTextForSendInput:
            return "sendInput requires non-empty text"
        }
    }
}

public extension BossWorkbenchAction {
    func validateForQueueing() throws {
        guard action == .sendInput else {
            return
        }
        guard text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw BossWorkbenchActionValidationError.missingTextForSendInput
        }
    }
}

public struct BossWorkbenchActionParser: Sendable {
    public init() {}

    public func parse(_ text: String) throws -> [BossWorkbenchAction] {
        guard let json = fencedActionJSON(in: text) ?? markerActionJSON(in: text) else {
            return []
        }
        return try JSONDecoder().decode([BossWorkbenchAction].self, from: Data(json.utf8))
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
