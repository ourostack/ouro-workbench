import XCTest
@testable import OuroWorkbenchCore

final class OnboardingNarrativeTests: XCTestCase {
    // #U26(c): the boss-ready / unclear-import / ambiguous-candidate / proposal-summary copy and
    // their tests went away with the dead hardcoded scan/arrange flow. `scanIntro` stays — the
    // Connect "boss is ready" panel still uses it — so its test stays too.
    func testScanIntroNamesLocalAgentStores() {
        XCTAssertEqual(
            WorkbenchOnboardingNarrative.scanIntro,
            "I will look for local coding-agent sessions across Workbench, Claude, Codex, Copilot, cmux, and shell history."
        )
    }

    func testDuplicateCleanupCopyGuidesExternalSessionShutdown() {
        XCTAssertEqual(
            WorkbenchOnboardingNarrative.duplicateCleanup,
            "After I resume these in Workbench, I will help you close matching sessions still running outside Workbench so work does not fork."
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

    // A ready boss routes to the boss-driven `.bossReconstruct` hand-off regardless of any stale
    // legacy proposal/selection inputs — those fields no longer steer the policy, and the dead
    // scan-routing phases they once produced are gone (#U26).
    func testFlowRoutesReadyBossToReconstructRegardlessOfLegacyProposalInputs() {
        let inputs: [WorkbenchOnboardingFlowInput] = [
            WorkbenchOnboardingFlowInput(bossIsReady: true, hasProposal: false, selectedTerminalCount: 0, ambiguousCandidateCount: 0, importSummaryHasImports: false),
            WorkbenchOnboardingFlowInput(bossIsReady: true, hasProposal: true, selectedTerminalCount: 0, ambiguousCandidateCount: 0, importSummaryHasImports: false),
            WorkbenchOnboardingFlowInput(bossIsReady: true, hasProposal: true, selectedTerminalCount: 4, ambiguousCandidateCount: 0, importSummaryHasImports: false),
            WorkbenchOnboardingFlowInput(bossIsReady: true, hasProposal: true, selectedTerminalCount: 0, ambiguousCandidateCount: 2, importSummaryHasImports: false)
        ]
        for input in inputs {
            let decision = WorkbenchOnboardingFlowPolicy.decision(for: input)
            XCTAssertEqual(decision.phase, .bossReconstruct)
            XCTAssertEqual(decision.primaryActionTitle, "Bring Back My Work")
            XCTAssertEqual(decision.notice, WorkbenchOnboardingNarrative.bossReconstructIntro)
        }
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

    // MARK: - Slice 7: boss-driven reconstruction hand-off

    func testBossReconstructIntroDescribesHandingTheReconstructionToTheBoss() {
        // The reconstruction is BOSS-DRIVEN: once the boss is ready, Workbench hands it
        // the "bring back my work" task rather than running a hardcoded scan/arrange.
        XCTAssertEqual(
            WorkbenchOnboardingNarrative.bossReconstructIntro,
            "Your boss will look for the work you had open and bring it back as terminals here."
        )
    }

    func testBossReconstructTaskIsAGeneralSeeProposeActHandOffWithNoAgencyKnowledge() {
        // The hand-off task names the primitives the boss uses (discover → optionally
        // propose → relaunch) WITHOUT encoding any agency / repo / resume-command knowledge —
        // the boss owns all context-specific intelligence.
        let task = WorkbenchOnboardingNarrative.bossReconstructTask
        XCTAssertTrue(task.contains("workbench_discover_agent_sessions"))
        XCTAssertTrue(task.contains("workbench_propose"))
        XCTAssertTrue(task.lowercased().contains("relaunch") || task.lowercased().contains("bring"))
        // Zero agency knowledge: no resume command shape, no harness CLI verbs baked in.
        XCTAssertFalse(task.contains("--resume"))
        XCTAssertFalse(task.lowercased().contains("agency"))
        // It is a CAPABILITY, never a forced gate — the boss MAY just act.
        XCTAssertTrue(task.lowercased().contains("propose"))
    }

    func testBossReconstructEmptyStateCopyIsACleanDeadEndNotADeadEnd() {
        // The empty case the operator will sometimes hit: nothing to bring in. The copy
        // must read as "you're set", never as a stuck/dead step.
        XCTAssertEqual(
            WorkbenchOnboardingNarrative.bossReconstructEmpty,
            "Nothing to bring back — you're all set. You can close this whenever you're ready."
        )
    }

    func testFlowHandsReconstructionToBossOnceBossIsReady() {
        // REPLACES the hardcoded scan: a ready boss with no proposal/import state routes to
        // the boss-driven reconstruction hand-off, NOT the old `.bossReadyWelcome` scan page.
        let decision = WorkbenchOnboardingFlowPolicy.decision(for: WorkbenchOnboardingFlowInput(
            bossIsReady: true,
            hasProposal: false,
            selectedTerminalCount: 0,
            ambiguousCandidateCount: 0,
            importSummaryHasImports: false
        ))

        XCTAssertEqual(decision.phase, .bossReconstruct)
        XCTAssertEqual(decision.primaryActionTitle, "Bring Back My Work")
        XCTAssertEqual(decision.notice, WorkbenchOnboardingNarrative.bossReconstructIntro)
    }

    func testFlowStillStartsInBossSetupWizardWhenBossNotReady() {
        // The `fix/onboarding-audit` repair must not regress: an un-ready boss still routes
        // to the setup wizard, unchanged.
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

    func testAppFlowWiringKeepsScanAndDuplicateCleanupActionsUseful() throws {
        let source = try WorkbenchAppSource.appSource()

        XCTAssertFalse(source.contains("model.onboardingProposal?.selectedTerminalCount == 0 {\n                return true"))
        XCTAssertTrue(source.contains("Task { await model.runBossQuickQuestion(WorkbenchOnboardingNarrative.duplicateCleanup) }"))
        XCTAssertFalse(source.contains("case .duplicateCleanup:\n                instructionStatus = model.onboardingFlowDecision.notice\n                dismiss()"))
    }

    func testAppFlowInputUsesOnlyOnboardingArrangeSummaryForDuplicateCleanup() throws {
        let source = try WorkbenchAppSource.appSource()

        XCTAssertTrue(source.contains("importSummaryHasImports: onboardingImportSummaryHasImports"))
        XCTAssertFalse(source.contains("importSummaryHasImports: lastImportSummary?.hasImports == true"))
        XCTAssertTrue(source.contains("onboardingImportSummaryHasImports = result.hasImports"))
        XCTAssertFalse(source.contains("onboardingImportSummaryHasImports = true\n        lastImportSummary = result"))
    }

    func testAppOnboardingChromeAvoidsStaticImportFraming() throws {
        let source = try WorkbenchAppSource.appSource()

        XCTAssertFalse(source.contains("case .importWork:\n                return \"Import\""))
        XCTAssertFalse(source.contains("Ask about setup, providers, or which sessions to import"))
        XCTAssertFalse(source.contains("Import stays locked until provider checks pass."))
    }
}
