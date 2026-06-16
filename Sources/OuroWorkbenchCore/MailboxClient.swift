import Foundation

public enum MailboxEndpoint: Equatable, Sendable {
    case machine
    case agent(String)
    case needsMe(String)
    case coding(String)
    case sessions(String)
    case attention(String)
    case habitRunSummaries(String, limit: Int?)
    case habitRunSummary(String, selector: MailboxHabitSummarySelector)
    case events

    public var path: String {
        switch self {
        case .machine:
            return "/api/machine"
        case .agent(let agent):
            return "/api/agents/\(Self.escape(agent))"
        case .needsMe(let agent):
            return "/api/agents/\(Self.escape(agent))/needs-me"
        case .coding(let agent):
            return "/api/agents/\(Self.escape(agent))/coding"
        case .sessions(let agent):
            return "/api/agents/\(Self.escape(agent))/sessions"
        case .attention(let agent):
            return "/api/agents/\(Self.escape(agent))/attention"
        case .habitRunSummaries(let agent, let limit):
            let basePath = "/api/agents/\(Self.escape(agent))/habit-run-summaries"
            guard let limit else { return basePath }
            return "\(basePath)?\(Self.queryString([("limit", String(limit))]))"
        case .habitRunSummary(let agent, let selector):
            let basePath = "/api/agents/\(Self.escape(agent))/habit-run-summary"
            let query = Self.queryString(selector.queryItems)
            return query.isEmpty ? basePath : "\(basePath)?\(query)"
        case .events:
            return "/api/events"
        }
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func escapeQuery(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private static func queryString(_ items: [(String, String?)]) -> String {
        items.compactMap { key, value in
            guard let value else { return nil }
            return "\(escapeQuery(key))=\(escapeQuery(value))"
        }.joined(separator: "&")
    }
}

public struct MailboxHabitSummarySelector: Equatable, Sendable {
    public var runId: String?
    public var habitName: String?
    public var operationId: String?
    public var which: String?

    public init(
        runId: String? = nil,
        habitName: String? = nil,
        operationId: String? = nil,
        which: String? = nil
    ) {
        self.runId = runId
        self.habitName = habitName
        self.operationId = operationId
        self.which = which
    }

    fileprivate var queryItems: [(String, String?)] {
        if runId != nil {
            return [("runId", runId)]
        }
        return [
            ("habit", habitName),
            ("operation-id", operationId),
            ("which", which),
        ]
    }
}

public struct MailboxClientConfiguration: Equatable, Sendable {
    public var baseURL: URL
    public var requestTimeoutNanoseconds: UInt64

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:6876")!,
        requestTimeoutNanoseconds: UInt64 = 3_000_000_000
    ) {
        self.baseURL = baseURL
        self.requestTimeoutNanoseconds = requestTimeoutNanoseconds
    }
}

public enum MailboxClientError: Error, Equatable, LocalizedError, Sendable {
    case invalidURL
    case badStatus(Int)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The Ouro mailbox URL is invalid."
        case .badStatus(let status):
            return "The Ouro mailbox returned HTTP \(status)."
        case .timeout:
            return "The Ouro mailbox did not answer before the Workbench timeout."
        }
    }
}

public struct MailboxClient: Sendable {
    public var configuration: MailboxClientConfiguration
    private let dataLoader: @Sendable (URL) async throws -> (Data, HTTPURLResponse)

    public init(
        configuration: MailboxClientConfiguration = MailboxClientConfiguration(),
        dataLoader: @escaping @Sendable (URL) async throws -> (Data, HTTPURLResponse) = MailboxClient.defaultDataLoader
    ) {
        self.configuration = configuration
        self.dataLoader = dataLoader
    }

    public func url(for endpoint: MailboxEndpoint) throws -> URL {
        guard let url = URL(string: endpoint.path, relativeTo: configuration.baseURL)?.absoluteURL else {
            throw MailboxClientError.invalidURL
        }
        return url
    }

    public func fetch<T: Decodable & Sendable>(_ endpoint: MailboxEndpoint, as type: T.Type = T.self) async throws -> T {
        let url = try url(for: endpoint)
        let (data, response) = try await load(url)
        guard (200..<300).contains(response.statusCode) else {
            throw MailboxClientError.badStatus(response.statusCode)
        }
        return try JSONDecoder().decode(type, from: data)
    }

