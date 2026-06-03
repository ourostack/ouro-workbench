import Foundation

/// Read-only, consolidated view of the ouro-harness state an operator cares
/// about, in one place: daemon health, the local agent inventory, and the
/// selected boss's MCP-registration / reachability.
///
/// This is a *pure aggregation* of reads that already exist elsewhere in the
/// Workbench — the boss dashboard (`BossDashboardSnapshot`, which carries the
/// daemon summary from `/api/machine`), the onboarding agent scan
/// (`OuroAgentInventory` → `[OuroAgentRecord]`), and the MCP registrar
/// (`BossWorkbenchMCPRegistrationSnapshot`). It does no IO of its own and
/// never shells out: the App gathers the live snapshots (watchdog-bounded,
/// off the main actor) and feeds them in, mirroring how `BossDashboardBuilder`
/// and `AutonomyReadinessBuilder` are driven. That keeps the formatting logic
/// trivially testable with fixtures.
public struct HarnessStatus: Equatable, Sendable {
    public var daemon: HarnessDaemonStatus
    public var agents: HarnessAgentInventory
    public var boss: HarnessBossReachability
    /// When the underlying snapshots were observed (the daemon's `observedAt`,
    /// if the machine read succeeded). Display-only.
    public var observedAt: String?

    public init(
        daemon: HarnessDaemonStatus,
        agents: HarnessAgentInventory,
        boss: HarnessBossReachability,
        observedAt: String?
    ) {
        self.daemon = daemon
        self.agents = agents
        self.boss = boss
        self.observedAt = observedAt
    }

    /// One-line roll-up suitable for a sheet subtitle. Leads with the most
    /// actionable problem (daemon down > boss unreachable), otherwise a calm
    /// "everything's up" summary.
    public var headline: String {
        if !daemon.isReachable {
            return "ouro daemon is \(daemon.statusText)"
        }
        if !boss.isReachable {
            return "Boss \(boss.agentName) is not reachable"
        }
        let readyText = "\(agents.readyCount) of \(agents.total) agent\(agents.total == 1 ? "" : "s") ready"
        return "Daemon up · \(readyText) · boss \(boss.agentName) reachable"
    }

    public var overallState: HarnessHealthState {
        if !daemon.isReachable || !boss.isReachable {
            return .blocked
        }
        if daemon.state == .attention || boss.state == .attention || agents.hasUnready {
            return .attention
        }
        return .healthy
    }
}

public enum HarnessHealthState: String, Equatable, Sendable {
    case healthy
    case attention
    case blocked
}

// MARK: - Daemon

public struct HarnessDaemonStatus: Equatable, Sendable {
    /// Raw daemon status string from the machine read (e.g. "running",
    /// "unknown"). `nil` when the machine read failed entirely (daemon down /
    /// mailbox unreachable).
    public var status: String?
    public var mode: String?
    /// The harness runtime version, when the machine read surfaced it.
    public var version: String?
    /// Set when the underlying machine read failed (timeout / connection
    /// refused), so we can show *why* the daemon looks down rather than just
    /// "unknown".
    public var unavailableReason: String?

    public init(
        status: String?,
        mode: String? = nil,
        version: String? = nil,
        unavailableReason: String? = nil
    ) {
        self.status = status
        self.mode = mode
        self.version = version
        self.unavailableReason = unavailableReason
    }

    /// The daemon is considered reachable only when the machine read succeeded
    /// AND reported a "running"-class status. A failed read or an explicit
    /// non-running status both count as not reachable.
    public var isReachable: Bool {
        guard unavailableReason == nil, let status else {
            return false
        }
        return status.caseInsensitiveCompare("running") == .orderedSame
            || status.caseInsensitiveCompare("ok") == .orderedSame
    }

    public var state: HarnessHealthState {
        if isReachable {
            return .healthy
        }
        // A successful read that reports a non-running status is "attention"
        // (the daemon answered but isn't running); a failed read is "blocked".
        return unavailableReason == nil && status != nil ? .attention : .blocked
    }

