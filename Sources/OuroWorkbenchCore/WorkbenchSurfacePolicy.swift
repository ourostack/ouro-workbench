import Foundation

public enum WorkbenchSurfacePolicy {
    public enum SessionAction: Equatable, Sendable {
        case launch
        case recover
        case stop
        case focus
        case redraw
        case restart
        case controlC
        case escape
        case eof
    }

    public struct SessionControls: Equatable, Sendable {
        public var primaryActions: [SessionAction]
        public var advancedActions: [SessionAction]

        public init(primaryActions: [SessionAction], advancedActions: [SessionAction]) {
            self.primaryActions = primaryActions
            self.advancedActions = advancedActions
        }
    }

    public static let workspaceSectionTitle = "Workspaces"
    public static let newWorkspaceTitle = "New Workspace"
    public static let newWorkspaceSheetTitle = "New Workspace"
    public static let editWorkspaceSheetTitle = "Edit Workspace"
    public static let workspaceNameRequiredMessage = "Workspace name is required"
    public static let workspaceRootPathRequiredMessage = "Workspace root path is required"
    public static let noWorkspaceSelectedToSaveMessage = "No workspace is selected to save"
    public static let keepAtLeastOneWorkspaceMessage = "Keep at least one workspace"
    public static let targetWorkspaceNoLongerExistsMessage = "Target workspace no longer exists"
    public static let bossSectionTitle = "Boss"

    /// U32: the bootstrapped default workspace's name. Was "Unsorted Sessions" — a
    /// state-claiming word that told a first-time operator their sessions were
    /// mis-filed / pending cleanup on a clean install where nothing had happened (a
    /// mild false alarm, and an odd handle for the boss to reason with). "Home" is a
    /// neutral, welcoming label that reads sensibly both as a workspace row and as a
    /// section header. Only fresh installs get this name; existing user-named
    /// workspaces (including any legacy "Unsorted Sessions") are never force-renamed
    /// — the bootstrapper only mints a default when there are zero projects.
    public static let setupWorkspaceName = "Home"

    public static func workspaceNoLongerExistsMessage(name: String) -> String {
        "Workspace no longer exists: \(name)"
    }

    /// U32: the terminals section header. Instead of repeating the selected
    /// workspace's bare name (so the sidebar read the same string twice — worst case
    /// "Unsorted Sessions" verbatim), name the RELATIONSHIP: "Terminals in <name>".
    /// With no workspace selected there's nothing to relate to, so fall back to the
    /// bare "Terminals" label.
    public static func terminalsSectionTitle(workspaceName: String?) -> String {
        guard let name = workspaceName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return "Terminals"
        }
        return "Terminals in \(name)"
    }

    public static func moveOrDeleteTerminalsBeforeDeletingMessage(name: String) -> String {
        "Move or delete terminals before deleting \(name)"
    }

    public static func bossStatus(agentName: String, isReady: Bool) -> String {
        let trimmed = agentName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return "Choose boss"
        }
        return isReady ? "\(trimmed) ready" : "\(trimmed) setup needed"
    }

    public static func shouldShowRecovery(recoverableCount: Int) -> Bool {
        recoverableCount > 0
    }

    // MARK: - U11: Stop confirmation gate

    /// Whether stopping THIS session must confirm first — gated by consequence,
    /// not by uniform friction. `⌘.` is the universal macOS "cancel" chord, so a
    /// reflexive press currently nukes a running agent with nothing; meanwhile the
    /// app already demands a named confirmation to DELETE an already-dead terminal.
    /// This inverts that: a session with a **live process holding context** (live
    /// AND any non-idle attention — running, waiting at a prompt, blocked-but-live,
    /// or flagged for review) confirms before terminating, because something real
    /// is lost. A session with no live process (idle/finished/never-started), or a
    /// bare live-but-idle shell that holds nothing, stops without ceremony.
    public static func stopNeedsConfirmation(isLiveProcess: Bool, attention: AttentionState) -> Bool {
        guard isLiveProcess else { return false }
        switch attention {
        case .active, .waitingOnHuman, .blocked, .needsBossReview:
            return true
        case .idle:
            return false
        }
    }

    /// Title for the Stop confirmation dialog, naming the session being stopped.
    public static func stopConfirmationTitle(name: String) -> String {
        "Stop \(name)?"
    }

    /// Destructive-button label for the Stop confirmation, naming the session.
    public static func stopConfirmationButton(name: String) -> String {
        "Stop \(name)"
    }

    /// Plain-language consequence shown in the Stop confirmation.
    public static let stopConfirmationMessage =
        "This ends the running agent and its live context. The terminal stops; "
            + "its session history (Claude, Codex, …) stays on disk."

    public static func sessionControls(
        isRunning: Bool,
        isArchived: Bool,
        isRecoverable: Bool
    ) -> SessionControls {
        guard !isArchived else {
            return SessionControls(primaryActions: [], advancedActions: [])
        }
        if isRunning {
            return SessionControls(
                primaryActions: [.stop],
                advancedActions: [.focus, .redraw, .restart, .controlC, .escape, .eof]
            )
        }
        if isRecoverable {
            return SessionControls(primaryActions: [.recover], advancedActions: [])
        }
        return SessionControls(primaryActions: [.launch], advancedActions: [])
    }
}