    private func load(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            // Cancel the sibling task on every exit path — including when
            // `group.next()` *throws* the timeout. Without this `defer`, a
            // timeout rethrows before `cancelAll()` runs, leaking the still
            // in-flight data task.
            defer { group.cancelAll() }
            group.addTask {
                try await dataLoader(url)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: configuration.requestTimeoutNanoseconds)
                throw MailboxClientError.timeout
            }
            guard let result = try await group.next() else {
                throw MailboxClientError.timeout
            }
            return result
        }
    }

    public static func defaultDataLoader(url: URL) async throws -> (Data, HTTPURLResponse) {
        try await defaultDataLoader(url: url, session: .shared)
    }

    static func defaultDataLoader(url: URL, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw MailboxClientError.invalidURL
        }
        return (data, httpResponse)
    }
}

public struct MailboxMachineView: Decodable, Equatable, Sendable {
    public var overview: MailboxMachineOverview?
    public var agents: [MailboxMachineAgentView]

    public init(overview: MailboxMachineOverview?, agents: [MailboxMachineAgentView]) {
        self.overview = overview
        self.agents = agents
    }
}

public struct MailboxMachineOverview: Decodable, Equatable, Sendable {
    public var observedAt: String?
    public var primaryEntryPoint: String?
    public var daemon: MailboxMachineDaemonSummary?
    public var runtime: MailboxRuntimeSummary?
    public var totals: MailboxMachineTotals?

    public init(
        observedAt: String?,
        primaryEntryPoint: String?,
        daemon: MailboxMachineDaemonSummary?,
        runtime: MailboxRuntimeSummary? = nil,
        totals: MailboxMachineTotals?
    ) {
        self.observedAt = observedAt
        self.primaryEntryPoint = primaryEntryPoint
        self.daemon = daemon
        self.runtime = runtime
        self.totals = totals
    }
}

/// The harness runtime block from `/api/machine` — carries the installed ouro
/// version. Decoded if-present so older daemons that omit it still parse.
public struct MailboxRuntimeSummary: Decodable, Equatable, Sendable {
    public var version: String?

    public init(version: String?) {
        self.version = version
    }
}

public struct MailboxMachineDaemonSummary: Decodable, Equatable, Sendable {
    public var status: String
    public var mode: String
    public var mailboxUrl: String

    public init(status: String, mode: String, mailboxUrl: String) {
        self.status = status
        self.mode = mode
        self.mailboxUrl = mailboxUrl
    }
}

public struct MailboxMachineTotals: Decodable, Equatable, Sendable {
    public var openObligations: Int
    public var activeCodingAgents: Int
    public var blockedCodingAgents: Int

    public init(openObligations: Int, activeCodingAgents: Int, blockedCodingAgents: Int) {
        self.openObligations = openObligations
        self.activeCodingAgents = activeCodingAgents
        self.blockedCodingAgents = blockedCodingAgents
    }
}

public struct MailboxMachineAgentView: Decodable, Equatable, Sendable {
    public var agentName: String
    public var enabled: Bool
    public var attention: MailboxAttentionSummary?
    public var obligations: MailboxCountSummary?
    public var coding: MailboxCountSummary?

    public init(
        agentName: String,
        enabled: Bool,
        attention: MailboxAttentionSummary?,
        obligations: MailboxCountSummary?,
        coding: MailboxCountSummary?
    ) {
        self.agentName = agentName
        self.enabled = enabled
        self.attention = attention
        self.obligations = obligations
        self.coding = coding
    }
}

public struct MailboxAttentionSummary: Decodable, Equatable, Sendable {
    public var level: String
    public var label: String

    public init(level: String, label: String) {
        self.level = level
        self.label = label
    }
}

public struct MailboxCountSummary: Decodable, Equatable, Sendable {
    public var openCount: Int?
    public var activeCount: Int?
    public var blockedCount: Int?

    public init(openCount: Int? = nil, activeCount: Int? = nil, blockedCount: Int? = nil) {
        self.openCount = openCount
        self.activeCount = activeCount
        self.blockedCount = blockedCount
    }
}

public struct MailboxNeedsMeView: Decodable, Equatable, Sendable {
    public var items: [MailboxNeedsMeItem]

    public init(items: [MailboxNeedsMeItem]) {
        self.items = items
    }
}

public struct MailboxNeedsMeItem: Decodable, Equatable, Identifiable, Sendable {
    public var urgency: String
    public var label: String
    public var detail: String
    public var ref: MailboxNavigationRef?
    public var ageMs: Int?

    public var id: String {
        "\(urgency)-\(label)-\(detail)"
    }

    public init(urgency: String, label: String, detail: String, ref: MailboxNavigationRef?, ageMs: Int?) {
        self.urgency = urgency
        self.label = label
        self.detail = detail
        self.ref = ref
        self.ageMs = ageMs
    }
}

