import Foundation

/// F6 — the pure remove-agent seam.
///
/// Workbench's agent roster is NOT a registry it owns: `OuroAgentInventory.scan()` derives it by
/// scanning `~/AgentBundles/*.ouro` on disk every refresh. There is therefore no Workbench-side
/// "deregister" to perform — the ONLY way an agent stops appearing in the roster is for its `.ouro`
/// bundle directory to no longer exist. So the honest removal is an on-disk bundle deletion, and the
/// confirmation copy says that plainly (permanent; deletes the bundle) rather than implying a
/// reversible "hide from the list".
///
/// This is the PURE seam: the "what to remove" decision value + the seam-free confirmation copy. The
/// actual `FileManager.removeItem` and the roster/selection/boss mutation that follows live in the
/// App as a thin I/O layer over these values.
public enum AgentRemoval {

    /// The decided removal action for one agent: which on-disk bundle to delete, and (since the
    /// roster is a pure filesystem scan) the fact that removal IS a bundle deletion.
    public struct Decision: Equatable, Sendable {
        public let agentName: String
        public let bundlePath: String
        /// Always true today: deleting the `.ouro` directory is the only honest removal (there is no
        /// separate roster handle to forget the agent by). Modeled as a value so the App's deletion
        /// I/O reads the intent off the seam rather than re-deciding it.
        public let deletesBundle: Bool

        public init(agentName: String, bundlePath: String, deletesBundle: Bool) {
            self.agentName = agentName
            self.bundlePath = bundlePath
            self.deletesBundle = deletesBundle
        }
    }

    /// Decide how to remove `agent`. Uniform across bundle status — even a broken bundle
    /// (`missingConfig` / `invalidConfig`) is removed by deleting its directory, because there is no
    /// other handle to forget it by.
    public static func decide(for agent: OuroAgentRecord) -> Decision {
        Decision(agentName: agent.name, bundlePath: agent.bundlePath, deletesBundle: true)
    }

    /// Seam-free confirmation copy for the destructive remove-agent action. Names the agent, states
    /// the deletion is permanent, and — when the agent is the CURRENT boss — adds a heads-up that the
    /// selection will move. Never leaks `ouro`/`vault`/path/argv seams beyond the agent name.
    public struct ConfirmationCopy: Equatable, Sendable {
        public let title: String
        public let message: String
        public let confirmTitle: String
        public let cancelTitle: String

        public init(title: String, message: String, confirmTitle: String, cancelTitle: String) {
            self.title = title
            self.message = message
            self.confirmTitle = confirmTitle
            self.cancelTitle = cancelTitle
        }
    }

    /// Build the confirmation copy for removing `agentName`. `isBoss` is true when the agent is the
    /// machine's current boss, which warrants an extra heads-up (the boss selection has to move).
    public static func confirmationCopy(agentName: String, isBoss: Bool) -> ConfirmationCopy {
        let base = "This permanently deletes \(agentName) and everything in its bundle from this Mac. This can't be undone."
        let message = isBoss
            ? base + " \(agentName) is your current boss, so Workbench will pick another agent (or none) afterward."
            : base
        return ConfirmationCopy(
            title: "Remove \(agentName)?",
            message: message,
            confirmTitle: "Delete",
            cancelTitle: "Cancel"
        )
    }
}
