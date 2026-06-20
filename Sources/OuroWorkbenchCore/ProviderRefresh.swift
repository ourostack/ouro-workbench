import Foundation

/// Recovery-truth of a single `refreshProvider` cycle.
///
/// Mirrors `AgentRepairTruth`: a seam-free human voice vs. a raw audit/debug detail (the ONE
/// place an `ouro` verb is allowed). Always classified from the POST-command verify probe,
/// never the command's exit code — a zero exit from `ouro provider refresh` does not prove the
/// daemon actually picked up the agent's vault credentials.
public enum ProviderRefreshTruth: String, Codable, Equatable, Sendable {
    /// The post-command probe reads the agent as healthy after the refresh ran.
    case refreshed
    /// The probe ran but still reads degraded — never a false "refreshed".
    case stillDegraded
    /// The probe could not classify the agent (unreachable), or refresh could not be attempted
    /// (missing explicit agent name) — a human is needed.
    case needsManual

    /// Classify purely from the post-command probe truth — never from an exit code.
    public static func classify(probe: AgentRepairProbe) -> ProviderRefreshTruth {
        switch probe {
        case .healthy:
            return .refreshed
        case .degraded:
            return .stillDegraded
        case .unreachable:
            return .needsManual
        }
    }

    /// True only when the agent could not be refreshed automatically.
    public var needsManualRecovery: Bool {
        self == .needsManual
    }

    /// Human-facing, seam-free copy. COHESIVE-PRODUCT CONTRACT: never exposes a CLI seam.
    public func humanFacingLine(agentName: String) -> String {
        switch self {
        case .refreshed:
            return "\(agentName)'s connection is refreshed and ready."
        case .stillDegraded:
            return "Workbench refreshed \(agentName)'s connection, but it still needs attention. Workbench will keep working on it."
        case .needsManual:
            return "Workbench couldn't refresh \(agentName)'s connection automatically. You can try again — and if it keeps happening, reconnecting your provider usually clears it up."
        }
    }

    /// Audit/debug detail line — the ONE surface where the raw `ouro` verb + explicit `--agent`
    /// are allowed.
    public func auditDetail(agentName: String) -> String {
        switch self {
        case .refreshed:
            return "ran `ouro provider refresh --agent \(agentName)`; post-command verify probe reads healthy (refreshed)."
        case .stillDegraded:
            return "ran `ouro provider refresh --agent \(agentName)`; post-command verify probe still reads degraded (still-degraded)."
        case .needsManual:
            return "ran `ouro provider refresh --agent \(agentName)`; post-command verify probe unreachable (needs-manual)."
        }
    }
}

/// The result of a single `refreshProvider` cycle.
public struct ProviderRefreshOutcome: Equatable, Sendable {
    public let agentName: String
    public let truth: ProviderRefreshTruth
    public let commandAttempted: Bool

    public init(agentName: String, truth: ProviderRefreshTruth, commandAttempted: Bool) {
        self.agentName = agentName
        self.truth = truth
        self.commandAttempted = commandAttempted
    }

    public var humanFacingLine: String { truth.humanFacingLine(agentName: agentName) }
    public var auditDetail: String { truth.auditDetail(agentName: agentName) }
    public var needsManualRecovery: Bool { truth.needsManualRecovery }
}

/// Named + narrow headless runner for the `refreshProvider` onboarding remediation.
///
/// Pure + injectable, mirroring `AgentRepairRunner`. This pushes the agent's already-stored
/// vault credentials into the running daemon (`ouro provider refresh --agent <name>`) — it
/// carries NO new secret. Recovery truth is ALWAYS from the post-command probe.
public struct ProviderRefreshRunner: Sendable {
    private let runRefresh: @Sendable (String) async throws -> Void
    private let verifyProbe: @Sendable (String) async -> AgentRepairProbe

    public init(
        runRefresh: @escaping @Sendable (String) async throws -> Void = ProviderRefreshRunner.headlessRefresh,
        verifyProbe: @escaping @Sendable (String) async -> AgentRepairProbe
    ) {
        self.runRefresh = runRefresh
        self.verifyProbe = verifyProbe
    }

    /// Run `ouro provider refresh --agent <name>` headlessly → post-command verify probe →
    /// classify. Guards the EXPLICIT agent name first.
    public func refresh(agentName: String) async -> ProviderRefreshOutcome {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ProviderRefreshOutcome(agentName: agentName, truth: .needsManual, commandAttempted: false)
        }
        try? await runRefresh(trimmed)
        let probe = await verifyProbe(trimmed)
        return ProviderRefreshOutcome(
            agentName: trimmed,
            truth: ProviderRefreshTruth.classify(probe: probe),
            commandAttempted: true
        )
    }

    /// Default headless refresh: spawn `ouro provider refresh --agent <name>` and WAIT for it
    /// to exit. Mirrors `AgentRepairRunner.headlessRepair`'s spawn shape. The exit status is
    /// ignored: recovery truth is the post-command probe's job.
    @Sendable
    public static func headlessRefresh(agentName: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ouro", "provider", "refresh", "--agent", agentName]
        process.environment = TerminalEnvironment().valuesWithResolvedPath()

        let devNull = FileHandle.nullDevice
        process.standardInput = devNull
        process.standardOutput = devNull
        process.standardError = devNull

        try process.run()
        // Bound the wait so a wedged `ouro`/`node` child can't hang the refresh forever.
        ProcessWatchdog.waitUntilExit(process, timeoutSeconds: 30)
    }
}
