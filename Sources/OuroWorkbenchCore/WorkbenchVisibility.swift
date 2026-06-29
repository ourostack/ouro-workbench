import Foundation
import Darwin

public enum WorkbenchVisibilityStatus: String, Codable, Equatable, Sendable {
    case available
    case degraded
    case unavailable
}

public struct WorkbenchVisibilityIssue: Codable, Equatable, Sendable {
    public var code: String
    public var severity: String
    public var source: String
    public var detail: String

    public init(code: String, severity: String, source: String, detail: String) {
        self.code = code
        self.severity = severity
        self.source = source
        self.detail = detail
    }
}

/// The boss-actionable recovery breakdown carried on the visibility snapshot
/// (#U28): the four classes the boss may act on differently, sourced from the
/// recovery PLANS (not raw `.needsRecovery` status), so the boss knows what it
/// may self-trigger via `request_action` vs what it must surface to the operator.
/// The four sum to `recoverableSessions` (the digest's actionable total).
public struct RecoveryBreakdownVisibility: Codable, Equatable, Sendable {
    public var reattach: Int
    public var autoResume: Int
    public var respawn: Int
    public var needsHuman: Int
    /// Everything the boss may self-execute (reattach + auto_resume + respawn).
    public var bossActionable: Int

    public init(reattach: Int, autoResume: Int, respawn: Int, needsHuman: Int, bossActionable: Int) {
        self.reattach = reattach
        self.autoResume = autoResume
        self.respawn = respawn
        self.needsHuman = needsHuman
        self.bossActionable = bossActionable
    }

    public init(_ breakdown: RecoveryBreakdown) {
        self.init(
            reattach: breakdown.reattach,
            autoResume: breakdown.resume,
            respawn: breakdown.respawn,
            needsHuman: breakdown.needsHuman,
            bossActionable: breakdown.bossActionable
        )
    }
}

public struct WorkbenchWorkspaceVisibility: Codable, Equatable, Sendable {
    public var activeSessions: Int
    public var runningSessions: Int
    public var waitingOnHumanSessions: Int
    public var blockedSessions: Int
    public var needsBossReviewSessions: Int
    /// Boss-actionable recovery TOTAL — sourced from the recovery plans (not raw
    /// `.needsRecovery` status), so human-only manual recoveries no longer inflate
    /// it (#U28). Equals `recovery.reattach + autoResume + respawn + needsHuman`.
    public var recoverableSessions: Int
    /// The per-class split of `recoverableSessions` so the boss knows which it may
    /// self-trigger vs escalate (#U28).
    public var recovery: RecoveryBreakdownVisibility

    public init(
        activeSessions: Int,
        runningSessions: Int,
        waitingOnHumanSessions: Int,
        blockedSessions: Int,
        needsBossReviewSessions: Int,
        recoverableSessions: Int,
        recovery: RecoveryBreakdownVisibility
    ) {
        self.activeSessions = activeSessions
        self.runningSessions = runningSessions
        self.waitingOnHumanSessions = waitingOnHumanSessions
        self.blockedSessions = blockedSessions
        self.needsBossReviewSessions = needsBossReviewSessions
        self.recoverableSessions = recoverableSessions
        self.recovery = recovery
    }
}

public struct WorkbenchDecisionVisibility: Codable, Equatable, Sendable {
    public var openInbox: Int
    public var recentActions: Int
    public var failedRecentActions: Int

    public init(openInbox: Int, recentActions: Int, failedRecentActions: Int) {
        self.openInbox = openInbox
        self.recentActions = recentActions
        self.failedRecentActions = failedRecentActions
    }
}

public struct WorkbenchVisibilityReadiness: Codable, Equatable, Sendable {
    public var status: WorkbenchVisibilityStatus
    public var issues: [WorkbenchVisibilityIssue]

    public init(status: WorkbenchVisibilityStatus, issues: [WorkbenchVisibilityIssue]) {
        self.status = status
        self.issues = issues
    }
}

public struct WorkbenchVisibilitySnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var generatedAt: Date
    public var bossAgent: String
    public var workspace: WorkbenchWorkspaceVisibility
    public var agentWork: AgentWorkVisibility
    public var decisions: WorkbenchDecisionVisibility
    public var readiness: WorkbenchVisibilityReadiness

    public init(
        schemaVersion: Int = 1,
        generatedAt: Date,
        bossAgent: String,
        workspace: WorkbenchWorkspaceVisibility,
        agentWork: AgentWorkVisibility,
        decisions: WorkbenchDecisionVisibility,
        readiness: WorkbenchVisibilityReadiness
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.bossAgent = bossAgent
        self.workspace = workspace
        self.agentWork = agentWork
        self.decisions = decisions
        self.readiness = readiness
    }
}

public struct AgentWorkVisibility: Codable, Equatable, Sendable {
    public var status: WorkbenchVisibilityStatus
    public var agent: String
    public var generatedAt: String?
    public var projectionOwner: String?
    public var counts: AgentWorkCountsVisibility
    public var claims: AgentWorkClaimsVisibility
    public var nextAction: AgentWorkNextActionVisibility
    public var sources: [OuroWorkCardSource]
    public var issues: [WorkbenchVisibilityIssue]

    public init(
        status: WorkbenchVisibilityStatus,
        agent: String,
        generatedAt: String?,
        projectionOwner: String?,
        counts: AgentWorkCountsVisibility,
        claims: AgentWorkClaimsVisibility,
        nextAction: AgentWorkNextActionVisibility,
        sources: [OuroWorkCardSource],
        issues: [WorkbenchVisibilityIssue]
    ) {
        self.status = status
        self.agent = agent
        self.generatedAt = generatedAt
        self.projectionOwner = projectionOwner
        self.counts = counts
        self.claims = claims
        self.nextAction = nextAction
        self.sources = sources
        self.issues = issues
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case agent
        case generatedAt
        case projectionOwner
        case counts
        case claims
        case nextAction
        case sources
        case issues
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.status = try container.decode(WorkbenchVisibilityStatus.self, forKey: .status)
        self.agent = try container.decode(String.self, forKey: .agent)
        self.generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        self.projectionOwner = try container.decodeIfPresent(String.self, forKey: .projectionOwner)
        self.counts = try container.decode(AgentWorkCountsVisibility.self, forKey: .counts)
        self.claims = try container.decode(AgentWorkClaimsVisibility.self, forKey: .claims)
        self.nextAction = try container.decode(AgentWorkNextActionVisibility.self, forKey: .nextAction)
        self.sources = try container.decode([OuroWorkCardSource].self, forKey: .sources)
        self.issues = try container.decode([WorkbenchVisibilityIssue].self, forKey: .issues)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status, forKey: .status)
        try container.encode(agent, forKey: .agent)
        try encodeNullable(generatedAt, to: &container, forKey: .generatedAt)
        try encodeNullable(projectionOwner, to: &container, forKey: .projectionOwner)
        try container.encode(counts, forKey: .counts)
        try container.encode(claims, forKey: .claims)
        try container.encode(nextAction, forKey: .nextAction)
        try container.encode(sources, forKey: .sources)
        try container.encode(issues, forKey: .issues)
    }

    private func encodeNullable<T: Encodable>(
        _ value: T?,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

public struct AgentWorkCountsVisibility: Codable, Equatable, Sendable {
    public var owed: Int?
    public var returnObligations: Int?
    public var activePackets: Int?
    public var evolutionCases: Int?
    public var waitingOnHuman: Int?
    public var unverifiedClaims: Int?
    public var staleRiskyClaims: Int?

    public init(
        owed: Int?,
        returnObligations: Int?,
        activePackets: Int?,
        evolutionCases: Int?,
        waitingOnHuman: Int?,
        unverifiedClaims: Int?,
        staleRiskyClaims: Int?
    ) {
        self.owed = owed
        self.returnObligations = returnObligations
        self.activePackets = activePackets
        self.evolutionCases = evolutionCases
        self.waitingOnHuman = waitingOnHuman
        self.unverifiedClaims = unverifiedClaims
        self.staleRiskyClaims = staleRiskyClaims
    }

    public static let unavailable = AgentWorkCountsVisibility(
        owed: nil,
        returnObligations: nil,
        activePackets: nil,
        evolutionCases: nil,
        waitingOnHuman: nil,
        unverifiedClaims: nil,
        staleRiskyClaims: nil
    )

    private enum CodingKeys: String, CodingKey {
        case owed
        case returnObligations
        case activePackets
        case evolutionCases
        case waitingOnHuman
        case unverifiedClaims
        case staleRiskyClaims
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.owed = try container.decodeIfPresent(Int.self, forKey: .owed)
        self.returnObligations = try container.decodeIfPresent(Int.self, forKey: .returnObligations)
        self.activePackets = try container.decodeIfPresent(Int.self, forKey: .activePackets)
        self.evolutionCases = try container.decodeIfPresent(Int.self, forKey: .evolutionCases)
        self.waitingOnHuman = try container.decodeIfPresent(Int.self, forKey: .waitingOnHuman)
        self.unverifiedClaims = try container.decodeIfPresent(Int.self, forKey: .unverifiedClaims)
        self.staleRiskyClaims = try container.decodeIfPresent(Int.self, forKey: .staleRiskyClaims)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try encodeNullable(owed, to: &container, forKey: .owed)
        try encodeNullable(returnObligations, to: &container, forKey: .returnObligations)
        try encodeNullable(activePackets, to: &container, forKey: .activePackets)
        try encodeNullable(evolutionCases, to: &container, forKey: .evolutionCases)
        try encodeNullable(waitingOnHuman, to: &container, forKey: .waitingOnHuman)
        try encodeNullable(unverifiedClaims, to: &container, forKey: .unverifiedClaims)
        try encodeNullable(staleRiskyClaims, to: &container, forKey: .staleRiskyClaims)
    }

    private func encodeNullable(
        _ value: Int?,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

public struct AgentWorkClaimsVisibility: Codable, Equatable, Sendable {
    public var available: Bool
    public var unavailableReason: String?
    public var unverified: Int?
    public var partial: Int?
    public var failed: Int?
    public var unverifiable: Int?
    public var staleRisky: Int?
    public var verified: Int?

    public init(
        available: Bool,
        unavailableReason: String?,
        unverified: Int?,
        partial: Int?,
        failed: Int?,
        unverifiable: Int?,
        staleRisky: Int?,
        verified: Int?
    ) {
        self.available = available
        self.unavailableReason = unavailableReason
        self.unverified = unverified
        self.partial = partial
        self.failed = failed
        self.unverifiable = unverifiable
        self.staleRisky = staleRisky
        self.verified = verified
    }

    public static func unavailable(reason: String?) -> AgentWorkClaimsVisibility {
        AgentWorkClaimsVisibility(
            available: false,
            unavailableReason: reason,
            unverified: nil,
            partial: nil,
            failed: nil,
            unverifiable: nil,
            staleRisky: nil,
            verified: nil
        )
    }

    private enum CodingKeys: String, CodingKey {
        case available
        case unavailableReason
        case unverified
        case partial
        case failed
        case unverifiable
        case staleRisky
        case verified
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.available = try container.decode(Bool.self, forKey: .available)
        self.unavailableReason = try container.decodeIfPresent(String.self, forKey: .unavailableReason)
        self.unverified = try container.decodeIfPresent(Int.self, forKey: .unverified)
        self.partial = try container.decodeIfPresent(Int.self, forKey: .partial)
        self.failed = try container.decodeIfPresent(Int.self, forKey: .failed)
        self.unverifiable = try container.decodeIfPresent(Int.self, forKey: .unverifiable)
        self.staleRisky = try container.decodeIfPresent(Int.self, forKey: .staleRisky)
        self.verified = try container.decodeIfPresent(Int.self, forKey: .verified)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(available, forKey: .available)
        try encodeNullable(unavailableReason, to: &container, forKey: .unavailableReason)
        try encodeNullable(unverified, to: &container, forKey: .unverified)
        try encodeNullable(partial, to: &container, forKey: .partial)
        try encodeNullable(failed, to: &container, forKey: .failed)
        try encodeNullable(unverifiable, to: &container, forKey: .unverifiable)
        try encodeNullable(staleRisky, to: &container, forKey: .staleRisky)
        try encodeNullable(verified, to: &container, forKey: .verified)
    }

    private func encodeNullable<T: Encodable>(
        _ value: T?,
        to container: inout KeyedEncodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) throws {
        if let value {
            try container.encode(value, forKey: key)
        } else {
            try container.encodeNil(forKey: key)
        }
    }
}

public struct AgentWorkNextActionVisibility: Codable, Equatable, Sendable {
    public var actor: String
    public var summary: String
    public var source: OuroWorkCardSource?

    public init(actor: String, summary: String, source: OuroWorkCardSource?) {
        self.actor = actor
        self.summary = summary
        self.source = source
    }

    public static let unavailable = AgentWorkNextActionVisibility(
        actor: "unknown",
        summary: "Work Card unavailable.",
        source: nil
    )

    private enum CodingKeys: String, CodingKey {
        case actor
        case summary
        case source
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.actor = try container.decode(String.self, forKey: .actor)
        self.summary = try container.decode(String.self, forKey: .summary)
        self.source = try container.decodeIfPresent(OuroWorkCardSource.self, forKey: .source)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(actor, forKey: .actor)
        try container.encode(summary, forKey: .summary)
        if let source {
            try container.encode(source, forKey: .source)
        } else {
            try container.encodeNil(forKey: .source)
        }
    }
}

public struct OuroWorkCard: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var projection: OuroWorkCardProjection
    public var agent: String
    public var generatedAt: String
    public var degraded: OuroWorkCardDegraded
    public var counts: OuroWorkCardCounts
    public var claims: OuroWorkCardClaims
    public var nextAction: OuroWorkCardNextAction
    public var sources: [OuroWorkCardSource]
}

public struct OuroWorkCardProjection: Codable, Equatable, Sendable {
    public var owner: String
    public var scope: String
    public var relationToActiveWorkFrame: String
}

public struct OuroWorkCardDegraded: Codable, Equatable, Sendable {
    public var status: String
    public var issues: [OuroWorkCardIssue]
}

public struct OuroWorkCardIssue: Codable, Equatable, Sendable {
    public var code: String
    public var severity: String
    public var source: OuroWorkCardSource
    public var detail: String
}

public struct OuroWorkCardCounts: Codable, Equatable, Sendable {
    public var owed: Int
    public var returnObligations: Int
    public var activePackets: Int
    public var evolutionCases: Int
    public var waitingOnHuman: Int
    public var unverifiedClaims: Int?
    public var staleRiskyClaims: Int?
}

public struct OuroWorkCardClaims: Codable, Equatable, Sendable {
    public var available: Bool
    public var unavailableReason: String?
    public var counts: OuroWorkCardClaimsCounts
}

public struct OuroWorkCardClaimsCounts: Codable, Equatable, Sendable {
    public var unverified: Int?
    public var partial: Int?
    public var failed: Int?
    public var unverifiable: Int?
    public var staleRisky: Int?
    public var verified: Int?
}

public struct OuroWorkCardNextAction: Codable, Equatable, Sendable {
    public var actor: String
    public var summary: String
    public var source: OuroWorkCardSource?
}

public struct OuroWorkCardSource: Codable, Equatable, Sendable {
    public var kind: String
    public var locator: String
    public var freshness: String
    public var redaction: String
}

public struct WorkCardCommandResult: Equatable, Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }
}

