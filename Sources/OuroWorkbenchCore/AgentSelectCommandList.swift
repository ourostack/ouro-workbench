import Foundation

/// U37(a): the de-duplicated "Select Agent: <name>" rows for the command palette.
///
/// The palette emitted one Select-Agent descriptor per scanned bundle, so a
/// duplicate inventory record produced a byte-identical duplicate row ("Select
/// Agent: slugger" twice), and the current boss appeared as a redundant "Select
/// Agent: <boss> (boss)" even though the boss is already addressable through the
/// boss selector. This pure builder emits exactly one row per installed bundle —
/// de-duped by case-insensitive name, keeping the first spelling — and EXCLUDES
/// the current boss. Pulled into Core so the rule is unit-tested rather than buried
/// in the App-target palette construction.
public enum AgentSelectCommandList {
    public static func commands(
        agents: [OuroAgentRecord],
        bossAgentName: String
    ) -> [WorkbenchCommandDescriptor] {
        let trimmedBoss = bossAgentName.trimmingCharacters(in: .whitespacesAndNewlines)
        var seen = Set<String>()
        var commands: [WorkbenchCommandDescriptor] = []

        for agent in agents {
            let key = agent.name.lowercased()
            // The current boss is addressable via the boss selector — never list it here.
            if !trimmedBoss.isEmpty, key == trimmedBoss.lowercased() {
                continue
            }
            // One row per bundle name; the first spelling wins.
            guard seen.insert(key).inserted else {
                continue
            }
            commands.append(
                WorkbenchCommandDescriptor(
                    id: .selectAgent,
                    title: "Select Agent: \(agent.name)",
                    detail: agent.summaryLine,
                    systemImage: agent.status == .ready
                        ? "person.crop.circle"
                        : "person.crop.circle.badge.exclamationmark",
                    keywords: ["agent", "bundle", "switch", "open", agent.name],
                    payload: agent.name
                )
            )
        }

        return commands
    }
}
