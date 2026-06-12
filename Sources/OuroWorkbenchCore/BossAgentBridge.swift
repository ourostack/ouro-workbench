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
    /// The machine owner's display name, woven into check-in questions so the boss
    /// reports on the ACTUAL operator — never a hardcoded name. Resolved at the app
    /// boundary (`SessionFriend.machineOwner`); defaults neutral for previews/tests.
    public let ownerName: String

    public init(ownerName: String = "the operator") {
        self.ownerName = ownerName
    }

    /// The `ouro mcp-serve --agent <boss>` plan that launches the boss's turn.
    ///
    /// RUNTIME-INJECTION model: when `workbenchMCPPath` is supplied, the plan appends
    /// `--workbench-mcp <path>` so the `ouro` runtime injects the Workbench MCP into THIS boss's
    /// turn at runtime (per-turn, boss-aware) — nothing is written to the synced agent bundle. A
    /// non-nil but EMPTY path passes the flag path-less (`--workbench-mcp` with no value) so the
    /// `ouro` side self-discovers the binary. A `nil` path (the default) omits the flag entirely,
    /// preserving the legacy arg shape for callers that don't opt into runtime injection.
    public func mcpServePlan(
        for boss: BossAgentSelection,
        workbenchMCPPath: String? = nil
    ) -> BossAgentBridgePlan {
        BossAgentBridgePlan(
            agentName: boss.agentName,
            arguments: ["mcp-serve", "--agent"] + Self.agentAndWorkbenchArguments(
                agentName: boss.agentName,
                workbenchMCPPath: workbenchMCPPath
            )
        )
    }

    /// `[<agentName>] (+ ["--workbench-mcp", <path>] | ["--workbench-mcp"])` — the agent name
    /// followed by the optional runtime-injection flag. Shared so the spawn sites agree on the
    /// exact arg shape.
    static func agentAndWorkbenchArguments(
        agentName: String,
        workbenchMCPPath: String?
    ) -> [String] {
        guard let workbenchMCPPath else {
            return [agentName]
        }
        if workbenchMCPPath.isEmpty {
            return [agentName, "--workbench-mcp"]
        }
        return [agentName, "--workbench-mcp", workbenchMCPPath]
    }

    public func checkInQuestion(userQuestion: String? = nil) -> String {
        userQuestion ?? "Summarize what is going on, what is waiting on \(ownerName), active terminal agents, blockers, and next actions."
    }

    public func watchQuestion() -> String {
        "Watch mode check-in: summarize important workspace changes, identify anything waiting on \(ownerName), and keep trusted terminal agents moving when the next action is clear."
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

public struct BossWorkbenchMCPRegistrar: @unchecked Sendable {
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

    /// RUNTIME-INJECTION model. "Registered" no longer means "the Workbench MCP is written into
    /// the boss bundle" — under runtime injection the boss gets the Workbench tools per-turn from
    /// the `--workbench-mcp` flag Workbench passes when it launches the boss (see
    /// `BossAgentBridgePlanner.mcpServePlan`). So this snapshot reports whether RUNTIME INJECTION
    /// is AVAILABLE — i.e. the Workbench MCP binary is present on disk — and whether the bundle is
    /// CLEAN of any stale `ouro_workbench` server / `senses.workbench` entry that an older
    /// Workbench (or a sync from another machine) may have left behind:
    ///   - `.registered`     — binary present AND bundle clean (runtime injection available).
    ///   - `.needsUpdate`    — binary present BUT a stale Workbench bundle entry remains
    ///                         (cleanup-pending; `install` migrates it away).
    ///   - `.notRegistered`  — binary missing (runtime injection unavailable; reinstall Workbench).
    ///   - `.agentMissing`   — the boss bundle config is missing.
    ///   - `.invalidConfig`  — unsafe agent name or unparseable config.
    ///
    /// The boss actually HAVING the tools at runtime is confirmed separately by the handoff
    /// round-trip (`BossAgentMCPClient.status`), not by this on-disk snapshot.
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
        if !fileManager.fileExists(atPath: configURL.path) {
            return makeSnapshot(
                agentName: boss.agentName,
                configURL: configURL,
                status: .agentMissing,
                detail: "Agent bundle config is missing."
            )
        }
        if !fileManager.isExecutableFile(atPath: mcpExecutableURL.path) {
            return makeSnapshot(
                agentName: boss.agentName,
                configURL: configURL,
                status: .notRegistered,
                detail: "The Workbench tools binary isn't installed yet, so Workbench can't connect this boss at runtime. Reinstall Workbench."
            )
        }
        do {
            let root = try loadRootObject(from: configURL)
            if bundleHasStaleWorkbenchEntry(in: root) {
                return makeSnapshot(
                    agentName: boss.agentName,
                    configURL: configURL,
                    status: .needsUpdate,
                    detail: "A stale Workbench entry is left in the boss bundle from an older setup; Workbench will remove it (the tools are now injected at runtime, not stored in the bundle)."
                )
            }
            return makeSnapshot(
                agentName: boss.agentName,
                configURL: configURL,
                status: .registered,
                detail: "Workbench tools are available to this boss at runtime, and the bundle is clean."
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

    /// CLEANUP MIGRATION (not a bundle write). Under runtime injection nothing belongs in the
    /// synced bundle, so this REMOVES any stale `ouro_workbench` server from `mcpServers` and
    /// removes the `senses.workbench` entry — and writes the bundle back only if it changed.
    /// It NEVER writes the Workbench server or sense. Recovery truth is the post-cleanup snapshot
    /// (`.registered` once clean + binary present), classified by the caller — not this return.
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
        do {
            _ = try removeStaleWorkbenchEntries(at: configURL)
        } catch let error as BossWorkbenchMCPRegistrationError {
            throw error
        } catch {
            throw BossWorkbenchMCPRegistrationError.writeFailed(error.localizedDescription)
        }
        return snapshot(for: boss)
    }

    /// ALL-AGENTS CLEANUP SWEEP. Under runtime injection NOTHING belongs in ANY synced bundle —
    /// the boss gets the Workbench MCP per-turn from `--workbench-mcp`, so a stale `ouro_workbench`
    /// server or `senses.workbench` entry on *any* agent (boss or not) is just pollution that
    /// git-sync would carry to other machines and is over-permissive. `install(for:)` only cleans
    /// the boss; this runs the SAME safe per-bundle cleanup over EVERY `*.ouro` bundle under
    /// `agentBundlesURL`, regardless of who's boss.
    ///
    /// Safe + idempotent: each bundle is loaded, the two Workbench keys removed, all other keys
    /// preserved, and the file rewritten ONLY if it changed (a clean machine produces no writes).
    /// A single unreadable / missing / non-JSON bundle is skipped gracefully — it never throws and
    /// never corrupts a bundle. Returns the names of the agents whose bundles were changed (so the
    /// caller can log/verify the migration).
    @discardableResult
    public func cleanupAllAgents() -> [String] {
        guard let bundleURLs = try? fileManager.contentsOfDirectory(
            at: agentBundlesURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var changedAgents: [String] = []
        for bundleURL in bundleURLs {
            guard bundleURL.pathExtension == "ouro",
                  (try? bundleURL.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else {
                continue
            }
            let configURL = bundleURL.appendingPathComponent("agent.json")
            guard fileManager.fileExists(atPath: configURL.path) else {
                continue
            }
            // A bad bundle (garbage JSON, unwritable) is skipped — one poison bundle must not
            // abort the sweep or corrupt anything.
            if (try? removeStaleWorkbenchEntries(at: configURL)) == true {
                changedAgents.append(bundleURL.deletingPathExtension().lastPathComponent)
            }
        }
        return changedAgents.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// THE one cleanup truth, shared by `install(for:)` and `cleanupAllAgents()`. Loads the
    /// bundle, removes any `mcpServers.ouro_workbench` and `senses.workbench`, preserves every
    /// other key, and rewrites the file (atomic, stable key order, trailing newline) ONLY when
    /// something was removed. Returns whether the bundle was changed. Throws on unreadable /
    /// non-JSON / unwritable bundles so callers can decide whether to propagate (`install`) or
    /// skip (`cleanupAllAgents`).
    @discardableResult
    private func removeStaleWorkbenchEntries(at configURL: URL) throws -> Bool {
        var root = try loadRootObject(from: configURL)
        var changed = false

        if var mcpServers = root["mcpServers"] as? [String: Any],
           mcpServers[serverName] != nil {
            mcpServers.removeValue(forKey: serverName)
            root["mcpServers"] = mcpServers
            changed = true
        }
        if var senses = root["senses"] as? [String: Any],
           senses["workbench"] != nil {
            senses.removeValue(forKey: "workbench")
            root["senses"] = senses
            changed = true
        }

        if changed {
            let data = try JSONSerialization.data(
                withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            var output = data
            output.append(0x0A)
            try output.write(to: configURL, options: .atomic)
        }
        return changed
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

    /// True when the boss bundle still carries a stale Workbench entry that the runtime-injection
    /// migration should remove: either an `ouro_workbench` server in `mcpServers`, or any
    /// `senses.workbench` entry. (Under runtime injection neither belongs in the synced bundle.)
    private func bundleHasStaleWorkbenchEntry(in root: [String: Any]) -> Bool {
        if let mcpServers = root["mcpServers"] as? [String: Any], mcpServers[serverName] != nil {
            return true
        }
        if let senses = root["senses"] as? [String: Any], senses["workbench"] != nil {
            return true
        }
        return false
    }
}
