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

    public init(baseURL: URL = URL(string: "http://127.0.0.1:6876")!) {
        self.baseURL = baseURL
    }
}

public enum MailboxClientError: Error, Equatable, Sendable {
    case invalidURL
    case badStatus(Int)
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
        let (data, response) = try await dataLoader(url)
        guard (200..<300).contains(response.statusCode) else {
            throw MailboxClientError.badStatus(response.statusCode)
        }
        return try JSONDecoder().decode(type, from: data)
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