public typealias WorkCardCommandRunner = @Sendable (
    _ executable: String,
    _ arguments: [String],
    _ timeout: TimeInterval
) throws -> WorkCardCommandResult

public enum WorkCardReadResult: Equatable, Sendable {
    case available(OuroWorkCard)
    case degraded(OuroWorkCard)
    case unavailable(WorkbenchVisibilityIssue)
}

public struct OuroWorkCardReader: Sendable {
    private let executable: String
    private let timeout: TimeInterval
    private let runner: WorkCardCommandRunner

    public init() {
        self.init(environment: TerminalEnvironment())
    }

    public init(environment: TerminalEnvironment) {
        self.init(executable: "/usr/bin/env", timeout: 4, environment: environment)
    }

    public init(
        executable: String = "/usr/bin/env",
        timeout: TimeInterval = 4,
        environment: TerminalEnvironment = TerminalEnvironment()
    ) {
        self.executable = executable
        self.timeout = timeout
        self.runner = { executable, arguments, timeout in
            try Self.defaultRunner(
                executable: executable,
                arguments: arguments,
                timeout: timeout,
                environment: environment
            )
        }
    }

    public init(
        executable: String = "/usr/bin/env",
        timeout: TimeInterval = 4,
        runner: @escaping WorkCardCommandRunner
    ) {
        self.executable = executable
        self.timeout = timeout
        self.runner = runner
    }

