import Foundation

public enum MailboxEndpoint: Equatable, Sendable {
    case machine
    case agent(String)
    case needsMe(String)
    case coding(String)
    case sessions(String)
    case attention(String)
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
        case .events:
            return "/api/events"
        }
    }

    private static func escape(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
        let (data, response) = try await URLSession.shared.data(from: url)
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
    public var totals: MailboxMachineTotals?

    public init(
        observedAt: String?,
        primaryEntryPoint: String?,
        daemon: MailboxMachineDaemonSummary?,
        totals: MailboxMachineTotals?
    ) {
        self.observedAt = observedAt
        self.primaryEntryPoint = primaryEntryPoint
        self.daemon = daemon
        self.totals = totals
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
