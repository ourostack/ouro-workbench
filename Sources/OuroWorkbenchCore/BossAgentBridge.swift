import Foundation

public struct BossAgentBridgePlan: Equatable, Sendable {
    public var agentName: String
    public var executable: String
    public var arguments: [String]

    public init(agentName: String, executable: String = "ouro", arguments: [String]) {
        self.agentName = agentName
        self.executable = executable
        self.arguments = arguments
    }

    public var displayCommand: String {
        ([executable] + arguments).joined(separator: " ")
    }
}

public struct BossAgentBridgePlanner: Sendable {
    public init() {}

    public func mcpServePlan(for boss: BossAgentSelection) -> BossAgentBridgePlan {
        BossAgentBridgePlan(
            agentName: boss.agentName,
            arguments: ["mcp-serve", "--agent", boss.agentName]
        )
    }

    public func checkInQuestion(userQuestion: String? = nil) -> String {
        userQuestion ?? "Summarize what is going on, what is waiting on Ari, active terminal agents, blockers, and next actions."
    }
}
