import Foundation

public struct TerminalEnvironment: Equatable, Sendable {
    public var values: [String: String]

    public init(values: [String: String] = ProcessInfo.processInfo.environment) {
        self.values = values
    }

    public func mergedWithTerminalDefaults() -> [String] {
        valuesWithResolvedPath()
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
    }

    public func valuesWithResolvedPath() -> [String: String] {
        var merged = values
        merged["TERM"] = "xterm-256color"
        merged["COLORTERM"] = merged["COLORTERM"] ?? "truecolor"
        merged["LANG"] = merged["LANG"] ?? "en_US.UTF-8"
        merged["TERM_PROGRAM"] = "OuroWorkbench"
        merged["PATH"] = Self.resolvedPath(from: merged)
        return merged
    }

    public static func resolvedPath(from values: [String: String]) -> String {
        let existing = values["PATH"]?.split(separator: ":").map(String.init) ?? []
        let homeLocalBin = values["HOME"].map { "\($0)/.local/bin" }
        let defaults = [
            homeLocalBin,
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].compactMap { $0 }
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
