import Foundation

public enum AutonomyReadinessState: String, Codable, Equatable, Sendable {
    case ready
    case attention
    case blocked
}

public enum AutonomyReadinessCheckState: String, Codable, Equatable, Sendable {
    case ok
    case warning
    case blocker
}

public struct AutonomyReadinessCheck: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var detail: String
    public var state: AutonomyReadinessCheckState

    public init(id: String, label: String, detail: String, state: AutonomyReadinessCheckState) {
        self.id = id
        self.label = label
        self.detail = detail
        self.state = state
    }
}

public struct AutonomyReadinessSnapshot: Codable, Equatable, Sendable {
    public var label: String
    public var state: AutonomyReadinessState
    public var headline: String
    public var detail: String
    public var checks: [AutonomyReadinessCheck]

    public init(label: String = "TTFA", checks: [AutonomyReadinessCheck]) {
        self.label = label
        self.checks = checks
        self.state = Self.state(for: checks)
        self.headline = Self.headline(for: state)
        self.detail = Self.detail(for: state)
    }

    public var blockerCount: Int {
        checks.filter { $0.state == .blocker }.count
    }

    public var warningCount: Int {
        checks.filter { $0.state == .warning }.count
    }

    public func appending(_ check: AutonomyReadinessCheck) -> AutonomyReadinessSnapshot {
        AutonomyReadinessSnapshot(label: label, checks: checks + [check])
    }

    private static func state(for checks: [AutonomyReadinessCheck]) -> AutonomyReadinessState {
        if checks.contains(where: { $0.state == .blocker }) {
            return .blocked
        }
        if checks.contains(where: { $0.state == .warning }) {
            return .attention
        }
        return .ready
    }

    private static func headline(for state: AutonomyReadinessState) -> String {
        switch state {
        case .ready:
            return "Boss is clear to run"
        case .attention:
            return "Autonomy is usable with watch points"
        case .blocked:
            return "Human-free operation is blocked"
        }
    }

    private static func detail(for state: AutonomyReadinessState) -> String {
        switch state {
        case .ready:
            return "The selected Ouro boss can inspect and control the Workbench, detected agent terminals are trusted, and restart recovery has no manual gaps."
        case .attention:
            return "Workbench can run, but one or more checks should be tightened before fully hands-off operation."
        case .blocked:
            return "The boss cannot fully inspect, control, or recover the Workbench until blockers are fixed."
        }
    }
}

public struct AutonomyReadinessBuilder: Sendable {
    private let presetProvider: @Sendable (TerminalAgentKind) -> TerminalAgentPreset?

    public init() {
        self.presetProvider = { TerminalAgentPresets.preset(for: $0) }
    }

    init(presetProvider: @escaping @Sendable (TerminalAgentKind) -> TerminalAgentPreset?) {
        self.presetProvider = presetProvider
    }

    public func build(
        state: WorkspaceState,
        summary: WorkspaceSummary,
        mcpRegistration: BossWorkbenchMCPRegistrationSnapshot?,
        executableHealth: [UUID: ExecutableHealth],
        bossWatchIsEnabled: Bool
    ) -> AutonomyReadinessSnapshot {
        AutonomyReadinessSnapshot(checks: [
            bossCheck(for: state.boss),
            mcpCheck(mcpRegistration),
            terminalTrustCheck(for: state),
            terminalResumeCheck(for: state),
            executableCheck(for: state, executableHealth: executableHealth),
            recoveryCheck(summary),
            bossWatchCheck(isEnabled: bossWatchIsEnabled)
        ])
    }

    private func bossCheck(for boss: BossAgentSelection) -> AutonomyReadinessCheck {
        if BossWorkbenchMCPRegistrar.isValidAgentBundleName(boss.agentName) {
            return AutonomyReadinessCheck(
                id: "boss",
                label: "Boss agent",
                detail: "\(boss.agentName) is selected.",
                state: .ok
            )
        }
        return AutonomyReadinessCheck(
            id: "boss",
            label: "Boss agent",
            detail: "The selected boss name is not a valid Ouro agent bundle name.",
            state: .blocker
        )
    }

    /// RUNTIME-INJECTION model: the Workbench tools reach the boss at runtime (Workbench passes
    /// `--workbench-mcp` when it launches the boss), so "ready" means the Workbench MCP binary is
    /// present (runtime injection available) AND the boss bundle is clean of any stale entry — not
    /// that anything is written into the synced bundle.
    private func mcpCheck(_ registration: BossWorkbenchMCPRegistrationSnapshot?) -> AutonomyReadinessCheck {
        guard let registration else {
            return AutonomyReadinessCheck(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "Workbench tools availability has not been checked.",
                state: .warning
            )
        }

        switch registration.status {
        case .registered:
            return AutonomyReadinessCheck(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "Workbench tools are available to \(registration.agentName) at runtime.",
                state: .ok
            )
        case .notRegistered:
            return AutonomyReadinessCheck(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "The Workbench tools binary isn't installed, so \(registration.agentName) can't be connected at runtime. Reinstall Workbench.",
                state: .blocker
            )
        case .needsUpdate:
            return AutonomyReadinessCheck(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "A stale Workbench entry is left in the boss bundle from an older setup and needs to be cleaned.",
                state: .blocker
            )
        case .agentMissing:
            return AutonomyReadinessCheck(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "The selected boss agent bundle is missing.",
                state: .blocker
            )
        case .executableMissing:
            return AutonomyReadinessCheck(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "The Workbench tools binary is not installed.",
                state: .blocker
            )
        case .invalidConfig:
            return AutonomyReadinessCheck(
                id: "boss-mcp",
                label: "Boss bridge",
                detail: "The selected boss agent config cannot be updated safely.",
                state: .blocker
            )
        }
    }

