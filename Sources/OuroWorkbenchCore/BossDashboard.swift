import Foundation

public struct BossDashboardSnapshot: Equatable, Sendable {
    public var agentName: String
    public var daemonStatus: String
    public var daemonMode: String
    public var attentionLabel: String
    public var openObligations: Int
    public var activeCodingAgents: Int
    public var blockedCodingAgents: Int
    public var needsMeItems: [MailboxNeedsMeItem]
    public var codingItems: [MailboxCodingItem]
    public var observedAt: String?
    public var availability: BossDashboardAvailability

    public init(
        agentName: String,
        daemonStatus: String,
        daemonMode: String,
        attentionLabel: String,
        openObligations: Int,
        activeCodingAgents: Int,
        blockedCodingAgents: Int,
        needsMeItems: [MailboxNeedsMeItem],
        codingItems: [MailboxCodingItem],
        observedAt: String?,
        availability: BossDashboardAvailability = .complete
    ) {
        self.agentName = agentName
        self.daemonStatus = daemonStatus
        self.daemonMode = daemonMode
        self.attentionLabel = attentionLabel
        self.openObligations = openObligations
        self.activeCodingAgents = activeCodingAgents
        self.blockedCodingAgents = blockedCodingAgents
        self.needsMeItems = needsMeItems
        self.codingItems = codingItems
        self.observedAt = observedAt
        self.availability = availability
    }

    public var oneLineStatus: String {
        if !availability.needsMeAvailable {
            return "Needs-me status unavailable"
        }
        if !needsMeItems.isEmpty {
            return "\(needsMeItems.count) item\(needsMeItems.count == 1 ? "" : "s") waiting on you"
        }
        if !availability.codingAvailable {
            return "Coding status unavailable"
        }
        if activeCodingAgents > 0 {
            return "\(activeCodingAgents) active coding agent\(activeCodingAgents == 1 ? "" : "s")"
        }
        return attentionLabel
    }
}

public struct BossDashboardAvailability: Equatable, Sendable {
    public var machineAvailable: Bool
    public var needsMeAvailable: Bool
    public var codingAvailable: Bool
    public var issues: [String]

    public init(
        machineAvailable: Bool,
        needsMeAvailable: Bool,
        codingAvailable: Bool,
        issues: [String] = []
    ) {
        self.machineAvailable = machineAvailable
        self.needsMeAvailable = needsMeAvailable
        self.codingAvailable = codingAvailable
        self.issues = issues
    }

    public static let complete = BossDashboardAvailability(
        machineAvailable: true,
        needsMeAvailable: true,
        codingAvailable: true
    )
}

public struct BossDashboardBuilder: Sendable {
    public init() {}

    public func build(
        boss: BossAgentSelection,
        machine: MailboxMachineView?,
        needsMe: MailboxNeedsMeView?,
        coding: MailboxCodingSummary?,
        availability: BossDashboardAvailability = .complete
    ) -> BossDashboardSnapshot {
        let selectedAgent = machine?.agents.first { $0.agentName.caseInsensitiveCompare(boss.agentName) == .orderedSame }
        let totals = machine?.overview?.totals
        return BossDashboardSnapshot(
            agentName: boss.agentName,
            daemonStatus: machine?.overview?.daemon?.status ?? "unknown",
            daemonMode: machine?.overview?.daemon?.mode ?? "unknown",
            attentionLabel: selectedAgent?.attention?.label ?? "unknown",
            openObligations: selectedAgent?.obligations?.openCount ?? totals?.openObligations ?? 0,
            activeCodingAgents: selectedAgent?.coding?.activeCount ?? coding?.activeCount ?? totals?.activeCodingAgents ?? 0,
            blockedCodingAgents: selectedAgent?.coding?.blockedCount ?? coding?.blockedCount ?? totals?.blockedCodingAgents ?? 0,
            needsMeItems: needsMe?.items ?? [],
            codingItems: coding?.items ?? [],
            observedAt: machine?.overview?.observedAt,
            availability: availability
        )
    }
}
