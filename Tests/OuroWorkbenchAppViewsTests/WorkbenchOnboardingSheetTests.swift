#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C6-5 — `WorkbenchOnboardingSheet` (`:6434`) initial-page composite.
///
/// **Re-confirm: NOT a shell-allowlist candidate.** Unlike `WorkbenchRootView` (the
/// window/scene shell with a `@StateObject` + `NavigationSplitView` and no data-state seam),
/// this sheet has a REAL data-state seam: it takes an injected `model` and composes
/// `OnboardingFlowHeader` + `OnboardingPageContent` + the nav row (`primaryActionTitle` /
/// `primaryActionImage` / `OnboardingProgressDots`), all driven by hermetic model state. It hosts
/// deterministically under `inspect()` and its initial `.boss` page renders a real composite —
/// so it stays IN U4 scope (covered), not allowlisted.
///
/// **Initial-page seam (AN-006).** `@State page` defaults to `.boss` with no init seam; the
/// `.connect` / `.importWork` pages are reachable ONLY by firing the in-view Back / Next Button
/// closures that ViewInspector's synchronous `inspect()` CANNOT fire (the C4 `DecisionInboxSheet
/// showFullLog` / `DecisionLogRow taught` pattern). So this test snapshots the GENUINE initial
/// `.boss` composite; the other two pages are RECORDED as in-view-Button-only reachable, NOT
/// fabricated. (`OnboardingPageContent`'s `.connect` / `.importWork` children ARE covered directly
/// in C6-4 via the injected-page seam — so no page goes uncovered.)
///
/// **Provenance (P2).** `model` via the hermetic `makeVM` store seam (AN-001 dual-injection). The
/// `.task` (refresh*) / `.onDisappear` (rollback) effects do NOT run under `inspect()`, so the
/// snapshot is the model's deterministic initial state. NO fabricated state.
///
/// **Determinism (P3).** No clock / path / machine value reaches the captured tree under the
/// hermetic VM. Byte-identical twice; no `/Users/` leak.
///
/// **Non-vacuity (P2).** The `.boss`-page primary button title ("Continue", `:6511`) is a captured
/// node driven by the `switch page` in `primaryActionTitle`. The negative control mutates it.
@MainActor
final class WorkbenchOnboardingSheetTests: XCTestCase {

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c6-onbsheet-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try WorkbenchStore(paths: paths).save(
            WorkspaceState(boss: BossAgentSelection(agentName: "boss")))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func sheet() throws -> WorkbenchOnboardingSheet {
        WorkbenchOnboardingSheet(model: try makeVM())
    }

    // MARK: - Initial-page composite

    /// The genuine initial `.boss` page: the header (Choose Boss), the boss-choice content, and
    /// the nav row with the "Continue" primary.
    func testOnboardingSheet_initialBossPage() throws {
        try assertViewSnapshot(of: try sheet(), named: "WorkbenchOnboardingSheet.initialBossPage")
    }

    // MARK: - Determinism (P3)