    public func read(agent: String) -> WorkCardReadResult {
        let normalizedAgent = agent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard BossWorkbenchMCPRegistrar.isValidAgentBundleName(normalizedAgent) else {
            return .unavailable(WorkbenchVisibilityIssue(
                code: "invalid_agent_name",
                severity: "unavailable",
                source: "ouro work card",
                detail: "Agent name cannot be used as an Ouro bundle name: \(agent)"
            ))
        }

        do {
            let result = try runner(
                executable,
                ["ouro", "work", "card", "--agent", normalizedAgent, "--format", "json"],
                timeout
            )
            guard result.exitCode == 0 else {
                return .unavailable(WorkbenchVisibilityIssue(
                    code: "work_card_command_failed",
                    severity: "unavailable",
                    source: "ouro work card",
                    detail: Self.commandFailureDetail(exitCode: result.exitCode, stderr: result.stderr)
                ))
            }
            let data = Data(result.stdout.utf8)
            let card = try JSONDecoder().decode(OuroWorkCard.self, from: data)
            if card.degraded.status == "degraded" || card.degraded.issues.contains(where: { $0.severity == "degraded" || $0.severity == "unavailable" }) {
                return .degraded(card)
            }
            return .available(card)
        } catch {
            return .unavailable(WorkbenchVisibilityIssue(
                code: "work_card_unreadable",
                severity: "unavailable",
                source: "ouro work card",
                detail: Self.sanitizedDiagnostic(error.localizedDescription)
            ))
        }
    }

