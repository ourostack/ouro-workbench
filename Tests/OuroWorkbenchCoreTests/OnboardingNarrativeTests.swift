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
}
