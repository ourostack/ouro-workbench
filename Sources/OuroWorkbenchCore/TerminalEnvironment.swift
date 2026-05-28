import Foundation

/// Per-session Workbench context layered onto a launched terminal's environment
/// so the agent inside can detect and describe its host. The always-on markers
/// (`OURO_WORKBENCH`, `OURO_WORKBENCH_VERSION`, `TERM_PROGRAM`) are set even when
/// no context is supplied; the contextual fields are emitted only when present.
public struct WorkbenchSessionContext: Equatable, Sendable {
    public var contextFilePath: String?
    public var group: String?
    public var session: String?
    public var boss: String?

    public init(
        contextFilePath: String? = nil,
        group: String? = nil,
        session: String? = nil,
        boss: String? = nil
    ) {
        self.contextFilePath = contextFilePath
        self.group = group
        self.session = session
        self.boss = boss
    }

    /// The contextual environment variables, omitting any unset field so the
    /// agent never sees an empty `OURO_WORKBENCH_GROUP=`.
    public var environmentVariables: [String: String] {
        var values: [String: String] = [:]
        if let contextFilePath, !contextFilePath.isEmpty {
            values["OURO_WORKBENCH_CONTEXT_FILE"] = contextFilePath
        }
        if let group, !group.isEmpty {
            values["OURO_WORKBENCH_GROUP"] = group
        }
        if let session, !session.isEmpty {
            values["OURO_WORKBENCH_SESSION"] = session
        }
        if let boss, !boss.isEmpty {
            values["OURO_WORKBENCH_BOSS"] = boss
        }
        return values
    }
}

public struct TerminalEnvironment: Equatable, Sendable {
    public var values: [String: String]
    public var workbenchContext: WorkbenchSessionContext?

    public init(
        values: [String: String] = ProcessInfo.processInfo.environment,
        workbenchContext: WorkbenchSessionContext? = nil
    ) {
        self.values = values
        self.workbenchContext = workbenchContext
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
        // Always-on markers so any session Workbench launches can detect its host.
        merged["OURO_WORKBENCH"] = "1"
        merged["OURO_WORKBENCH_VERSION"] = WorkbenchRelease.version
        if let workbenchContext {
            for (key, value) in workbenchContext.environmentVariables {
                merged[key] = value
            }
        }
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