    private static func commandFailureDetail(exitCode: Int32, stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "ouro work card exited \(exitCode)."
        }
        return "ouro work card exited \(exitCode): \(sanitizedDiagnostic(trimmed))"
    }

    private static func sanitizedDiagnostic(_ value: String, limit: Int = 500) -> String {
        var sanitized = value
            .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            .replacingOccurrences(of: "\u{001B}", with: "")
        while sanitized.contains("\n\n\n") {
            sanitized = sanitized.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        if sanitized.count > limit {
            let end = sanitized.index(sanitized.startIndex, offsetBy: limit)
            sanitized = "\(sanitized[..<end])..."
        }
        return sanitized
    }

    public static func defaultRunner(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> WorkCardCommandResult {
        try defaultRunner(
            executable: executable,
            arguments: arguments,
            timeout: timeout,
            environment: TerminalEnvironment()
        )
    }

    public static func defaultRunner(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        environment: TerminalEnvironment
    ) throws -> WorkCardCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment.valuesWithResolvedPath()

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdout = ProcessOutputBuffer(limit: 4 * 1024 * 1024)
        let stderr = ProcessOutputBuffer(limit: 64 * 1024)
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stdout.append(data)
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                stderr.append(data)
            }
        }

        let semaphore = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in
            semaphore.signal()
        }

        try process.run()
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if semaphore.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + 1)
            }
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            return WorkCardCommandResult(exitCode: 124, stdout: stdout.string, stderr: stderr.string.isEmpty ? "ouro work card timed out." : stderr.string)
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        return WorkCardCommandResult(exitCode: process.terminationStatus, stdout: stdout.string, stderr: stderr.string)
    }
}

final class ProcessOutputBuffer: @unchecked Sendable {
    private let limit: Int
    private let lock = NSLock()
    private var data = Data()
    private var truncated = false

    init(limit: Int = 64 * 1024) {
        self.limit = limit
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard data.count < limit else {
            truncated = true
            return
        }
        let remaining = limit - data.count
        if chunk.count > remaining {
            data.append(chunk.prefix(remaining))
            truncated = true
        } else {
            data.append(chunk)
        }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        var text = String(data: data, encoding: .utf8) ?? ""
        if truncated {
            text += "\n[output truncated]"
        }
        return text
    }
}

public struct WorkbenchVisibilityBuilder: Sendable {
    private let recoveryPlanner = RecoveryPlanner()

    public init() {}