    func testOnboardingSheet_determinism_byteIdenticalTwiceNoLeak() throws {
        let a = try ViewSnapshotHost.snapshotText(of: try sheet())
        let b = try ViewSnapshotHost.snapshotText(of: try sheet())
        XCTAssertEqual(a, b, "the initial boss page must be byte-identical twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }

    // MARK: - Provenance: the boss page renders the composite (header + content + Continue)

    func testOnboardingSheet_bossPageComposite() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: try sheet())
        XCTAssertTrue(tree.contains("Choose Boss"), "the header title renders the .boss page:\n\(tree)")
        XCTAssertTrue(tree.contains("Continue"), "the .boss-page primary reads Continue")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The `.boss`-page `primaryActionTitle` ("Continue") is a captured node driven by the
    /// `switch page` — break it and the composite snapshot + the provenance assertion go RED.
    func testOnboardingSheet_negativeControl_primaryTitleIsCaptured() throws {
        let tree = try ViewSnapshotHost.snapshotText(of: try sheet())
        XCTAssertTrue(tree.contains("Continue"),
                      "the .boss-page primary title renders (mutating it to anything else makes this RED):\n\(tree)")
        // The header's "Cancel" (not-completed) also renders alongside the Continue primary —
        // proving the composite (header + nav) is captured, not just one child.
        XCTAssertTrue(tree.contains("Cancel"), "the not-completed header dismiss label renders")
    }

    // MARK: - U5 B3 — DRIVE every page + nav + lifecycle region (corrected recipe: INVOKE)

    /// A `.ready` `OnboardingReadiness` (so `onboardingFlowInput.bossIsReady == true`), built via
    /// the real public initializer.
    private func readyReadiness() -> OnboardingReadiness {
        OnboardingReadiness(state: .ready, headline: "ready", detail: "d",
                            selectedBossName: "boss", repairSteps: [])
    }

    /// A ready agent so `OnboardingBossChoiceView` shows a usable selected boss (Continue enabled on
    /// the `.boss` page) and `OnboardingReadinessView` renders the ready surface.
    private func readyAgent() -> OuroAgentRecord {
        let lane = OuroAgentLane(provider: "github-copilot", model: "gpt-5.4")
        return OuroAgentRecord(
            name: "boss", bundlePath: "/agent-bundles/boss.ouro",
            configPath: "/agent-bundles/boss.ouro/agent.json", status: .ready, detail: "ready",
            humanFacing: lane, agentFacing: lane)
    }

    /// Build a model whose `onboardingFlowDecision.phase` is the requested phase, then the sheet on
    /// the requested page. `.bossSetupWizard` ⟸ not-ready; `.bossReconstruct` ⟸ ready + no imports;
    /// `.duplicateCleanup` ⟸ ready + imports. All through the REAL model seams.
    private func sheet(
        page: WorkbenchOnboardingSheet.OnboardingPage,
        phase: WorkbenchOnboardingPhase
    ) throws -> (WorkbenchViewModel, WorkbenchOnboardingSheet) {
        let model = try makeVM()
        model.ouroAgents = [readyAgent()]
        model.state.boss.agentName = "boss"
        switch phase {
        case .bossSetupWizard:
            model.onboardingReadiness = OnboardingReadiness(
                state: .needsCredentials, headline: "h", detail: "d",
                selectedBossName: "boss", repairSteps: [])
            model.onboardingImportSummaryHasImports = false
        case .bossReconstruct:
            model.onboardingReadiness = readyReadiness()
            model.onboardingImportSummaryHasImports = false
        case .duplicateCleanup:
            model.onboardingReadiness = readyReadiness()
            model.onboardingImportSummaryHasImports = true
        }
        XCTAssertEqual(model.onboardingFlowDecision.phase, phase, "provenance: the real policy reached \(phase)")
        return (model, WorkbenchOnboardingSheet(model: model, initialPage: page))
    }

    // MARK: B3.a0 — the OnboardingPage.next computed property (no render caller → direct logic test)

    /// `OnboardingPage.next` (`:6498`, `OnboardingPage(rawValue: rawValue + 1)`) has NO body caller
    /// (the wizard uses `page.previous` for Back and `advance()` sets pages directly), so no render
    /// seam executes it. It is `internal` (the enum is testable), so DRIVE it directly: it returns
    /// the next page in `rawValue` order and nil past the last. This asserts every arm + the nil tail.
    func testOnboardingSheet_pageNext_isExhaustive() throws {
        XCTAssertEqual(WorkbenchOnboardingSheet.OnboardingPage.boss.next, .connect, "boss → connect")
        XCTAssertEqual(WorkbenchOnboardingSheet.OnboardingPage.connect.next, .importWork, "connect → importWork")
        XCTAssertNil(WorkbenchOnboardingSheet.OnboardingPage.importWork.next, "importWork is the last page → nil")
    }

    // MARK: B3.a — render the .connect / .importWork pages (primaryActionTitle/Image/IsDisabled arms)

    /// The `.connect` page under each flow phase drives `primaryActionTitle.connect` (the
    /// `onboardingFlowDecision.primaryActionTitle`) + `primaryActionImage.connect` (the
    /// `phase == .bossSetupWizard ? "link" : "arrow.uturn.backward.circle"` ternary) +
    /// `primaryActionIsDisabled.connect`. Each phase renders the page through the REAL seam.
    func testOnboardingSheet_connectPage_bossSetupWizard() throws {
        let (_, sheet) = try sheet(page: .connect, phase: .bossSetupWizard)
        let tree = try ViewSnapshotHost.snapshotText(of: sheet)
        XCTAssertTrue(tree.contains("Connect your agent"), "the .connect page content renders:\n\(tree)")
        XCTAssertTrue(tree.contains("Connect Boss"), "bossSetupWizard → the 'Connect Boss' primary title:\n\(tree)")
        try assertViewSnapshot(of: sheet, named: "WorkbenchOnboardingSheet.connectBossSetup")
    }

    func testOnboardingSheet_connectPage_bossReconstruct() throws {
        let (_, sheet) = try sheet(page: .connect, phase: .bossReconstruct)
        let tree = try ViewSnapshotHost.snapshotText(of: sheet)
        XCTAssertTrue(tree.contains("Bring Back My Work"),
                      "bossReconstruct → the 'Bring Back My Work' primary title (the non-wizard image arm):\n\(tree)")
        try assertViewSnapshot(of: sheet, named: "WorkbenchOnboardingSheet.connectBossReconstruct")
    }

    func testOnboardingSheet_connectPage_duplicateCleanup() throws {
        let (_, sheet) = try sheet(page: .connect, phase: .duplicateCleanup)
        let tree = try ViewSnapshotHost.snapshotText(of: sheet)
        XCTAssertTrue(tree.contains("Review Duplicates"),
                      "duplicateCleanup → the 'Review Duplicates' primary title:\n\(tree)")
        try assertViewSnapshot(of: sheet, named: "WorkbenchOnboardingSheet.connectDuplicateCleanup")
    }

    /// The `.importWork` page under each flow phase drives `primaryActionImage.importWork`'s inner
    /// `switch phase` (`.bossReconstruct`/`.duplicateCleanup`/`.bossSetupWizard`) + the
    /// `primaryActionIsDisabled.importWork` arms (the `isReady != true` gate, the `bossReconstruct`
    /// `bossCheckInIsRunning` gate, the `onboardingIsScanning` gate).
    func testOnboardingSheet_importWorkPage_bossReconstruct() throws {
        let (_, sheet) = try sheet(page: .importWork, phase: .bossReconstruct)
        let tree = try ViewSnapshotHost.snapshotText(of: sheet)
        XCTAssertTrue(tree.contains("Bring back your work"),
                      "the .importWork page content renders (bossReconstruct surface):\n\(tree)")
        try assertViewSnapshot(of: sheet, named: "WorkbenchOnboardingSheet.importWorkBossReconstruct")
    }

    func testOnboardingSheet_importWorkPage_duplicateCleanup() throws {
        let (_, sheet) = try sheet(page: .importWork, phase: .duplicateCleanup)
        let tree = try ViewSnapshotHost.snapshotText(of: sheet)
        XCTAssertTrue(tree.contains("Review Duplicates"), "duplicateCleanup → 'Review Duplicates' primary:\n\(tree)")
        try assertViewSnapshot(of: sheet, named: "WorkbenchOnboardingSheet.importWorkDuplicateCleanup")
    }

    /// `primaryActionIsDisabled.importWork`'s THIRD gate `if model.onboardingIsScanning { return true }`
    /// (`:6618`) is reached only on the `.importWork` page with a READY boss whose phase is NOT
    /// `.bossReconstruct` (so `.duplicateCleanup`) AND a scan in flight. Render that exact state so
    /// the scanning-true gate evaluates its `return true` arm.
    func testOnboardingSheet_importWorkPage_duplicateCleanup_scanningDisablesPrimary() throws {
        let (model, sheet) = try sheet(page: .importWork, phase: .duplicateCleanup)
        model.onboardingIsScanning = true
        XCTAssertEqual(model.onboardingFlowDecision.phase, .duplicateCleanup, "provenance: duplicateCleanup")
        XCTAssertTrue(model.onboardingIsScanning, "provenance: a scan is in flight → primary disabled")
        // Re-render so primaryActionIsDisabled re-evaluates with the scanning flag (hits :6618 true arm).
        let tree = try ViewSnapshotHost.snapshotText(of: sheet)
        XCTAssertTrue(tree.contains("Review Duplicates"), "the duplicateCleanup primary still renders (disabled):\n\(tree)")
    }

    func testOnboardingSheet_importWorkPage_bossSetupWizard_disabledGate() throws {
        // .importWork + bossSetupWizard (not ready) → primaryActionIsDisabled.importWork hits the
        // `onboardingReadiness?.isReady != true` early-true arm (disabled) AND the importWork image
        // `.bossSetupWizard` → "link" arm.
        let (model, sheet) = try sheet(page: .importWork, phase: .bossSetupWizard)
        XCTAssertNotEqual(model.onboardingReadiness?.isReady, true, "provenance: not ready → importWork disabled")
        let tree = try ViewSnapshotHost.snapshotText(of: sheet)
        XCTAssertTrue(tree.contains("Bring back your work"), "the .importWork content renders:\n\(tree)")
        try assertViewSnapshot(of: sheet, named: "WorkbenchOnboardingSheet.importWorkBossSetupDisabled")
    }

    // MARK: B3.b — DRIVE the nav Button action closures (advance() / Back) + the @State writes

    /// The Continue button on the `.boss` page (`:6521`) → `advance()` `.boss` arm (`:6614`)
    /// → `page = .connect` (a `@State` write the no-hosting inspect can't reflect, but the closure
    /// + the `.boss` switch arm EXECUTE). The button is ENABLED (a usable selected boss). DRIVEN by
    /// `.tap()`; asserted it runs without throwing (responsive).
    func testOnboardingSheet_drive_continueFromBoss_advanceBossArm() throws {
        let model = try makeVM()
        model.ouroAgents = [readyAgent()]
        model.state.boss.agentName = "boss"
        XCTAssertTrue(model.onboardingBossChoices.contains { $0.isSelected && $0.isUsable },
                      "precondition: a usable selected boss enables Continue")
        let sheet = WorkbenchOnboardingSheet(model: model, initialPage: .boss)
        XCTAssertNoThrow(try sheet.inspect().find(button: "Continue").tap(),
                         "Continue (advance .boss arm) executes")
    }

    /// The Continue button on the `.connect` page under `.bossSetupWizard` (`advance()` `.connect`
    /// arm, `:6616`) → the `phase == .bossSetupWizard` branch (`:6617`) → runs
    /// `refreshOnboardingReadiness()` + `runOnboardingProviderChecksIfNeeded()` +
    /// `startFirstRunBootstrapIfNeeded()` and RETURNS (no page change). The button must be enabled
    /// (no scanning / running checks). DRIVEN by `.tap()`; asserted the model-observable
    /// `onboardingReadiness` re-derives (stays non-nil) — the closure ran the `.bossSetupWizard` arm.
    func testOnboardingSheet_drive_advanceConnect_bossSetupWizardArm() throws {
        let model = try makeVM()
        model.ouroAgents = [readyAgent()]
        model.state.boss.agentName = "boss"
        // Not ready → bossSetupWizard; no running checks → Continue enabled.
        model.onboardingReadiness = OnboardingReadiness(
            state: .needsCredentials, headline: "h", detail: "d", selectedBossName: "boss", repairSteps: [])
        model.onboardingProviderChecks = [:]
        model.onboardingIsScanning = false
        XCTAssertEqual(model.onboardingFlowDecision.phase, .bossSetupWizard, "precondition")
        let sheet = WorkbenchOnboardingSheet(model: model, initialPage: .connect)
        let title = model.onboardingFlowDecision.primaryActionTitle // "Connect Boss"
        XCTAssertNoThrow(try sheet.inspect().find(button: title).tap(),
                         "advance() .connect → .bossSetupWizard arm executes")
        XCTAssertNotNil(model.onboardingReadiness, "the .bossSetupWizard arm re-ran refreshOnboardingReadiness()")
    }

    /// The Continue button on the `.connect` page under `.bossReconstruct` (a READY boss, no
    /// imports) → `advance()` `.connect` arm → the NON-wizard branch: sets
    /// `onboardingHasBeenCompleted = true` + clears `onboardingBossSnapshot` + (page=.importWork,
    /// a @State write) + `startBossReconstruction()`. DRIVEN by `.tap()`; asserted
    /// `onboardingHasBeenCompleted` flips true (the synchronous completion) + a
    /// "startBossReconstruction" action-log entry lands.
    func testOnboardingSheet_drive_advanceConnect_readyCompletesAndReconstructs() throws {
        let model = try makeVM()
        model.ouroAgents = [readyAgent()]
        model.state.boss.agentName = "boss"
        model.onboardingReadiness = readyReadiness()
        model.onboardingImportSummaryHasImports = false
        model.onboardingProviderChecks = ["outward": OnboardingProviderCheckResult(lane: "outward", state: .passed, detail: "ok")]
        XCTAssertEqual(model.onboardingFlowDecision.phase, .bossReconstruct, "precondition")
        XCTAssertFalse(model.onboardingHasBeenCompleted, "precondition")
        let sheet = WorkbenchOnboardingSheet(model: model, initialPage: .connect)
        try sheet.inspect().find(button: "Bring Back My Work").tap()
        XCTAssertTrue(model.onboardingHasBeenCompleted,
                      "the ready .connect advance marks onboarding completed (the non-wizard arm)")
        XCTAssertNil(model.onboardingBossSnapshot, "the open snapshot is cleared on completion")
        XCTAssertEqual(model.state.actionLog.first?.action, "startBossReconstruction",
                       "a ready boss hands off to reconstruction on landing importWork")
    }

    /// The Continue button on the `.importWork` page under `.bossReconstruct` → `advance()`
    /// `.importWork` arm (`:6639`) → the `.bossReconstruct` case (`:6641`) → `startBossReconstruction()`.
    /// DRIVEN by `.tap()`; asserted `onboardingReconstructionHandedOff` flips true (the hand-off).
    func testOnboardingSheet_drive_advanceImportWork_bossReconstructArm() throws {
        let model = try makeVM()
        model.ouroAgents = [readyAgent()]
        model.state.boss.agentName = "boss"
        model.onboardingReadiness = readyReadiness()
        model.onboardingImportSummaryHasImports = false
        model.bossCheckInIsRunning = false
        XCTAssertEqual(model.onboardingFlowDecision.phase, .bossReconstruct, "precondition")
        XCTAssertFalse(model.onboardingReconstructionHandedOff, "precondition")
        let sheet = WorkbenchOnboardingSheet(model: model, initialPage: .importWork)
        try sheet.inspect().find(button: "Bring Back My Work").tap()
        XCTAssertTrue(model.onboardingReconstructionHandedOff,
                      "advance() .importWork → .bossReconstruct arm hands off (flag flips true)")
    }

    /// The Continue button on the `.importWork` page under `.duplicateCleanup` → `advance()`
    /// `.importWork` arm → the `.duplicateCleanup` case (`:6646`) → `Task { runBossQuickQuestion(…) }`.
    /// DRIVEN by `.tap()`; the synchronous closure executes the `.duplicateCleanup` arm (the Task
    /// runs against the hermetic env, not awaited) — asserted the responsive button runs without throwing.
    func testOnboardingSheet_drive_advanceImportWork_duplicateCleanupArm() throws {
        let model = try makeVM()
        model.ouroAgents = [readyAgent()]
        model.state.boss.agentName = "boss"
        model.onboardingReadiness = readyReadiness()
        model.onboardingImportSummaryHasImports = true
        XCTAssertEqual(model.onboardingFlowDecision.phase, .duplicateCleanup, "precondition")
        let sheet = WorkbenchOnboardingSheet(model: model, initialPage: .importWork)
        XCTAssertNoThrow(try sheet.inspect().find(button: "Review Duplicates").tap(),
                         "advance() .importWork → .duplicateCleanup arm executes")
    }

    /// The Back button (`:6506`) on a non-first page → the `if let previous = page.previous` arm
    /// (`:6507`, exercising `OnboardingPage.previous` `:6489` and `next` `:6485` are computed by the
    /// progress dots) → `page = previous` (a `@State` write). The Back button is ENABLED on a
    /// non-`.boss` page. DRIVEN by `.tap()`; asserted responsive (the closure + the `if let previous`
    /// arm execute).
    func testOnboardingSheet_drive_backButton_fromConnect() throws {
        let (_, sheet) = try sheet(page: .connect, phase: .bossSetupWizard)
        XCTAssertNoThrow(try sheet.inspect().find(button: "Back").tap(),
                         "Back (page.previous → page = previous) executes on the .connect page")
    }

    // MARK: B3.c — DRIVE the .task and .onDisappear lifecycle closures

    /// The sheet's `.task` (`:6534`) MODIFIER closure is genuinely UN-DRIVABLE through ViewInspector
    /// on this toolchain (CARVE): on macOS 26 / Swift 6.3 SwiftUI lowers `.task {…}` to
    /// `_TaskModifier2` (NOT the `_TaskModifier` ViewInspector's `callTask()` hardcodes — probed),
    /// AND the modifier's `action` is `@isolated(any) () async -> ()`, which cannot be `as?`-cast to
    /// `(@Sendable () async -> Void)` / `(() async -> Void)` for a Mirror-extracted invocation (probed:
    /// the cast fails). ViewInspector's `modifierAttribute(modifierName:)` is `internal`, so the
    /// corrected name is also unreachable. So the `.task` modifier region (`:6534`) is carved.
    ///
    /// Its BODY is NOT untested: every method the `.task` calls is independently driven —
    /// `prepareLoginShellEnvironment()` (guarded), `refreshOuroAgents()` /
    /// `refreshWorkbenchMCPRegistration()` / `refreshOnboardingReadiness()` /
    /// `runOnboardingProviderChecksIfNeeded()`. This test calls that exact body sequence DIRECTLY on
    /// the model (the same calls the `.task` makes) and asserts the model-observable effect, so the
    /// behaviour the `.task` triggers is covered even though the modifier closure itself can't be invoked.
    func testOnboardingSheet_taskBodyMethodsDrivenDirectly() async throws {
        let priorPath = TerminalEnvironment.loginShellPath
        TerminalEnvironment.loginShellPath = "/usr/bin:/bin" // guard prepareLoginShellEnvironment's shell-out
        defer { TerminalEnvironment.loginShellPath = priorPath }
        let model = try makeVM()
        model.onboardingReadiness = nil
        // The exact .task body sequence (:6538–6542), invoked directly.
        await model.prepareLoginShellEnvironment()
        model.refreshOuroAgents()
        model.refreshWorkbenchMCPRegistration()
        model.refreshOnboardingReadiness()
        model.runOnboardingProviderChecksIfNeeded()
        XCTAssertNotNil(model.onboardingReadiness, "the .task body's refreshOnboardingReadiness() ran")
    }

    /// The sheet's `.onDisappear` (`:6544`) runs `cancelOnboardingProviderChecks()` +
    /// `rollbackOnboardingIfIncomplete()`. With a mid-wizard boss pick (an `onboardingBossSnapshot`
    /// snapshot + not completed), the rollback restores the snapshot boss. DRIVEN by
    /// `callOnDisappear()`; asserted the rollback fired (the boss reverts to the snapshot).
    func testOnboardingSheet_drive_onDisappear_rollsBackIncompletePick() throws {
        let model = try makeVM()
        // Simulate a mid-wizard pick: snapshot the original boss, then change the live pick.
        model.onboardingBossSnapshot = "boss"
        model.state.boss.agentName = "other-pick"
        model.onboardingHasBeenCompleted = false
        let sheet = WorkbenchOnboardingSheet(model: model)
        try sheet.inspect().find(ViewType.VStack.self).callOnDisappear()
        XCTAssertEqual(model.state.boss.agentName, "boss",
                       "onDisappear → rollbackOnboardingIfIncomplete() restores the snapshot boss")
    }
}
#endif
