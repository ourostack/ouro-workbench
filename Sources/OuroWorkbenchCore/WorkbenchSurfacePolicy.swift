import Foundation

public enum WorkbenchSurfacePolicy {
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
}
