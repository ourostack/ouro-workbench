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

    func testAppFlowWiringKeepsScanAndDuplicateCleanupActionsUseful() throws {
        let source = try appSource()

        XCTAssertFalse(source.contains("model.onboardingProposal?.selectedTerminalCount == 0 {\n                return true"))
        XCTAssertTrue(source.contains("Task { await model.runBossQuickQuestion(WorkbenchOnboardingNarrative.duplicateCleanup) }"))
        XCTAssertFalse(source.contains("case .duplicateCleanup:\n                instructionStatus = model.onboardingFlowDecision.notice\n                dismiss()"))
    }

    func testAppFlowInputUsesOnlyOnboardingArrangeSummaryForDuplicateCleanup() throws {
        let source = try appSource()

        XCTAssertTrue(source.contains("importSummaryHasImports: onboardingImportSummaryHasImports"))
        XCTAssertFalse(source.contains("importSummaryHasImports: lastImportSummary?.hasImports == true"))
        XCTAssertTrue(source.contains("onboardingImportSummaryHasImports = result.hasImports"))
        XCTAssertFalse(source.contains("onboardingImportSummaryHasImports = true\n        lastImportSummary = result"))
    }

    func testAppOnboardingChromeAvoidsStaticImportFraming() throws {
        let source = try appSource()

        XCTAssertFalse(source.contains("case .importWork:\n                return \"Import\""))
        XCTAssertFalse(source.contains("Ask about setup, providers, or which sessions to import"))
        XCTAssertFalse(source.contains("Import stays locked until provider checks pass."))
    }

    private func appSource() throws -> String {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("OuroWorkbenchApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