    private func terminalTrustCheck(for state: WorkspaceState) -> AutonomyReadinessCheck {
        let agentEntries = activeTerminalAgentEntries(in: state)
        if agentEntries.isEmpty {
            return AutonomyReadinessCheck(
                id: "terminal-trust",
                label: "Agent terminals",
                detail: "No terminal agents are open yet.",
                state: .warning
            )
        }

        let untrusted = agentEntries.filter { $0.trust != .trusted }
        if !untrusted.isEmpty {
            return AutonomyReadinessCheck(
                id: "terminal-trust",
                label: "Agent terminals",
                detail: "\(entryNames(untrusted)) \(untrusted.count == 1 ? "is" : "are") not trusted.",
                state: .blocker
            )
        }

        return AutonomyReadinessCheck(
            id: "terminal-trust",
            label: "Agent terminals",
            detail: "\(entryNames(agentEntries)) are trusted.",
            state: .ok
        )
    }

    private func terminalResumeCheck(for state: WorkspaceState) -> AutonomyReadinessCheck {
        let agentEntries = activeTerminalAgentEntries(in: state)
        if agentEntries.isEmpty {
            return AutonomyReadinessCheck(
                id: "terminal-resume",
                label: "Restart posture",
                detail: "Open agent terminals will be evaluated for resume when they exist.",
                state: .warning
            )
        }

        let manualResume = agentEntries.filter { entry in
            guard let agentKind = TerminalAgentDetector.detect(entry: entry) else {
                return false
            }
            guard let preset = presetProvider(agentKind) else {
                return false
            }
            return preset.resumeStrategy.kind == .manual
        }
        if !manualResume.isEmpty {
            return AutonomyReadinessCheck(
                id: "terminal-resume",
                label: "Restart posture",
                detail: "\(entryNames(manualResume)) \(manualResume.count == 1 ? "has" : "have") no automatic resume strategy.",
                state: .blocker
            )
        }

        let disabled = agentEntries.filter { !$0.autoResume }
        if !disabled.isEmpty {
            return AutonomyReadinessCheck(
                id: "terminal-resume",
                label: "Restart posture",
                detail: "\(entryNames(disabled)) \(disabled.count == 1 ? "has" : "have") auto-resume disabled.",
                state: .blocker
            )
        }

        return AutonomyReadinessCheck(
            id: "terminal-resume",
            label: "Restart posture",
            detail: "Terminal agents have automatic resume strategies.",
            state: .ok
        )
    }

    private func executableCheck(
        for state: WorkspaceState,
        executableHealth: [UUID: ExecutableHealth]
    ) -> AutonomyReadinessCheck {
        let agentEntries = activeTerminalAgentEntries(in: state)
        let checkedEntries = agentEntries.isEmpty ? activeTerminalEntries(in: state) : agentEntries
        let unchecked = checkedEntries.filter { executableHealth[$0.id] == nil }
        if !unchecked.isEmpty {
            return AutonomyReadinessCheck(
                id: "executables",
                label: "Executables",
                detail: "Executable health has not been checked for \(entryNames(unchecked)).",
                state: .warning
            )
        }

        let unavailable = checkedEntries.filter { entry in
            executableHealth[entry.id]?.status != .available
        }
        if !unavailable.isEmpty {
            let details = unavailable.map { entry -> String in
                let health = executableHealth[entry.id]
                return "\(entry.name): \(health?.detail ?? "not checked")"
            }
            return AutonomyReadinessCheck(
                id: "executables",
                label: "Executables",
                detail: details.joined(separator: " "),
                state: .blocker
            )
        }

        return AutonomyReadinessCheck(
            id: "executables",
            label: "Executables",
            detail: agentEntries.isEmpty ? "Configured terminal commands are available." : "Terminal agent commands are available.",
            state: .ok
        )
    }

    private func recoveryCheck(_ summary: WorkspaceSummary) -> AutonomyReadinessCheck {
        let manual = summary.recoveryPlans.filter { $0.action == .manualActionNeeded }
        if !manual.isEmpty {
            return AutonomyReadinessCheck(
                id: "recovery",
                label: "Recovery",
                detail: "\(manual.count) session\(manual.count == 1 ? "" : "s") require manual recovery.",
                state: .blocker
            )
        }

        let queued = summary.needsRecovery.filter { $0.action == .autoResume || $0.action == .respawn }
        if !queued.isEmpty {
            return AutonomyReadinessCheck(
                id: "recovery",
                label: "Recovery",
                detail: "\(queued.count) restart action\(queued.count == 1 ? "" : "s") are queued.",
                state: .warning
            )
        }

        return AutonomyReadinessCheck(
            id: "recovery",
            label: "Recovery",
            detail: "No sessions require manual recovery.",
            state: .ok
        )
    }

    private func bossWatchCheck(isEnabled: Bool) -> AutonomyReadinessCheck {
        if isEnabled {
            return AutonomyReadinessCheck(
                id: "boss-watch",
                label: "Boss watch",
                detail: "Automatic watch mode is running.",
                state: .ok
            )
        }

        return AutonomyReadinessCheck(
            id: "boss-watch",
            label: "Boss watch",
            detail: "Watch mode is paused; manual boss asks still work.",
            state: .warning
        )
    }

    private func activeTerminalAgentEntries(in state: WorkspaceState) -> [ProcessEntry] {
        state.processEntries
            .filter { !$0.isArchived && $0.kind == .terminalAgent }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func activeTerminalEntries(in state: WorkspaceState) -> [ProcessEntry] {
        state.processEntries
            .filter { !$0.isArchived && ($0.kind == .terminalAgent || $0.kind == .shell) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func entryNames(_ entries: [ProcessEntry]) -> String {
        entries.map(\.name).joined(separator: ", ")
    }

}