    public func build(
        state: WorkspaceState,
        workCard: WorkCardReadResult,
        now: Date = Date(),
        liveSessionNames: Set<String> = []
    ) -> WorkbenchVisibilitySnapshot {
        let workspace = workspaceVisibility(state: state, liveSessionNames: liveSessionNames)
        let agentWork = agentWorkVisibility(workCard: workCard, fallbackAgent: state.boss.agentName)
        var issues = agentWork.issues
        if !agentWork.claims.available && !issues.contains(where: { $0.code == "claims_unavailable" }) {
            issues.append(WorkbenchVisibilityIssue(
                code: "claims_unavailable",
                severity: "unavailable",
                source: "ouro work card",
                detail: agentWork.claims.unavailableReason ?? "Claim verification is not yet wired into the Work Card."
            ))
        }
        let readinessStatus: WorkbenchVisibilityStatus = issues.isEmpty ? .available : .degraded
        return WorkbenchVisibilitySnapshot(
            generatedAt: now,
            bossAgent: state.boss.agentName,
            workspace: workspace,
            agentWork: agentWork,
            decisions: WorkbenchDecisionVisibility(
                openInbox: state.openInboxCount(now: now),
                recentActions: state.actionLog.count,
                failedRecentActions: state.actionLog.filter { !$0.succeeded }.count
            ),
            readiness: WorkbenchVisibilityReadiness(status: readinessStatus, issues: issues)
        )
    }

    private func workspaceVisibility(
        state: WorkspaceState,
        liveSessionNames: Set<String>
    ) -> WorkbenchWorkspaceVisibility {
        let activeEntries = state.processEntries.filter { !$0.isArchived }
        let latestRuns = latestRunsByEntryID(state: state)
        // #U28: source the boss-facing recovery scalar from the recovery PLANS,
        // not raw `.needsRecovery` status — so a human-only manual recovery no
        // longer inflates what the boss is told it can act on, and the count
        // splits by class (reattach / auto_resume / respawn / needs_human).
        let plans = recoveryPlanner.planRecovery(for: state, liveSessionNames: liveSessionNames)
        let breakdown = RecoveryBreakdown(plans: plans)
        return WorkbenchWorkspaceVisibility(
            activeSessions: activeEntries.count,
            runningSessions: activeEntries.filter { latestRuns[$0.id]?.status == .running }.count,
            waitingOnHumanSessions: activeEntries.filter { $0.attention == .waitingOnHuman }.count,
            blockedSessions: activeEntries.filter { $0.attention == .blocked }.count,
            needsBossReviewSessions: activeEntries.filter { $0.attention == .needsBossReview }.count,
            recoverableSessions: breakdown.total,
            recovery: RecoveryBreakdownVisibility(breakdown)
        )
    }

    private func latestRunsByEntryID(state: WorkspaceState) -> [UUID: ProcessRun] {
        state.processRuns.reduce(into: [UUID: ProcessRun]()) { latest, run in
            guard let existing = latest[run.entryId] else {
                latest[run.entryId] = run
                return
            }
            if ProcessRun.isMoreRecent(run, existing) {
                latest[run.entryId] = run
            }
        }
    }

    private func agentWorkVisibility(
        workCard: WorkCardReadResult,
        fallbackAgent: String
    ) -> AgentWorkVisibility {
        switch workCard {
        case let .available(card):
            return visibility(from: card, status: .available)
        case let .degraded(card):
            return visibility(from: card, status: .degraded)
        case let .unavailable(issue):
            return AgentWorkVisibility(
                status: .unavailable,
                agent: fallbackAgent,
                generatedAt: nil,
                projectionOwner: nil,
                counts: .unavailable,
                claims: .unavailable(reason: issue.detail),
                nextAction: .unavailable,
                sources: [],
                issues: [issue]
            )
        }
    }

