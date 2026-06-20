import Foundation

public enum WorkbenchOnboardingNarrative {
    public static let bossReadyWelcome = "I can see this Mac now."
    public static let scanIntro = "I will look for local coding-agent sessions across Workbench, Claude, Codex, Copilot, cmux, and shell history."
    public static let unclearImport = "I will ask before importing anything unclear."
    public static let duplicateCleanup = "After I resume these in Workbench, I will help you close matching sessions still running outside Workbench so work does not fork."

    /// Operator-facing line for the boss-driven reconstruction hand-off: Workbench no
    /// longer runs a hardcoded scan/arrange — once the boss is ready it hands the boss the
    /// "bring back my work" task and renders the boss's conversation + proposal card.
    public static let bossReconstructIntro = "Your boss will look for the work you had open and bring it back as terminals here."

    /// The hand-off TASK handed to the boss agent. It names the GENERAL primitives the boss
    /// uses (discover → optionally propose → relaunch) and is explicit that proposing is a
    /// CAPABILITY, not a forced gate. It carries ZERO agency / repo / resume-command
    /// knowledge — the boss owns every context-specific decision (which session, the exact
    /// relaunch command).
    public static let bossReconstructTask = """
    Help {{owner}} pick up where they left off. Use workbench_discover_agent_sessions to see \
    their recent and running coding-agent sessions on this Mac. Decide which ones are worth \
    bringing back. You may use workbench_propose to show {{owner}} an editable list to \
    tick / edit / approve before you act — or, if it is obvious, just bring the sessions \
    back yourself. Relaunch each chosen session as a Workbench terminal with the right \
    resume command and working directory. If there is nothing worth bringing back, say so \
    plainly — {{owner}} is all set.
    """

    /// Shown when the boss reports there was nothing to reconstruct. A clean "you're set",
    /// never a stuck / dead-end step — the empty case the operator will sometimes hit.
    public static let bossReconstructEmpty = "Nothing to bring back — you're all set. You can close this whenever you're ready."

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
    /// Boss-driven reconstruction hand-off (Slice 7): replaces the hardcoded
    /// `bossReadyWelcome` / `scanProposal` / `arrangeApprovedImports` scan-and-arrange
    /// flow. Workbench hands the boss the "bring back my work" task and surfaces the boss's
    /// conversation + proposal card; the boss does discover → optionally propose → relaunch.
    case bossReconstruct
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

        // Post-import: the boss has brought sessions back, so guide the operator through
        // closing any matching sessions still running outside Workbench (preserved branch —
        // the fix/onboarding-audit duplicate-cleanup step must not regress).
        if input.importSummaryHasImports {
            return WorkbenchOnboardingFlowDecision(
                phase: .duplicateCleanup,
                primaryActionTitle: "Review Duplicates",
                notice: WorkbenchOnboardingNarrative.duplicateCleanup
            )
        }

        // Slice 7: a ready boss hands off to boss-driven reconstruction. Workbench no longer
        // routes through the hardcoded scan/arrange phases — the boss does discover →
        // optionally propose → relaunch. The legacy proposal/selection inputs no longer
        // steer the policy (they remain on the input only for back-compat).
        return WorkbenchOnboardingFlowDecision(
            phase: .bossReconstruct,
            primaryActionTitle: "Bring Back My Work",
            notice: WorkbenchOnboardingNarrative.bossReconstructIntro
        )
    }
}
