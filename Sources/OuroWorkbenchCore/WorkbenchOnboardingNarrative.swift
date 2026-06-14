import Foundation

public enum WorkbenchOnboardingNarrative {
    public static let bossReadyWelcome = "I can see this Mac now."
    public static let scanIntro = "I will look for local coding-agent sessions across Workbench, Claude, Codex, Copilot, cmux, and shell history."
    public static let unclearImport = "I will ask before importing anything unclear."
    public static let duplicateCleanup = "After I resume these in Workbench, I will help you close matching sessions still running outside Workbench so work does not fork."

    public static func ambiguousCandidates(count: Int) -> String {
        "I found \(count) unclear \(sessionNoun(count)). I will ask before importing them."
    }

    public static func proposalSummary(groupCount: Int, selectedCount: Int) -> String {
        "I found \(selectedCount) likely \(sessionNoun(selectedCount)) across \(groupCount) \(workspaceNoun(groupCount))."
    }

    private static func sessionNoun(_ count: Int) -> String {
        count == 1 ? "session" : "sessions"
    }

    private static func workspaceNoun(_ count: Int) -> String {
        count == 1 ? "workspace" : "workspaces"
    }
}
