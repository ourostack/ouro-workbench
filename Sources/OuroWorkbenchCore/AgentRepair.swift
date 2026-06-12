import Foundation

/// The readiness signal a post-command verify probe returns for an agent.
///
/// This is what recovery truth is classified from — NEVER the `ouro repair` exit code. A
/// zero exit does not prove the agent's vault/provider readiness is actually healthy, and a
/// non-zero exit (or a thrown spawn) does not prove it is broken. Only the post-command
/// probe of the agent's actual readiness is trustworthy.
public enum AgentRepairProbe: String, Codable, Equatable, Sendable {
    /// The agent answered the verify probe as healthy/ready.
    case healthy
    /// The agent answered, but readiness is still degraded (a known, classifiable state).
    case degraded
    /// The agent could not be probed at all (no answer / transport failure) — unclassifiable.
    case unreachable
}

/// Recovery-truth of a single `repairAgent` cycle.
///
/// Mirrors `DaemonRecoveryTruth`: a seam-free human voice (`humanFacingLine`) vs. a raw
/// audit/debug detail (`auditDetail`, the ONE place an `ouro` verb is allowed). Always
/// classified from the POST-command verify probe, never the command's exit code.
public enum AgentRepairTruth: String, Codable, Equatable, Sendable {
    /// The verify probe reads healthy after the repair ran.
    case repaired
    /// The verify probe ran but still reads degraded — never a false "repaired".
    case stillDegraded
    /// The verify probe could not classify the agent (unreachable), or repair could not be
    /// attempted (missing explicit agent name) — a human is needed.
    case needsManual

    /// Classify purely from the post-command probe truth — never from an exit code.
    public static func classify(probe: AgentRepairProbe) -> AgentRepairTruth {
        switch probe {
        case .healthy:
            return .repaired
        case .degraded:
            return .stillDegraded
        case .unreachable:
            return .needsManual
        }
    }

    /// True only when the agent could not be brought back to readiness — the one outcome
    /// that must surface an honest manual-recovery line to the human.
    public var needsManualRecovery: Bool {
        self == .needsManual
    }

    /// Human-facing, seam-free copy. COHESIVE-PRODUCT CONTRACT: never exposes a CLI seam
    /// (`ouro`, `daemon`, raw flags) — those belong in `auditDetail` only. Names the agent
    /// so the human knows which agent was acted on.
    public func humanFacingLine(agentName: String) -> String {
        switch self {
        case .repaired:
            return "\(agentName) is back online and ready."
        case .stillDegraded:
            return "Workbench tried to get \(agentName) ready, but it still needs attention. Workbench will keep working on it."
        case .needsManual:
            return "Workbench couldn't bring \(agentName) back online automatically. Please reopen Workbench, and if it keeps happening, restart your Mac."
        }
    }

    /// Audit/debug detail line. This is the ONE surface where the raw `ouro` verb and the
    /// explicit `--agent <name>` are allowed — never the human-facing product voice.
    public func auditDetail(agentName: String) -> String {
        switch self {
        case .repaired:
            return "ran `ouro repair --agent \(agentName)`; post-command verify probe reads healthy (repaired)."
        case .stillDegraded:
            return "ran `ouro repair --agent \(agentName)`; post-command verify probe still reads degraded (still-degraded)."
        case .needsManual:
            return "ran `ouro repair --agent \(agentName)`; post-command verify probe unreachable (needs-manual)."
        }
    }
}

/// The result of a single `repairAgent` cycle.
public struct AgentRepairOutcome: Equatable, Sendable {
    /// The explicit agent name this cycle targeted (echoed for audit + UI).
    public let agentName: String
    /// The recovery-truth classification (`repaired | stillDegraded | needsManual`).
    public let truth: AgentRepairTruth
    /// Whether the repair command was actually attempted (false = guarded out on a missing
    /// explicit agent name; the command never ran).
    public let commandAttempted: Bool

    public init(agentName: String, truth: AgentRepairTruth, commandAttempted: Bool) {
        self.agentName = agentName
        self.truth = truth
        self.commandAttempted = commandAttempted
    }

    /// Human-facing, seam-free result line for surfacing in `bossAppliedActions`.
    public var humanFacingLine: String {
        truth.humanFacingLine(agentName: agentName)
    }

    /// Raw audit/debug detail (carries the `ouro` verb + explicit `--agent`).
    public var auditDetail: String {
        truth.auditDetail(agentName: agentName)
    }

    /// True only when the agent could not be brought back to readiness.
    public var needsManualRecovery: Bool {
        truth.needsManualRecovery
    }
}

/// Named + narrow headless runner for the `repairAgent` onboarding remediation.
///
/// Pure + injectable, mirroring `DaemonManager`: it takes a `runRepair` closure (spawns
/// `ouro repair --agent <name>` headlessly) and a `verifyProbe` closure (post-command
/// readiness probe). Tests inject deterministic closures; the app injects
/// `AgentRepairRunner.headlessRepair` + a `BossAgentMCPClient.status`-backed probe.
///
/// This is deliberately NOT a generic `runOuroCommand`: it is one action with its own
/// verify-probe + audit semantics. Recovery truth is ALWAYS from the probe — a thrown
/// `runRepair` does not crash `repair()` and does not short-circuit the probe.
public struct AgentRepairRunner: Sendable {
    private let runRepair: @Sendable (String) async throws -> Void
    private let verifyProbe: @Sendable (String) async -> AgentRepairProbe

    public init(
        runRepair: @escaping @Sendable (String) async throws -> Void = AgentRepairRunner.headlessRepair,
        verifyProbe: @escaping @Sendable (String) async -> AgentRepairProbe
    ) {
        self.runRepair = runRepair
        self.verifyProbe = verifyProbe
    }

    /// Run `ouro repair --agent <name>` headlessly → post-command verify probe → classify.
    ///
    /// Guards the EXPLICIT agent name first: an empty/whitespace name never runs the command
    /// (never lean on `ouro` default-agent resolution — the wrong agent could be repaired).
    public func repair(agentName: String) async -> AgentRepairOutcome {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return AgentRepairOutcome(agentName: agentName, truth: .needsManual, commandAttempted: false)
        }

        // Swallow a thrown spawn — recovery truth comes from the verify probe, not the spawn.
        try? await runRepair(trimmed)

        let probe = await verifyProbe(trimmed)
        return AgentRepairOutcome(
            agentName: trimmed,
            truth: AgentRepairTruth.classify(probe: probe),
            commandAttempted: true
        )
    }

    /// Default headless repair: spawn `ouro repair --agent <name>` and WAIT for it to exit.
    ///
    /// Mirrors the `BossAgentMCPClient` / `DaemonManager.detachedStart` spawn shape
    /// (`/usr/bin/env ouro …` + `TerminalEnvironment().valuesWithResolvedPath()`) so `ouro`
    /// resolves from a Finder-launched `.app`'s minimal PATH. No pane is spawned — this runs
    /// headlessly with stdio routed to /dev/null. Unlike the daemon start, we DO wait: repair
    /// is a finite, non-interactive remediation, and the verify probe runs after it returns.
    @Sendable
    public static func headlessRepair(agentName: String) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ouro", "repair", "--agent", agentName]
        process.environment = TerminalEnvironment().valuesWithResolvedPath()

        let devNull = FileHandle.nullDevice
        process.standardInput = devNull
        process.standardOutput = devNull
        process.standardError = devNull

        try process.run()
        process.waitUntilExit()
        // Deliberately ignore the exit status: recovery truth is the post-command probe's job.
    }
}