    public var statusText: String {
        if let unavailableReason {
            return "unreachable (\(unavailableReason))"
        }
        guard let status, !status.isEmpty else {
            return "unknown"
        }
        return status
    }

    public var versionText: String {
        guard let version, !version.isEmpty else {
            return "unknown"
        }
        return version
    }

    public var modeText: String {
        guard let mode, !mode.isEmpty else {
            return "unknown"
        }
        return mode
    }
}

// MARK: - Agents

public struct HarnessAgentEntry: Equatable, Identifiable, Sendable {
    public var name: String
    public var status: OuroAgentBundleStatus
    public var detail: String
    public var isSelectedBoss: Bool
    /// MCP-registration status for this specific agent, when known.
    public var mcpStatus: BossWorkbenchMCPRegistrationStatus?

    public var id: String { name }

    public init(
        name: String,
        status: OuroAgentBundleStatus,
        detail: String,
        isSelectedBoss: Bool,
        mcpStatus: BossWorkbenchMCPRegistrationStatus? = nil
    ) {
        self.name = name
        self.status = status
        self.detail = detail
        self.isSelectedBoss = isSelectedBoss
        self.mcpStatus = mcpStatus
    }

    public var isReady: Bool {
        status == .ready
    }
}

public struct HarnessAgentInventory: Equatable, Sendable {
    public var entries: [HarnessAgentEntry]

    public init(entries: [HarnessAgentEntry]) {
        self.entries = entries
    }

    public var total: Int { entries.count }
    public var readyCount: Int { entries.filter(\.isReady).count }
    public var hasUnready: Bool { entries.contains { !$0.isReady } }
    public var isEmpty: Bool { entries.isEmpty }

    public var summaryLine: String {
        guard !entries.isEmpty else {
            return "No local agents found in ~/AgentBundles"
        }
        return "\(total) local, \(readyCount) ready"
    }

    /// The entry flagged as the selected Workbench boss, if it's present in the
    /// local inventory. Absent when the persisted boss has no installed bundle.
    public var selectedBoss: HarnessAgentEntry? {
        entries.first(where: \.isSelectedBoss)
    }
}

// MARK: - Boss reachability

public struct HarnessBossReachability: Equatable, Sendable {
    public var agentName: String
    /// Whether the selected boss appears in the local agent inventory as a
    /// ready bundle. A boss with no installed (or non-ready) bundle is not
    /// reachable.
    public var bundleIsReady: Bool
    public var mcpStatus: BossWorkbenchMCPRegistrationStatus?
    public var mcpDetail: String?

    public init(
        agentName: String,
        bundleIsReady: Bool,
        mcpStatus: BossWorkbenchMCPRegistrationStatus?,
        mcpDetail: String? = nil
    ) {
        self.agentName = agentName
        self.bundleIsReady = bundleIsReady
        self.mcpStatus = mcpStatus
        self.mcpDetail = mcpDetail
    }

    /// The boss is reachable when its bundle is installed + ready AND its
    /// Workbench MCP is registered. Anything less means the boss can't be
    /// driven hands-off.
    public var isReachable: Bool {
        bundleIsReady && mcpStatus == .registered
    }

    public var state: HarnessHealthState {
        if isReachable {
            return .healthy
        }
        switch mcpStatus {
        case .needsUpdate:
            // Registered but stale — usable today, worth a nudge.
            return bundleIsReady ? .attention : .blocked
        case .none:
            return .attention
        default:
            return .blocked
        }
    }

    public var mcpStatusText: String {
        guard let mcpStatus else {
            return "unknown"
        }
        switch mcpStatus {
        case .registered:
            return "registered"
        case .notRegistered:
            return "not registered"
        case .needsUpdate:
            return "update needed"
        case .agentMissing:
            return "agent bundle missing"
        case .executableMissing:
            return "install app first"
        case .invalidConfig:
            return "config issue"
        }
    }

    public var bundleText: String {
        bundleIsReady ? "installed and ready" : "missing or not ready"
    }
}

// MARK: - Builder

public struct HarnessStatusBuilder: Sendable {
    public init() {}

