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

    /// Which confirm-gated control actions the Harness Status view should offer,
    /// and how prominently. Pure: derived only from the current status.
    ///
    /// - Repair daemon is *always* available (restarting a running daemon is
    ///   harmless) but only *urgent* when the daemon isn't reachable.
    /// - Register the Workbench MCP is available only when a registration could
    ///   actually land — the selected boss's MCP status is `notRegistered` /
    ///   `needsUpdate` (mirroring `BossWorkbenchMCPRegistrationSnapshot`'s own
    ///   `isActionable`). Statuses like `agentMissing` / `executableMissing` /
    ///   `invalidConfig` aren't one-click-fixable from here (you must install
    ///   the bundle or the app first), so the action is hidden rather than
    ///   offered-and-doomed. When available it's always urgent.
    public var controlOffer: HarnessControlOffer {
        let registerActionable = boss.mcpIsActionable
        return HarnessControlOffer(
            repairDaemonAvailable: true,
            repairDaemonIsUrgent: !daemon.isReachable,
            registerWorkbenchMCPAvailable: registerActionable,
            registerWorkbenchMCPIsUrgent: registerActionable
        )
    }
}

public enum HarnessHealthState: String, Equatable, Sendable {
    case healthy
    case attention
    case blocked
}

// MARK: - Control actions

/// A confirm-gated control the operator can fire from the Harness Status view
/// to fix a degraded harness. Deliberately small and non-destructive: each
/// either heals the local daemon or (re)registers the Workbench MCP — both are
/// idempotent, user-clicked, and reversible.
public enum HarnessControlAction: String, Equatable, Sendable, CaseIterable {
    /// Run the ouro daemon heal/start command (`ouro up`). The natural fix when
    /// the daemon is down or unreachable; harmless when it's already running.
    case repairDaemon
    /// Register (or refresh) the Workbench MCP with the selected boss. The fix
    /// when the boss's MCP registration is `notRegistered` / `needsUpdate`.
    case registerWorkbenchMCP
}

/// What the Harness Status view should offer the operator: which actions are
/// *available* at all, and which one (if any) is the *urgent* one to surface
/// prominently because the harness is degraded in a way that action fixes.
///
/// Pure derivation from a `HarnessStatus` so the App's button placement /
/// prominence is testable without SwiftUI. The two actions map 1:1 to the two
/// reused execution paths in the App (the ouro-command runner + the MCP
/// registrar) — this type only decides *whether* and *how prominently* to show
/// them.
public struct HarnessControlOffer: Equatable, Sendable {
    /// Repair/start the daemon. Always available (you can always (re)start it),
    /// but only *urgent* when the daemon isn't reachable.
    public var repairDaemonAvailable: Bool
    public var repairDaemonIsUrgent: Bool
    /// Register the Workbench MCP. Available only when registration could
    /// actually succeed for the selected boss (its bundle is installed) AND it
    /// isn't already registered-and-current. Urgent whenever it's available,
    /// since an unregistered/stale boss can't be driven hands-off.
    public var registerWorkbenchMCPAvailable: Bool
    public var registerWorkbenchMCPIsUrgent: Bool

    public init(
        repairDaemonAvailable: Bool,
        repairDaemonIsUrgent: Bool,
        registerWorkbenchMCPAvailable: Bool,
        registerWorkbenchMCPIsUrgent: Bool
    ) {
        self.repairDaemonAvailable = repairDaemonAvailable
        self.repairDaemonIsUrgent = repairDaemonIsUrgent
        self.registerWorkbenchMCPAvailable = registerWorkbenchMCPAvailable
        self.registerWorkbenchMCPIsUrgent = registerWorkbenchMCPIsUrgent
    }

    /// Whether `action` should be shown at all.
    public func isAvailable(_ action: HarnessControlAction) -> Bool {
        switch action {
        case .repairDaemon:
            return repairDaemonAvailable
        case .registerWorkbenchMCP:
            return registerWorkbenchMCPAvailable
        }
    }

    /// Whether `action` should be surfaced prominently (the harness is degraded
    /// in a way this action fixes) rather than as a secondary control.
    public func isUrgent(_ action: HarnessControlAction) -> Bool {
        switch action {
        case .repairDaemon:
            return repairDaemonIsUrgent
        case .registerWorkbenchMCP:
            return registerWorkbenchMCPIsUrgent
        }
    }

    /// True when at least one action is urgent — i.e. the operator has a clear
    /// next step to un-degrade the harness from this view.
    public var hasUrgentAction: Bool {
        repairDaemonIsUrgent || registerWorkbenchMCPIsUrgent
    }
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
            return "No Ouro agents are installed on this machine yet"
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

    /// Whether a one-click "register Workbench MCP" would actually do something
    /// useful for this boss: its registration is missing or stale. Mirrors
    /// `BossWorkbenchMCPRegistrationSnapshot.isActionable`. Statuses where the
    /// registrar can't succeed (no bundle, no app, bad config) are *not*
    /// actionable from the status view — those need a different fix first.
    public var mcpIsActionable: Bool {
        mcpStatus == .notRegistered || mcpStatus == .needsUpdate
    }

    public var state: HarnessHealthState {
        if isReachable {
            return .healthy
        }
        switch mcpStatus {
        case .needsUpdate:
            // Binary present, only a stale bundle entry remains — runtime injection still works
            // today (the flag is passed regardless of the bundle); worth a cleanup nudge.
            return bundleIsReady ? .attention : .blocked
        case .none:
            return .attention
        default:
            return .blocked
        }
    }

    /// RUNTIME-INJECTION model: the Workbench tools reach the boss at runtime, so this status
    /// reflects whether runtime injection is available (binary present + bundle clean), not a
    /// bundle registration.
    public var mcpStatusText: String {
        guard let mcpStatus else {
            return "unknown"
        }
        switch mcpStatus {
        case .registered:
            return "available at runtime"
        case .notRegistered:
            return "tools binary missing"
        case .needsUpdate:
            return "stale entry to clean"
        case .agentMissing:
            return "agent bundle missing"
        case .executableMissing:
            return "install app first"
        case .invalidConfig:
            return "config issue"
        case .toolsNotInjected:
            return "tools didn't load — update ouro"
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
