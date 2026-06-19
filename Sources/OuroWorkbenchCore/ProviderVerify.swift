import Foundation

/// One of the two provider lanes an Ouro agent serves: the `outward` (human-facing) lane and
/// the `inner` (agent-facing) lane. Carried explicitly on the lane-scoped onboarding actions
/// (`verifyProvider`, `selectLane`) so a remediation never has to guess which lane it targets.
public enum ProviderLane: String, Codable, Equatable, Sendable, CaseIterable {
    case outward
    case inner

    /// The `ouro check --agent <name> --lane <lane>` tokens for a lane-scoped verify. This is
    /// the lane-specific readiness probe verb (vs. the lane-less `ouro auth verify`).
    public func checkTokens(agentName: String) -> [String] {
        ["ouro", "check", "--agent", agentName, "--lane", rawValue]
    }
}

/// Recovery-truth of a single `verifyProvider` cycle.
///
/// Mirrors `AgentRepairTruth`: a seam-free human voice (`humanFacingLine`) vs. a raw
/// audit/debug detail (`auditDetail`, the ONE place an `ouro` verb is allowed). Always
/// classified from the POST-command verify probe, never the command's exit code — a zero exit
/// from `ouro auth verify` does not prove the provider credentials actually work.
public enum ProviderVerifyTruth: String, Codable, Equatable, Sendable {
    /// The post-command probe reads the provider credentials as healthy/verified.
    case verified
    /// The probe ran but the provider still reads unverified — never a false "verified".
    case stillUnverified
    /// The probe could not classify the agent (unreachable), or verify could not be attempted
    /// (missing explicit agent name) — a human is needed.
    case needsManual

    /// Classify purely from the post-command probe truth — never from an exit code.
    public static func classify(probe: AgentRepairProbe) -> ProviderVerifyTruth {
        switch probe {
        case .healthy:
            return .verified
        case .degraded:
            return .stillUnverified
        case .unreachable:
            return .needsManual
        }
    }

    /// True only when the provider could not be verified automatically — the one outcome that
    /// must surface an honest manual line to the human.
    public var needsManualRecovery: Bool {
        self == .needsManual
    }

    /// Human-facing, seam-free copy. COHESIVE-PRODUCT CONTRACT: never exposes a CLI seam
    /// (`ouro`, `daemon`, raw flags / lanes) — those belong in `auditDetail` only.
    public func humanFacingLine(agentName: String) -> String {
        switch self {
        case .verified:
            return "\(agentName)'s provider connection checks out."
        case .stillUnverified:
            return "Workbench checked \(agentName)'s provider connection, but it isn't working yet. Workbench will keep working on it."
        case .needsManual:
            return "Workbench couldn't check \(agentName)'s provider connection. You can try again — and if it keeps happening, reconnecting your provider usually clears it up."
        }
    }

    /// Audit/debug detail line. This is the ONE surface where the raw `ouro` verb, the explicit
    /// `--agent <name>`, and the lane are allowed — never the human-facing product voice. A
    /// lane-scoped verify uses `ouro check --lane`; a lane-less verify uses `ouro auth verify`.
    public func auditDetail(agentName: String, lane: ProviderLane?) -> String {
        let verb: String
        if let lane {
            verb = "ouro check --agent \(agentName) --lane \(lane.rawValue)"
        } else {
            verb = "ouro auth verify --agent \(agentName)"
        }
        switch self {
        case .verified:
            return "ran `\(verb)`; post-command verify probe reads healthy (verified)."
        case .stillUnverified:
            return "ran `\(verb)`; post-command verify probe still reads degraded (still-unverified)."
        case .needsManual:
            return "ran `\(verb)`; post-command verify probe unreachable (needs-manual)."
        }
    }
}

/// The result of a single `verifyProvider` cycle.
public struct ProviderVerifyOutcome: Equatable, Sendable {
    /// The explicit agent name this cycle targeted (echoed for audit + UI).
    public let agentName: String
    /// The optional lane this cycle targeted (nil = whole-agent `auth verify`).
    public let lane: ProviderLane?
    /// The recovery-truth classification (`verified | stillUnverified | needsManual`).
    public let truth: ProviderVerifyTruth
    /// Whether the verify command was actually attempted (false = guarded out on a missing
    /// explicit agent name; the command never ran).
    public let commandAttempted: Bool