    /// Aggregate the three harness sections from snapshots the App already
    /// gathers. All inputs are optional/nilable so a partial read (e.g. daemon
    /// down, agents still scannable from disk) still produces a coherent view.
    ///
    /// - Parameters:
    ///   - boss: The selected Workbench boss.
    ///   - dashboard: The latest boss-dashboard snapshot (carries the daemon
    ///     summary + availability). `nil` before the first refresh.
    ///   - agents: The local agent inventory from `OuroAgentInventory.scan()`.
    ///   - bossRegistration: MCP-registration snapshot for the selected boss.
    ///   - registrationByAgentName: Per-agent MCP-registration snapshots, so
    ///     each inventory row can show its own registration status.
    public func build(
        boss: BossAgentSelection,
        dashboard: BossDashboardSnapshot?,
        agents: [OuroAgentRecord],
        bossRegistration: BossWorkbenchMCPRegistrationSnapshot?,
        registrationByAgentName: [String: BossWorkbenchMCPRegistrationSnapshot] = [:]
    ) -> HarnessStatus {
        let daemon = daemonStatus(dashboard: dashboard)
        let inventory = agentInventory(
            boss: boss,
            agents: agents,
            registrationByAgentName: registrationByAgentName
        )
        let reachability = bossReachability(
            boss: boss,
            inventory: inventory,
            bossRegistration: bossRegistration
        )
        return HarnessStatus(
            daemon: daemon,
            agents: inventory,
            boss: reachability,
            observedAt: dashboard?.observedAt
        )
    }

    private func daemonStatus(dashboard: BossDashboardSnapshot?) -> HarnessDaemonStatus {
        guard let dashboard else {
            return HarnessDaemonStatus(
                status: nil,
                unavailableReason: "not checked yet"
            )
        }
        // When the machine read failed, the dashboard records it in
        // `availability` (machineAvailable == false) and leaves daemonStatus at
        // the "unknown" sentinel. Surface the failure as unreachable rather
        // than a bare "unknown", reusing the dashboard's own issue text.
        if !dashboard.availability.machineAvailable {
            return HarnessDaemonStatus(
                status: nil,
                mode: nil,
                version: dashboard.daemonVersion,
                unavailableReason: machineIssueText(dashboard.availability.issues)
            )
        }
        return HarnessDaemonStatus(
            status: dashboard.daemonStatus,
            mode: dashboard.daemonMode,
            version: dashboard.daemonVersion
        )
    }

    private func machineIssueText(_ issues: [String]) -> String {
        // The dashboard collects issues like "machine: <error>"; prefer the
        // machine one, else fall back to a generic phrasing.
        if let machineIssue = issues.first(where: { $0.hasPrefix("machine:") }) {
            return machineIssue
                .replacingOccurrences(of: "machine:", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        return "mailbox did not answer"
    }

    private func agentInventory(
        boss: BossAgentSelection,
        agents: [OuroAgentRecord],
        registrationByAgentName: [String: BossWorkbenchMCPRegistrationSnapshot]
    ) -> HarnessAgentInventory {
        let entries = agents.map { agent -> HarnessAgentEntry in
            HarnessAgentEntry(
                name: agent.name,
                status: agent.status,
                detail: agent.detail,
                isSelectedBoss: agent.name.caseInsensitiveCompare(boss.agentName) == .orderedSame,
                mcpStatus: registrationByAgentName[agent.name]?.status
            )
        }
        return HarnessAgentInventory(entries: entries)
    }

    private func bossReachability(
        boss: BossAgentSelection,
        inventory: HarnessAgentInventory,
        bossRegistration: BossWorkbenchMCPRegistrationSnapshot?
    ) -> HarnessBossReachability {
        let bossEntry = inventory.entries.first {
            $0.name.caseInsensitiveCompare(boss.agentName) == .orderedSame
        }
        return HarnessBossReachability(
            agentName: boss.agentName,
            bundleIsReady: bossEntry?.isReady ?? false,
            mcpStatus: bossRegistration?.status,
            mcpDetail: bossRegistration?.detail
        )
    }
}
