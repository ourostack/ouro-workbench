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
    public static let bossSectionTitle = "Boss"
    public static let setupWorkspaceName = "Unsorted Sessions"

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
