import Foundation

public struct BossAgentBridgePlan: Equatable, Sendable {
    public var agentName: String
    public var executable: String
    public var arguments: [String]

    public init(agentName: String, executable: String = "ouro", arguments: [String]) {
        self.agentName = agentName
        self.executable = executable
        self.arguments = arguments
    }

    public var displayCommand: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

public struct BossAgentBridgePlanner: Sendable {
    public init() {}

    public func mcpServePlan(for boss: BossAgentSelection) -> BossAgentBridgePlan {
        BossAgentBridgePlan(
            agentName: boss.agentName,
            arguments: ["mcp-serve", "--agent", boss.agentName]
        )
    }

    public func checkInQuestion(userQuestion: String? = nil) -> String {
        userQuestion ?? "Summarize what is going on, what is waiting on Ari, active terminal agents, blockers, and next actions."
    }
}

public enum BossWorkbenchMCPRegistrationStatus: String, Codable, Equatable, Sendable {
    case registered
    case notRegistered
    case needsUpdate
    case agentMissing
    case executableMissing
    case invalidConfig
}

public struct BossWorkbenchMCPRegistrationSnapshot: Equatable, Sendable {
    public var agentName: String
    public var serverName: String
    public var commandPath: String
    public var agentConfigPath: String
    public var status: BossWorkbenchMCPRegistrationStatus
    public var detail: String

    public init(
        agentName: String,
        serverName: String,
        commandPath: String,
        agentConfigPath: String,
        status: BossWorkbenchMCPRegistrationStatus,
        detail: String
    ) {
        self.agentName = agentName
        self.serverName = serverName
        self.commandPath = commandPath
        self.agentConfigPath = agentConfigPath
        self.status = status
        self.detail = detail
    }

    public var isActionable: Bool {
        status == .notRegistered || status == .needsUpdate
    }
}

public enum BossWorkbenchMCPRegistrationError: Error, Equatable, LocalizedError, Sendable {
    case emptyAgentName
    case invalidAgentName(String)
    case agentConfigMissing(String)
    case executableMissing(String)
    case invalidConfig(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .emptyAgentName:
            return "Boss agent name is empty."
        case let .invalidAgentName(agentName):
            return "Boss agent name cannot be used as a bundle name: \(agentName)"
        case let .agentConfigMissing(path):
            return "Boss agent config is missing at \(path)."
        case let .executableMissing(path):
            return "Workbench MCP executable is missing at \(path)."
        case let .invalidConfig(path):
            return "Boss agent config is not a JSON object: \(path)."
        case let .writeFailed(message):
            return message
        }
    }
}

public struct BossWorkbenchMCPRegistrar {
    public var agentBundlesURL: URL
    public var mcpExecutableURL: URL
    public var serverName: String
    public var fileManager: FileManager

    public init(
        agentBundlesURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AgentBundles", isDirectory: true),
        mcpExecutableURL: URL = BossWorkbenchMCPRegistrar.defaultMCPExecutableURL(),
        serverName: String = "ouro_workbench",
        fileManager: FileManager = .default
    ) {
        self.agentBundlesURL = agentBundlesURL
        self.mcpExecutableURL = mcpExecutableURL
        self.serverName = serverName
        self.fileManager = fileManager
    }

    public static func defaultMCPExecutableURL(
        bundleURL: URL = Bundle.main.bundleURL,
        homeURL: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let bundled = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("OuroWorkbenchMCP")
        if bundleURL.pathExtension == "app" {
            return bundled
        }
        return homeURL
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Ouro Workbench.app", isDirectory: true)
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent("OuroWorkbenchMCP")
    }

    public static func isValidAgentBundleName(_ agentName: String) -> Bool {
        guard !agentName.isEmpty,
              agentName.trimmingCharacters(in: .whitespacesAndNewlines) == agentName,
              agentName != ".",
              agentName != ".." else {
            return false
        }
        let disallowed = CharacterSet(charactersIn: "/:\\\0")
        return agentName.rangeOfCharacter(from: disallowed) == nil
    }