    public init(agentName: String, lane: ProviderLane?, truth: ProviderVerifyTruth, commandAttempted: Bool) {
        self.agentName = agentName
        self.lane = lane
        self.truth = truth
        self.commandAttempted = commandAttempted
    }

    /// Human-facing, seam-free result line for surfacing in `bossAppliedActions`.
    public var humanFacingLine: String {
        truth.humanFacingLine(agentName: agentName)
    }

    /// Raw audit/debug detail (carries the `ouro` verb + explicit `--agent` + lane).
    public var auditDetail: String {
        truth.auditDetail(agentName: agentName, lane: lane)
    }

    /// True only when the provider could not be verified.
    public var needsManualRecovery: Bool {
        truth.needsManualRecovery
    }
}

/// Named + narrow headless runner for the `verifyProvider` onboarding remediation.
///
/// Pure + injectable, mirroring `AgentRepairRunner`: a `runVerify` closure (spawns
/// `ouro auth verify` / `ouro check --lane` headlessly) and a `verifyProbe` closure
/// (post-command readiness probe). Tests inject deterministic closures; the app injects
/// `ProviderVerifyRunner.headlessVerify` + a `BossAgentMCPClient.status`-backed probe.
///
/// This is deliberately NOT a generic `runOuroCommand`: it is one action with its own
/// verify-probe + audit semantics. Recovery truth is ALWAYS from the probe — a thrown
/// `runVerify` does not crash `verify()` and does not short-circuit the probe.
public struct ProviderVerifyRunner: Sendable {
    private let runVerify: @Sendable (String, ProviderLane?) async throws -> Void
    private let verifyProbe: @Sendable (String, ProviderLane?) async -> AgentRepairProbe

    public init(verifyProbe: @escaping @Sendable (String, ProviderLane?) async -> AgentRepairProbe) {
        self.init(runVerify: Self.headlessVerify, verifyProbe: verifyProbe)
    }

    public init(
        runVerify: @escaping @Sendable (String, ProviderLane?) async throws -> Void,
        verifyProbe: @escaping @Sendable (String, ProviderLane?) async -> AgentRepairProbe
    ) {
        self.runVerify = runVerify
        self.verifyProbe = verifyProbe
    }

    /// Run the verify verb headlessly → post-command verify probe → classify.
    ///
    /// Guards the EXPLICIT agent name first: an empty/whitespace name never runs the command
    /// (never lean on `ouro` default-agent resolution — the wrong agent could be probed).
    public func verify(agentName: String, lane: ProviderLane?) async -> ProviderVerifyOutcome {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ProviderVerifyOutcome(agentName: agentName, lane: lane, truth: .needsManual, commandAttempted: false)
        }

        // Swallow a thrown spawn — recovery truth comes from the verify probe, not the spawn.
        try? await runVerify(trimmed, lane)

        let probe = await verifyProbe(trimmed, lane)
        return ProviderVerifyOutcome(
            agentName: trimmed,
            lane: lane,
            truth: ProviderVerifyTruth.classify(probe: probe),
            commandAttempted: true
        )
    }

    /// Default headless verify: spawn `ouro auth verify --agent <name>` (lane-less) or
    /// `ouro check --agent <name> --lane <lane>` (lane-scoped) and WAIT for it to exit.
    ///
    /// Mirrors `AgentRepairRunner.headlessRepair` (`/usr/bin/env ouro …` +
    /// `TerminalEnvironment().valuesWithResolvedPath()`) so `ouro` resolves from a
    /// Finder-launched `.app`'s minimal PATH. No pane is spawned. The exit status is ignored:
    /// recovery truth is the post-command probe's job.
    @Sendable
    public static func headlessVerify(agentName: String, lane: ProviderLane?) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        if let lane {
            process.arguments = ["ouro", "check", "--agent", agentName, "--lane", lane.rawValue]
        } else {
            process.arguments = ["ouro", "auth", "verify", "--agent", agentName]
        }
        process.environment = TerminalEnvironment().valuesWithResolvedPath()

        let devNull = FileHandle.nullDevice
        process.standardInput = devNull
        process.standardOutput = devNull
        process.standardError = devNull

        try process.run()
        // Bound the wait so a wedged `ouro`/`node` child can't hang the verify forever.
        ProcessWatchdog.waitUntilExit(process, timeoutSeconds: 30)
        // Deliberately ignore the exit status: recovery truth is the post-command probe's job.
    }
}
