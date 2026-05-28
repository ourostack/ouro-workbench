import Foundation

/// Declarative Workbench workspace definition. A `.workbench.json` file at a
/// project root captures the group / terminals a repo wants to spin up so
/// `Open Workspace…` can reconcile them with existing state without the user
/// dragging the same set of CLI invocations together every time.
///
/// Shape (all fields optional except `terminals`):
/// ```json
/// {
///   "group": "spoonjoy-v2",
///   "rootPath": "~/Projects/spoonjoy-v2",
///   "terminals": [
///     {
///       "name": "dev server",
///       "command": "npm run dev",
///       "workingDirectory": ".",
///       "trust": "trusted",
///       "autoResume": true,
///       "notes": "vite + tailwind"
///     }
///   ]
/// }
/// ```
public struct WorkbenchWorkspaceConfig: Codable, Equatable, Sendable {
    public var group: String?
    public var rootPath: String?
    public var terminals: [TerminalConfig]

    public init(
        group: String? = nil,
        rootPath: String? = nil,
        terminals: [TerminalConfig]
    ) {
        self.group = group
        self.rootPath = rootPath
        self.terminals = terminals
    }

    public struct TerminalConfig: Codable, Equatable, Sendable {
        /// Display name shown in the sidebar.
        public var name: String
        /// Full launch command, e.g. `npm run dev`, `claude --resume <id>`.
        public var command: String
        /// Defaults to the workspace's resolved root path.
        public var workingDirectory: String?
        /// `"trusted"` (boss can act without confirming) or `"untrusted"`
        /// (boss must wait for human). Defaults to `"untrusted"`.
        public var trust: String?
        /// Restart automatically on Workbench relaunch. Defaults to `false`.
        public var autoResume: Bool?
        /// Free-form notes shown in the session inspector.
        public var notes: String?

        public init(
            name: String,
            command: String,
            workingDirectory: String? = nil,
            trust: String? = nil,
            autoResume: Bool? = nil,
            notes: String? = nil
        ) {
            self.name = name
            self.command = command
            self.workingDirectory = workingDirectory
            self.trust = trust
            self.autoResume = autoResume
            self.notes = notes
        }
    }
}

public enum WorkbenchWorkspaceConfigError: Error, Equatable, Sendable {
    case configFileMissing(String)
    case malformedJSON(String)
    case noTerminals
}

/// Loads `.workbench.json` from a given directory and validates it. Resolves
/// `~` expansion in the rootPath / workingDirectory and falls back to the
/// directory containing the config when those fields are missing.
public struct WorkbenchWorkspaceConfigLoader: Sendable {
    public static let configFileName = ".workbench.json"

    public init() {}

    public func load(directoryPath: String, fileManager: FileManager = .default) throws -> WorkbenchWorkspaceConfig {
        let expandedDirectory = (directoryPath as NSString).expandingTildeInPath
        let configPath = (expandedDirectory as NSString).appendingPathComponent(Self.configFileName)
        guard fileManager.fileExists(atPath: configPath) else {
            throw WorkbenchWorkspaceConfigError.configFileMissing(configPath)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: configPath))
        } catch {
            throw WorkbenchWorkspaceConfigError.malformedJSON(error.localizedDescription)
        }
        let decoder = JSONDecoder()
        let decoded: WorkbenchWorkspaceConfig
        do {
            decoded = try decoder.decode(WorkbenchWorkspaceConfig.self, from: data)
        } catch {
            throw WorkbenchWorkspaceConfigError.malformedJSON(error.localizedDescription)
        }
        guard !decoded.terminals.isEmpty else {
            throw WorkbenchWorkspaceConfigError.noTerminals
        }
        return decoded
    }

    /// Resolve the effective root path for a config loaded from `directoryPath`.
    /// Uses `rootPath` when set (with `~` expansion); otherwise falls back to
    /// the directory the config was loaded from.
    public func resolvedRootPath(for config: WorkbenchWorkspaceConfig, configDirectory: String) -> String {
        if let configured = config.rootPath, !configured.isEmpty {
            return (configured as NSString).expandingTildeInPath
        }
        return (configDirectory as NSString).expandingTildeInPath
    }

    /// Resolve a terminal's working directory: configured value wins; ".";
    /// otherwise the workspace root.
    public func resolvedWorkingDirectory(
        for terminal: WorkbenchWorkspaceConfig.TerminalConfig,
        rootPath: String
    ) -> String {
        let raw = terminal.workingDirectory ?? ""
        if raw.isEmpty || raw == "." {
            return rootPath
        }
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return expanded
        }
        return (rootPath as NSString).appendingPathComponent(expanded)
    }

    /// Resolve a group name: configured value wins; otherwise the workspace
    /// root's last path component.
    public func resolvedGroupName(for config: WorkbenchWorkspaceConfig, rootPath: String) -> String {
        if let configured = config.group, !configured.isEmpty {
            return configured
        }
        return (rootPath as NSString).lastPathComponent
    }
}
