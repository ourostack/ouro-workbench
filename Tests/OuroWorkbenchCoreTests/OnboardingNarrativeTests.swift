import XCTest
@testable import OuroWorkbenchCore

final class OnboardingNarrativeTests: XCTestCase {
    func testBossReadyWelcomeCopy() {
        XCTAssertEqual(WorkbenchOnboardingNarrative.bossReadyWelcome, "I can see this Mac now.")
    }

    func testScanIntroNamesLocalAgentStores() {
        XCTAssertEqual(
            WorkbenchOnboardingNarrative.scanIntro,
            "I will look for local coding-agent sessions across Workbench, Claude, Codex, Copilot, cmux, and shell history."
        )
    }

    func testUnclearImportCopyPromisesToAsk() {
        XCTAssertEqual(WorkbenchOnboardingNarrative.unclearImport, "I will ask before importing anything unclear.")
    }

    func testAmbiguousCandidateCopyIncludesCount() {
        XCTAssertEqual(
            WorkbenchOnboardingNarrative.ambiguousCandidates(count: 2),
            "I found 2 unclear sessions. I will ask before importing them."
        )
    }

    func testDuplicateCleanupCopyGuidesExternalSessionShutdown() {
        XCTAssertEqual(
            WorkbenchOnboardingNarrative.duplicateCleanup,
            "After I resume these in Workbench, I will help you close matching sessions still running outside Workbench so work does not fork."
        )
    }

    func testProposalSummaryCopyUsesWorkspaces() {
        XCTAssertEqual(
            WorkbenchOnboardingNarrative.proposalSummary(groupCount: 3, selectedCount: 5),
            "I found 5 likely sessions across 3 workspaces."
        )
    }

    func testFlowStartsInBossSetupWizardBeforeBossReadiness() {
        let decision = WorkbenchOnboardingFlowPolicy.decision(for: WorkbenchOnboardingFlowInput(
            bossIsReady: false,
            hasProposal: false,
            selectedTerminalCount: 0,
            ambiguousCandidateCount: 0,
            importSummaryHasImports: false
        ))

        XCTAssertEqual(decision.phase, .bossSetupWizard)
        XCTAssertEqual(decision.primaryActionTitle, "Connect Boss")
        XCTAssertNil(decision.notice)
    }

    func testFlowSwitchesToBossReadyWelcomeWhenBossCanScan() {
        let decision = WorkbenchOnboardingFlowPolicy.decision(for: WorkbenchOnboardingFlowInput(
            bossIsReady: true,
            hasProposal: false,
            selectedTerminalCount: 0,
            ambiguousCandidateCount: 0,
            importSummaryHasImports: false
        ))

        XCTAssertEqual(decision.phase, .bossReadyWelcome)
        XCTAssertEqual(decision.primaryActionTitle, "Scan With Boss")
        XCTAssertEqual(decision.notice, WorkbenchOnboardingNarrative.scanIntro)
    }

    func testFlowKeepsScanProposalWhenProposalHasNoSelectedTerminals() {
        let decision = WorkbenchOnboardingFlowPolicy.decision(for: WorkbenchOnboardingFlowInput(
            bossIsReady: true,
            hasProposal: true,
            selectedTerminalCount: 0,
            ambiguousCandidateCount: 0,
            importSummaryHasImports: false
        ))

        XCTAssertEqual(decision.phase, .scanProposal)
        XCTAssertEqual(decision.primaryActionTitle, "Scan With Boss")
        XCTAssertNil(decision.notice)
    }

    func testFlowArrangesApprovedImportsWhenSelectionExists() {
        let decision = WorkbenchOnboardingFlowPolicy.decision(for: WorkbenchOnboardingFlowInput(
            bossIsReady: true,
            hasProposal: true,
            selectedTerminalCount: 4,
            ambiguousCandidateCount: 0,
            importSummaryHasImports: false
        ))

        XCTAssertEqual(decision.phase, .arrangeApprovedImports)
        XCTAssertEqual(decision.primaryActionTitle, "Arrange Selected")
        XCTAssertNil(decision.notice)
    }

    func testFlowAttachesAmbiguousCandidateNarrative() {
        let decision = WorkbenchOnboardingFlowPolicy.decision(for: WorkbenchOnboardingFlowInput(
            bossIsReady: true,
            hasProposal: true,
            selectedTerminalCount: 0,
            ambiguousCandidateCount: 2,
            importSummaryHasImports: false
        ))

        XCTAssertEqual(decision.phase, .scanProposal)
        XCTAssertEqual(decision.primaryActionTitle, "Scan With Boss")
        XCTAssertEqual(decision.notice, WorkbenchOnboardingNarrative.ambiguousCandidates(count: 2))
    }

    func testFlowGuidesDuplicateCleanupAfterImportSummary() {
        let decision = WorkbenchOnboardingFlowPolicy.decision(for: WorkbenchOnboardingFlowInput(
            bossIsReady: true,
            hasProposal: true,
            selectedTerminalCount: 4,
            ambiguousCandidateCount: 0,
            importSummaryHasImports: true
        ))

        XCTAssertEqual(decision.phase, .duplicateCleanup)
        XCTAssertEqual(decision.primaryActionTitle, "Review Duplicates")
        XCTAssertEqual(decision.notice, WorkbenchOnboardingNarrative.duplicateCleanup)
    }
}
