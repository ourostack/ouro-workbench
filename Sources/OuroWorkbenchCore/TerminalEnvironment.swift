import Foundation

public struct TerminalEnvironment: Equatable, Sendable {
    public var values: [String: String]

    public init(values: [String: String] = ProcessInfo.processInfo.environment) {
        self.values = values
    }

    public func mergedWithTerminalDefaults() -> [String] {
        var merged = values
        merged["TERM"] = merged["TERM"] ?? "xterm-256color"
        merged["COLORTERM"] = merged["COLORTERM"] ?? "truecolor"
        merged["LANG"] = merged["LANG"] ?? "en_US.UTF-8"
        merged["PATH"] = Self.resolvedPath(from: merged)
        return merged
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
    }

    public static func resolvedPath(from values: [String: String]) -> String {
        let existing = values["PATH"]?.split(separator: ":").map(String.init) ?? []
        let defaults = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        var seen = Set<String>()
        return (existing + defaults)
            .filter { component in
                guard !component.isEmpty, !seen.contains(component) else {
                    return false
                }
                seen.insert(component)
                return true
            }
            .joined(separator: ":")
    }
}