public struct MailboxNavigationRef: Decodable, Equatable, Sendable {
    public var tab: String
    public var focus: String?

    public init(tab: String, focus: String?) {
        self.tab = tab
        self.focus = focus
    }
}

public struct MailboxCodingSummary: Decodable, Equatable, Sendable {
    public var totalCount: Int
    public var activeCount: Int
    public var blockedCount: Int
    public var items: [MailboxCodingItem]

    public init(totalCount: Int, activeCount: Int, blockedCount: Int, items: [MailboxCodingItem]) {
        self.totalCount = totalCount
        self.activeCount = activeCount
        self.blockedCount = blockedCount
        self.items = items
    }
}

public struct MailboxCodingItem: Decodable, Equatable, Identifiable, Sendable {
    public var id: String
    public var runner: String
    public var status: String
    public var workdir: String
    public var lastActivityAt: String?
    public var checkpoint: String?
    public var taskRef: String?

    public init(
        id: String,
        runner: String,
        status: String,
        workdir: String,
        lastActivityAt: String?,
        checkpoint: String?,
        taskRef: String?
    ) {
        self.id = id
        self.runner = runner
        self.status = status
        self.workdir = workdir
        self.lastActivityAt = lastActivityAt
        self.checkpoint = checkpoint
        self.taskRef = taskRef
    }
}

public struct MailboxHabitSessionSummaryView: Decodable, Equatable, Sendable {
    public var totalCount: Int
    public var limit: Int
    public var items: [MailboxHabitSessionSummary]

    public init(totalCount: Int, limit: Int, items: [MailboxHabitSessionSummary]) {
        self.totalCount = totalCount
        self.limit = limit
        self.items = items
    }
}

public struct MailboxHabitSessionSummary: Decodable, Equatable, Identifiable, Sendable {
    public var runId: String
    public var habitName: String
    public var operationId: String?
    public var status: String
    public var triggeredAt: String
    public var completedAt: String
    public var summary: String
    public var decisions: [String]
    public var pending: MailboxHabitSummaryPending
    public var messagesSent: [MailboxHabitSummaryMessage]
    public var toolsUsed: [String]
    public var producedRefs: [MailboxHabitSummaryProducedRef]
    public var errors: [String]
    public var warnings: [String]
    public var nextLikelyStep: String?
    public var sources: MailboxHabitSummarySources

    public var id: String { runId }

    public init(
        runId: String,
        habitName: String,
        operationId: String?,
        status: String,
        triggeredAt: String,
        completedAt: String,
        summary: String,
        decisions: [String],
        pending: MailboxHabitSummaryPending,
        messagesSent: [MailboxHabitSummaryMessage],
        toolsUsed: [String],
        producedRefs: [MailboxHabitSummaryProducedRef],
        errors: [String],
        warnings: [String],
        nextLikelyStep: String?,
        sources: MailboxHabitSummarySources
    ) {
        self.runId = runId
        self.habitName = habitName
        self.operationId = operationId
        self.status = status
        self.triggeredAt = triggeredAt
        self.completedAt = completedAt
        self.summary = summary
        self.decisions = decisions
        self.pending = pending
        self.messagesSent = messagesSent
        self.toolsUsed = toolsUsed
        self.producedRefs = producedRefs
        self.errors = errors
        self.warnings = warnings
        self.nextLikelyStep = nextLikelyStep
        self.sources = sources
    }
}

public struct MailboxHabitSummaryPending: Decodable, Equatable, Sendable {
    public var count: Int
    public var files: [String]

    public init(count: Int, files: [String]) {
        self.count = count
        self.files = files
    }
}

public struct MailboxHabitSummaryMessage: Decodable, Equatable, Sendable {
    public var recipient: String
    public var channel: String
    public var result: String

    public init(recipient: String, channel: String, result: String) {
        self.recipient = recipient
        self.channel = channel
        self.result = result
    }
}

public struct MailboxHabitSummaryProducedRef: Decodable, Equatable, Sendable {
    public var kind: String
    public var locator: String

    public init(kind: String, locator: String) {
        self.kind = kind
        self.locator = locator
    }
}

public struct MailboxHabitSummarySources: Decodable, Equatable, Sendable {
    public var receipt: String
    public var session: String
    public var pending: String
    public var runtimeState: String

    public init(receipt: String, session: String, pending: String, runtimeState: String) {
        self.receipt = receipt
        self.session = session
        self.pending = pending
        self.runtimeState = runtimeState
    }
}
