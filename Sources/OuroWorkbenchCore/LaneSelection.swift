import Foundation

/// A fully-specified lane provider/model selection — config-only, carrying NO secret.
///
/// Every field is explicit: the resolved agent name (never `ouro` default-agent resolution),
/// the lane, the provider id, and the model id. This is what `selectLane` carries: it sets a
/// lane's provider/model config; the credential itself lives in the vault and is never routed
/// through this action.
public struct LaneSelection: Equatable, Sendable {
    public let agentName: String
    public let lane: ProviderLane
    public let provider: String
    public let model: String

    public init(agentName: String, lane: ProviderLane, provider: String, model: String) {
        self.agentName = agentName
        self.lane = lane
        self.provider = provider
        self.model = model
    }

    /// The `ouro use --agent <name> --lane <lane> --provider <p> --model <m>` tokens. Config
    /// only — no credential token ever appears here.
    public var useTokens: [String] {
        ["ouro", "use", "--agent", agentName, "--lane", lane.rawValue, "--provider", provider, "--model", model]
    }
}

/// Recovery-truth of a single `selectLane` cycle.
///
/// Always classified from the POST-command verify probe, never the command's exit code — a
/// zero exit from `ouro use` does not prove the agent's lane is actually serving with the new
/// provider/model.
public enum LaneSelectionTruth: String, Codable, Equatable, Sendable {
    /// The post-command probe reads the agent as healthy after the lane was set.
    case selected
    /// The probe ran but still reads degraded — never a false "selected".
    case stillDegraded
    /// The probe could not classify the agent (unreachable), or selection could not be
    /// attempted (missing explicit agent name) — a human is needed.
    case needsManual

    /// Classify purely from the post-command probe truth — never from an exit code.
    public static func classify(probe: AgentRepairProbe) -> LaneSelectionTruth {
        switch probe {
        case .healthy:
            return .selected
        case .degraded:
            return .stillDegraded
        case .unreachable:
            return .needsManual
        }
    }

    /// True only when the lane could not be brought to readiness automatically.
    public var needsManualRecovery: Bool {
        self == .needsManual
    }

    /// Human-facing, seam-free copy. COHESIVE-PRODUCT CONTRACT: never exposes a CLI seam.
    public func humanFacingLine(selection: LaneSelection) -> String {
        switch self {
        case .selected:
            return "\(selection.agentName) is now set up with \(selection.provider) and ready."
        case .stillDegraded:
            return "Workbench set up \(selection.agentName) with \(selection.provider), but it still needs attention. Workbench will keep working on it."
        case .needsManual:
            return "Workbench couldn't finish setting up \(selection.agentName) with \(selection.provider). You can try again — and if it keeps happening, reconnecting your provider usually clears it up."
        }
    }

    /// Audit/debug detail line — the ONE surface where the raw `ouro` verb + explicit fields are
    /// allowed.
    public func auditDetail(selection: LaneSelection) -> String {
        let verb = ShellArgumentEscaper.commandLine(selection.useTokens)
        switch self {
        case .selected:
            return "ran `\(verb)`; post-command verify probe reads healthy (selected)."
        case .stillDegraded:
            return "ran `\(verb)`; post-command verify probe still reads degraded (still-degraded)."
        case .needsManual:
            return "ran `\(verb)`; post-command verify probe unreachable (needs-manual)."
        }
    }
}

/// The result of a single `selectLane` cycle.
public struct LaneSelectionOutcome: Equatable, Sendable {
    public let selection: LaneSelection
    public let truth: LaneSelectionTruth
    public let commandAttempted: Bool

    public init(selection: LaneSelection, truth: LaneSelectionTruth, commandAttempted: Bool) {
        self.selection = selection
        self.truth = truth
        self.commandAttempted = commandAttempted
    }

    public var humanFacingLine: String { truth.humanFacingLine(selection: selection) }
    public var auditDetail: String { truth.auditDetail(selection: selection) }
    public var needsManualRecovery: Bool { truth.needsManualRecovery }
}

/// Named + narrow headless runner for the `selectLane` onboarding remediation.
///
/// Pure + injectable, mirroring `AgentRepairRunner`. Config-only: it sets a lane's
/// provider/model and carries NO secret. Recovery truth is ALWAYS from the post-command probe.
public struct LaneSelectionRunner: Sendable {
    private let runSelect: @Sendable (LaneSelection) async throws -> Void
    private let verifyProbe: @Sendable (String) async -> AgentRepairProbe

    public init(verifyProbe: @escaping @Sendable (String) async -> AgentRepairProbe) {
        self.init(runSelect: Self.headlessSelect, verifyProbe: verifyProbe)
    }

    public init(
        runSelect: @escaping @Sendable (LaneSelection) async throws -> Void,
        verifyProbe: @escaping @Sendable (String) async -> AgentRepairProbe
    ) {
        self.runSelect = runSelect
        self.verifyProbe = verifyProbe
    }

    /// Run `ouro use …` headlessly → post-command verify probe → classify. Guards the EXPLICIT
    /// agent name first.
    public func select(_ selection: LaneSelection) async -> LaneSelectionOutcome {
        let trimmed = selection.agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return LaneSelectionOutcome(selection: selection, truth: .needsManual, commandAttempted: false)
        }
        try? await runSelect(selection)
        let probe = await verifyProbe(trimmed)
        return LaneSelectionOutcome(
            selection: selection,
            truth: LaneSelectionTruth.classify(probe: probe),
            commandAttempted: true
        )
    }

    /// Default headless select: spawn `ouro use …` and WAIT for it to exit. Mirrors
    /// `AgentRepairRunner.headlessRepair`'s spawn shape. The exit status is ignored: recovery
    /// truth is the post-command probe's job.
    @Sendable
    public static func headlessSelect(_ selection: LaneSelection) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = selection.useTokens
        process.environment = TerminalEnvironment().valuesWithResolvedPath()

        let devNull = FileHandle.nullDevice
        process.standardInput = devNull
        process.standardOutput = devNull
        process.standardError = devNull

        try process.run()
        // Bound the wait so a wedged `ouro`/`node` child can't hang lane selection forever.
        ProcessWatchdog.waitUntilExit(process, timeoutSeconds: 30)
    }
}