    private func visibility(from card: OuroWorkCard, status: WorkbenchVisibilityStatus) -> AgentWorkVisibility {
        AgentWorkVisibility(
            status: status,
            agent: card.agent,
            generatedAt: card.generatedAt,
            projectionOwner: card.projection.owner,
            counts: AgentWorkCountsVisibility(
                owed: card.counts.owed,
                returnObligations: card.counts.returnObligations,
                activePackets: card.counts.activePackets,
                evolutionCases: card.counts.evolutionCases,
                waitingOnHuman: card.counts.waitingOnHuman,
                unverifiedClaims: card.counts.unverifiedClaims,
                staleRiskyClaims: card.counts.staleRiskyClaims
            ),
            claims: claimsVisibility(from: card.claims),
            nextAction: nextActionVisibility(from: card.nextAction),
            sources: card.sources,
            issues: card.degraded.issues.map { issue in
                WorkbenchVisibilityIssue(
                    code: issue.code,
                    severity: issue.severity,
                    source: "\(issue.source.kind):\(issue.source.locator)",
                    detail: issue.detail
                )
            }
        )
    }

    private func claimsVisibility(from claims: OuroWorkCardClaims) -> AgentWorkClaimsVisibility {
        guard claims.available else {
            return .unavailable(reason: claims.unavailableReason)
        }
        return AgentWorkClaimsVisibility(
            available: true,
            unavailableReason: claims.unavailableReason,
            unverified: claims.counts.unverified,
            partial: claims.counts.partial,
            failed: claims.counts.failed,
            unverifiable: claims.counts.unverifiable,
            staleRisky: claims.counts.staleRisky,
            verified: claims.counts.verified
        )
    }

    private func nextActionVisibility(from nextAction: OuroWorkCardNextAction) -> AgentWorkNextActionVisibility {
        guard nextAction.source?.redaction == "none" else {
            return AgentWorkNextActionVisibility(
                actor: nextAction.actor,
                summary: nextAction.source.map { "Review redacted Work Card source: \($0.locator)." } ?? "Review redacted Work Card next action.",
                source: nextAction.source
            )
        }
        return AgentWorkNextActionVisibility(
            actor: nextAction.actor,
            summary: nextAction.summary,
            source: nextAction.source
        )
    }
}

public struct WorkbenchVisibilityTextRenderer: Sendable {
    public init() {}

    public func render(_ snapshot: WorkbenchVisibilitySnapshot) -> String {
        let work = snapshot.agentWork
        var lines: [String] = [
            "Workbench Visibility — \(snapshot.bossAgent)",
            "Readiness: \(snapshot.readiness.status.rawValue)",
            "Workspace: active=\(snapshot.workspace.activeSessions) running=\(snapshot.workspace.runningSessions) waiting_on_human=\(snapshot.workspace.waitingOnHumanSessions) blocked=\(snapshot.workspace.blockedSessions) needs_boss_review=\(snapshot.workspace.needsBossReviewSessions) recoverable=\(snapshot.workspace.recoverableSessions)",
            // #U28: break the boss-actionable recovery scalar out by class so the
            // boss knows which it may self-trigger (reattach/auto_resume/respawn)
            // vs which it must escalate (needs_human) — never a bare 'recoverable=N'.
            "Recovery: reattach=\(snapshot.workspace.recovery.reattach) auto_resume=\(snapshot.workspace.recovery.autoResume) respawn=\(snapshot.workspace.recovery.respawn) needs_human=\(snapshot.workspace.recovery.needsHuman) boss_actionable=\(snapshot.workspace.recovery.bossActionable)",
            "Decisions: open_inbox=\(snapshot.decisions.openInbox) recent_actions=\(snapshot.decisions.recentActions) failed_recent_actions=\(snapshot.decisions.failedRecentActions)",
            "Agent work: \(work.status.rawValue) owed=\(render(work.counts.owed)) return_obligations=\(render(work.counts.returnObligations)) active_packets=\(render(work.counts.activePackets)) evolution_cases=\(render(work.counts.evolutionCases)) waiting_on_human=\(render(work.counts.waitingOnHuman)) unverified_claims=\(render(work.counts.unverifiedClaims)) stale_risky_claims=\(render(work.counts.staleRiskyClaims))",
            "Claims: \(work.claims.available ? "available" : "unavailable")\(work.claims.unavailableReason.map { " — \($0)" } ?? "")",
            "Next action: \(work.nextAction.summary)"
        ]
        if !snapshot.readiness.issues.isEmpty {
            lines.append("Issues:")
            for issue in snapshot.readiness.issues {
                lines.append("- \(issue.code) [\(issue.severity)] \(issue.detail)")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func render(_ value: Int?) -> String {
        value.map(String.init) ?? "unknown"
    }
}
