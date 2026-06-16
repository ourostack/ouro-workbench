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

public enum WorkbenchOnboardingPhase: Equatable, Sendable {
    case bossSetupWizard
    case bossReadyWelcome
    case scanProposal
    case arrangeApprovedImports
    case duplicateCleanup
}

public struct WorkbenchOnboardingFlowInput: Equatable, Sendable {
    public var bossIsReady: Bool
    public var hasProposal: Bool
    public var selectedTerminalCount: Int
    public var ambiguousCandidateCount: Int
    public var importSummaryHasImports: Bool

    public init(
        bossIsReady: Bool,
        hasProposal: Bool,
        selectedTerminalCount: Int,
        ambiguousCandidateCount: Int,
        importSummaryHasImports: Bool
    ) {
        self.bossIsReady = bossIsReady
        self.hasProposal = hasProposal
        self.selectedTerminalCount = selectedTerminalCount
        self.ambiguousCandidateCount = ambiguousCandidateCount
        self.importSummaryHasImports = importSummaryHasImports
    }
}

public struct WorkbenchOnboardingFlowDecision: Equatable, Sendable {
    public var phase: WorkbenchOnboardingPhase
    public var primaryActionTitle: String
    public var notice: String?

    public init(
        phase: WorkbenchOnboardingPhase,
        primaryActionTitle: String,
        notice: String? = nil
    ) {
        self.phase = phase
        self.primaryActionTitle = primaryActionTitle
        self.notice = notice
    }
}

public enum WorkbenchOnboardingFlowPolicy {
    public static func decision(for input: WorkbenchOnboardingFlowInput) -> WorkbenchOnboardingFlowDecision {
        guard input.bossIsReady else {
            return WorkbenchOnboardingFlowDecision(
                phase: .bossSetupWizard,
                primaryActionTitle: "Connect Boss"
            )
        }

        if input.importSummaryHasImports {
            return WorkbenchOnboardingFlowDecision(
                phase: .duplicateCleanup,
                primaryActionTitle: "Review Duplicates",
                notice: WorkbenchOnboardingNarrative.duplicateCleanup
            )
        }

        guard input.hasProposal else {
            return WorkbenchOnboardingFlowDecision(
                phase: .bossReadyWelcome,
                primaryActionTitle: "Scan With Boss",
                notice: WorkbenchOnboardingNarrative.scanIntro
            )
        }

        if input.selectedTerminalCount > 0 {
            return WorkbenchOnboardingFlowDecision(
                phase: .arrangeApprovedImports,
                primaryActionTitle: "Arrange Selected"
            )
        }

        return WorkbenchOnboardingFlowDecision(
            phase: .scanProposal,
            primaryActionTitle: "Scan With Boss",
            notice: input.ambiguousCandidateCount > 0
                ? WorkbenchOnboardingNarrative.ambiguousCandidates(count: input.ambiguousCandidateCount)
                : nil
        )
    }
}