    public func snapshot(for boss: BossAgentSelection) -> BossWorkbenchMCPRegistrationSnapshot {
        guard Self.isValidAgentBundleName(boss.agentName) else {
            return makeSnapshot(
                agentName: boss.agentName,
                configURL: agentConfigURL(forValidAgentName: "invalid"),
                status: .invalidConfig,
                detail: "Boss agent name cannot contain path separators or surrounding whitespace."
            )
        }
        let configURL = agentConfigURL(forValidAgentName: boss.agentName)
        let commandPath = mcpExecutableURL.path
        if !fileManager.fileExists(atPath: configURL.path) {
            return makeSnapshot(
                agentName: boss.agentName,
                configURL: configURL,
                status: .agentMissing,
                detail: "Agent bundle config is missing."
            )
        }
        if !fileManager.isExecutableFile(atPath: commandPath) {
            return makeSnapshot(
                agentName: boss.agentName,
                configURL: configURL,
                status: .executableMissing,
                detail: "Install the native app so the Workbench MCP executable is available."
            )
        }
        do {
            let root = try loadRootObject(from: configURL)
            guard let mcpServers = root["mcpServers"] as? [String: Any],
                  let server = mcpServers[serverName] as? [String: Any] else {
                return makeSnapshot(
                    agentName: boss.agentName,
                    configURL: configURL,
                    status: .notRegistered,
                    detail: "Workbench MCP is not registered for this boss agent."
                )
            }
            if serverMatches(server) {
                return makeSnapshot(
                    agentName: boss.agentName,
                    configURL: configURL,
                    status: .registered,
                    detail: "Workbench MCP is registered for this boss agent."
                )
            }
            return makeSnapshot(
                agentName: boss.agentName,
                configURL: configURL,
                status: .needsUpdate,
                detail: "Workbench MCP registration points at a different command."
            )
        } catch {
            return makeSnapshot(
                agentName: boss.agentName,
                configURL: configURL,
                status: .invalidConfig,
                detail: error.localizedDescription
            )
        }
    }

    @discardableResult
    public func install(for boss: BossAgentSelection) throws -> BossWorkbenchMCPRegistrationSnapshot {
        guard !boss.agentName.isEmpty else {
            throw BossWorkbenchMCPRegistrationError.emptyAgentName
        }
        guard Self.isValidAgentBundleName(boss.agentName) else {
            throw BossWorkbenchMCPRegistrationError.invalidAgentName(boss.agentName)
        }
        let configURL = agentConfigURL(forValidAgentName: boss.agentName)
        guard fileManager.fileExists(atPath: configURL.path) else {
            throw BossWorkbenchMCPRegistrationError.agentConfigMissing(configURL.path)
        }
        guard fileManager.isExecutableFile(atPath: mcpExecutableURL.path) else {
            throw BossWorkbenchMCPRegistrationError.executableMissing(mcpExecutableURL.path)
        }
        do {
            var root = try loadRootObject(from: configURL)
            var mcpServers = root["mcpServers"] as? [String: Any] ?? [:]
            mcpServers[serverName] = [
                "command": mcpExecutableURL.path,
                "args": []
            ]
            root["mcpServers"] = mcpServers
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            var output = data
            output.append(0x0A)
            try output.write(to: configURL, options: .atomic)
        } catch let error as BossWorkbenchMCPRegistrationError {
            throw error
        } catch {
            throw BossWorkbenchMCPRegistrationError.writeFailed(error.localizedDescription)
        }
        return snapshot(for: boss)
    }

    private func agentConfigURL(forValidAgentName agentName: String) -> URL {
        agentBundlesURL
            .appendingPathComponent("\(agentName).ouro", isDirectory: true)
            .appendingPathComponent("agent.json")
    }

    private func makeSnapshot(
        agentName: String,
        configURL: URL,
        status: BossWorkbenchMCPRegistrationStatus,
        detail: String
    ) -> BossWorkbenchMCPRegistrationSnapshot {
        BossWorkbenchMCPRegistrationSnapshot(
            agentName: agentName,
            serverName: serverName,
            commandPath: mcpExecutableURL.path,
            agentConfigPath: configURL.path,
            status: status,
            detail: detail
        )
    }

    private func loadRootObject(from configURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: configURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BossWorkbenchMCPRegistrationError.invalidConfig(configURL.path)
        }
        return root
    }

    private func serverMatches(_ server: [String: Any]) -> Bool {
        guard server["command"] as? String == mcpExecutableURL.path else {
            return false
        }
        let args = server["args"] as? [String]
        return args == [] || server["args"] == nil
    }
}
