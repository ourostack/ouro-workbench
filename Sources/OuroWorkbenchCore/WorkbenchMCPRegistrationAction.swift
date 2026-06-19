import Foundation

/// Recovery-truth of a single `registerWorkbenchMCP` cycle.
///
/// RUNTIME-INJECTION model: the action no longer registers the Workbench MCP into the boss
/// bundle. It verifies that runtime injection is AVAILABLE (the Workbench MCP binary is present)
/// and CLEANS any stale bundle entry an older Workbench left behind. Recovery truth is classified
/// from the POST-command registrar SNAPSHOT (`BossWorkbenchMCPRegistrationStatus`), never from
/// whether the registrar's cleanup threw — a thrown cleanup does not prove the bundle is dirty,
/// and a clean return does not prove the snapshot reads registered. Only the post-command
/// snapshot of the on-disk agent config + binary presence is trustworthy.
public enum WorkbenchMCPRegistrationTruth: String, Codable, Equatable, Sendable {
    /// The post-command snapshot reads registered (binary present + bundle clean → runtime
    /// injection available).
    case registered
    /// The snapshot is still cleanup-pending (`needsUpdate`: binary present but a stale bundle
    /// entry remains) — the cleanup re-runs; never a false "registered".
    case stillUnregistered
    /// The snapshot is unrecoverable automatically — the binary is missing (`notRegistered`:
    /// reinstall Workbench) or the bundle is structurally broken (`agentMissing` /
    /// `executableMissing` / `invalidConfig`), or the action could not be attempted (missing
    /// explicit agent name).
    case needsManual

    /// Classify purely from the post-command registrar snapshot — never from a throw.
    public static func classify(status: BossWorkbenchMCPRegistrationStatus) -> WorkbenchMCPRegistrationTruth {
        switch status {
        case .registered:
            return .registered
        case .needsUpdate:
            // Binary present, a stale bundle entry remains — the cleanup re-runs.
            return .stillUnregistered
        case .notRegistered, .agentMissing, .executableMissing, .invalidConfig:
            // Binary missing (`notRegistered`) is NOT auto-recoverable — the registrar can't
            // install a binary — so it is needs-manual alongside the structural failures.
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
            return "Workbench couldn't connect \(agentName) automatically. You can try again — and if it keeps happening, reconnecting your provider usually clears it up."
        }
    }

    /// Audit/debug detail line — names the agent and the Workbench MCP runtime-injection target.
    public func auditDetail(agentName: String) -> String {
        switch self {
        case .registered:
            return "verified Workbench MCP runtime injection for \(agentName) (binary present + bundle clean); post-command registrar snapshot reads registered."
        case .stillUnregistered:
            return "ran the Workbench MCP bundle cleanup for \(agentName); post-command registrar snapshot still cleanup-pending (still-unregistered)."
        case .needsManual:
            return "ran the Workbench MCP runtime-injection check for \(agentName); post-command registrar snapshot unrecoverable (needs-manual: binary missing or bundle broken)."
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
