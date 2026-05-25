import Foundation

public enum OuroAgentBundleStatus: String, Codable, Equatable, Sendable {
    case ready
    case disabled
    case missingConfig
    case invalidConfig
}

public struct OuroAgentLane: Codable, Equatable, Sendable {
    public var provider: String?
    public var model: String?

    public init(provider: String? = nil, model: String? = nil) {
        self.provider = provider
        self.model = model
    }

    public var summary: String? {
        switch (provider, model) {
        case let (provider?, model?):
            return "\(provider)/\(model)"
        case let (provider?, nil):
            return provider
        case let (nil, model?):
            return model
        case (nil, nil):
            return nil
        }
    }
}

public struct OuroAgentRecord: Equatable, Identifiable, Sendable {
    public var id: String { name }
    public var name: String
    public var bundlePath: String
    public var configPath: String
    public var status: OuroAgentBundleStatus
    public var detail: String
    public var humanFacing: OuroAgentLane?
    public var agentFacing: OuroAgentLane?

    public init(
        name: String,
        bundlePath: String,
        configPath: String,
        status: OuroAgentBundleStatus,
        detail: String,
        humanFacing: OuroAgentLane? = nil,
        agentFacing: OuroAgentLane? = nil
    ) {
        self.name = name
        self.bundlePath = bundlePath
        self.configPath = configPath
        self.status = status
        self.detail = detail
        self.humanFacing = humanFacing
        self.agentFacing = agentFacing
    }

    public var isUsableAsBoss: Bool {
        status == .ready && BossWorkbenchMCPRegistrar.isValidAgentBundleName(name)
    }

    public var summaryLine: String {
        var pieces = [detail]
        if let humanSummary = humanFacing?.summary {
            pieces.append("human \(humanSummary)")
        }
        if let agentSummary = agentFacing?.summary {
            pieces.append("agent \(agentSummary)")
        }
        return pieces.joined(separator: " · ")
    }
}

public struct OuroAgentInventory {
    public var agentBundlesURL: URL
    public var fileManager: FileManager

    public init(
        agentBundlesURL: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("AgentBundles", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.agentBundlesURL = agentBundlesURL
        self.fileManager = fileManager
    }

    public func scan() -> [OuroAgentRecord] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: agentBundlesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return urls
            .compactMap(record)
            .sorted { left, right in
                left.name.localizedCaseInsensitiveCompare(right.name) == .orderedAscending
            }
    }

    private func record(for bundleURL: URL) -> OuroAgentRecord? {
        guard bundleURL.pathExtension == "ouro",
              (try? bundleURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        else {
            return nil
        }

        let agentName = bundleURL.deletingPathExtension().lastPathComponent
        let configURL = bundleURL.appendingPathComponent("agent.json")
        guard fileManager.fileExists(atPath: configURL.path) else {
            return OuroAgentRecord(
                name: agentName,
                bundlePath: bundleURL.path,
                configPath: configURL.path,
                status: .missingConfig,
                detail: "agent.json missing"
            )
        }

        do {
            let root = try loadRootObject(from: configURL)
            let enabled = root["enabled"] as? Bool
            return OuroAgentRecord(
                name: agentName,
                bundlePath: bundleURL.path,
                configPath: configURL.path,
                status: enabled == false ? .disabled : .ready,
                detail: enabled == false ? "disabled in agent.json" : "ready",
                humanFacing: lane(in: root, keys: ["humanFacing", "outward"]),
                agentFacing: lane(in: root, keys: ["agentFacing", "inner"])
            )
        } catch {
            return OuroAgentRecord(
                name: agentName,
                bundlePath: bundleURL.path,
                configPath: configURL.path,
                status: .invalidConfig,
                detail: error.localizedDescription
            )
        }
    }

    private func loadRootObject(from configURL: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: configURL)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BossWorkbenchMCPRegistrationError.invalidConfig(configURL.path)
        }
        return root
    }

    private func lane(in root: [String: Any], keys: [String]) -> OuroAgentLane? {
        for key in keys {
            guard let object = root[key] as? [String: Any] else {
                continue
            }
            let lane = OuroAgentLane(
                provider: object["provider"] as? String,
                model: object["model"] as? String
            )
            if lane.provider != nil || lane.model != nil {
                return lane
            }
        }
        return nil
    }
}
