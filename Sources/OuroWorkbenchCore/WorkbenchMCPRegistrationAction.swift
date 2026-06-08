import Foundation

/// Recovery-truth of a single `registerWorkbenchMCP` cycle.
///
/// Classified from the POST-command registrar SNAPSHOT (`BossWorkbenchMCPRegistrationStatus`),
/// never from whether the registrar's `install` threw — a thrown install does not prove the
/// config is unregistered, and a clean return does not prove the snapshot reads registered.
/// Only the post-command snapshot of the on-disk agent config is trustworthy.
public enum WorkbenchMCPRegistrationTruth: String, Codable, Equatable, Sendable {
    /// The post-command snapshot reads registered.
    case registered
    /// The snapshot is still actionable (`notRegistered` / `needsUpdate`) — never a false
    /// "registered".
    case stillUnregistered
    /// The snapshot is unrecoverable automatically (`agentMissing` / `executableMissing` /
    /// `invalidConfig`), or registration could not be attempted (missing explicit agent name).
    case needsManual

    /// Classify purely from the post-command registrar snapshot — never from a throw.
    public static func classify(status: BossWorkbenchMCPRegistrationStatus) -> WorkbenchMCPRegistrationTruth {
        switch status {
        case .registered:
            return .registered
        case .notRegistered, .needsUpdate:
            return .stillUnregistered
        case .agentMissing, .executableMissing, .invalidConfig:
            return .needsManual
        }
    }

    /// True only when registration could not be completed automatically.
    public var needsManualRecovery: Bool {
        self == .needsManual
    }

    /// Human-facing, seam-free copy. COHESIVE-PRODUCT CONTRACT: never exposes a CLI seam
    /// (`ouro`, `mcp`, `daemon`). The agent "connecting to Workbench" is the product framing.
    public func humanFacingLine(agentName: String) -> String {
        switch self {
        case .registered:
            return "\(agentName) is connected to Workbench and ready."
        case .stillUnregistered:
            return "Workbench is connecting \(agentName), but it isn't ready yet. Workbench will keep working on it."
        case .needsManual:
            return "Workbench couldn't connect \(agentName) automatically. Please reinstall Workbench, and if it keeps happening, restart your Mac."
        }
    }

    /// Audit/debug detail line — names the agent and the Workbench MCP registration target.
    public func auditDetail(agentName: String) -> String {
        switch self {
        case .registered:
            return "registered the Workbench MCP for \(agentName); post-command registrar snapshot reads registered."
        case .stillUnregistered:
            return "ran the Workbench MCP registration for \(agentName); post-command registrar snapshot still actionable (still-unregistered)."
        case .needsManual:
            return "ran the Workbench MCP registration for \(agentName); post-command registrar snapshot unrecoverable (needs-manual)."
        }
    }
}

/// The result of a single `registerWorkbenchMCP` cycle.
public struct WorkbenchMCPRegistrationOutcome: Equatable, Sendable {
    public let agentName: String
    public let truth: WorkbenchMCPRegistrationTruth
    public let commandAttempted: Bool

    public init(agentName: String, truth: WorkbenchMCPRegistrationTruth, commandAttempted: Bool) {
        self.agentName = agentName
        self.truth = truth
        self.commandAttempted = commandAttempted
    }

    public var humanFacingLine: String { truth.humanFacingLine(agentName: agentName) }
    public var auditDetail: String { truth.auditDetail(agentName: agentName) }
    public var needsManualRecovery: Bool { truth.needsManualRecovery }
}

/// Named + narrow runner for the `registerWorkbenchMCP` onboarding remediation.
///
/// Pure + injectable, mirroring `AgentRepairRunner`. It WRAPS the existing headless in-app
/// registrar (`BossWorkbenchMCPRegistrar.install`) as an agent-issuable action: the app injects
/// `runRegister` (the registrar install for the explicit agent) and `snapshotProbe` (the
/// registrar's post-command snapshot status). Recovery truth is ALWAYS from the snapshot — a
/// thrown install does not crash `register()` and does not short-circuit the snapshot probe.
public struct WorkbenchMCPRegistrationRunner: Sendable {
    private let runRegister: @Sendable (String) async throws -> Void
    private let snapshotProbe: @Sendable (String) async -> BossWorkbenchMCPRegistrationStatus

    public init(
        runRegister: @escaping @Sendable (String) async throws -> Void,
        snapshotProbe: @escaping @Sendable (String) async -> BossWorkbenchMCPRegistrationStatus
    ) {
        self.runRegister = runRegister
        self.snapshotProbe = snapshotProbe
    }

    /// Run the registrar install headlessly → post-command snapshot probe → classify. Guards the
    /// EXPLICIT agent name first.
    public func register(agentName: String) async -> WorkbenchMCPRegistrationOutcome {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return WorkbenchMCPRegistrationOutcome(agentName: agentName, truth: .needsManual, commandAttempted: false)
        }
        try? await runRegister(trimmed)
        let status = await snapshotProbe(trimmed)
        return WorkbenchMCPRegistrationOutcome(
            agentName: trimmed,
            truth: WorkbenchMCPRegistrationTruth.classify(status: status),
            commandAttempted: true
        )
    }
}
