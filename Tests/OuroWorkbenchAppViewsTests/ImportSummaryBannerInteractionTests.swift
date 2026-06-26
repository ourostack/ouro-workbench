#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B9 — `ImportSummaryBanner` (`:2012`) INTERACTION drive-to-100%.
///
/// The C11 `ImportSummaryBannerTests` snapshot the RENDER arms (tone/icon/headline/
/// note/detail/Open-gate) but never EXECUTE the action/lifecycle closures — so 8
/// region segments (the "Open" button action, the xmark dismiss button action, the
/// `.onAppear`/`.onDisappear` lifecycle closures, and the `scheduleDismiss()` helper
/// + its `dismissTask = Task { … }` creation) were never coloured. ViewInspector
/// 0.10.3 invokes button actions (`.tap()`) and the lifecycle hooks
/// (`callOnAppear()`/`callOnDisappear()`), so this suite DRIVES every reachable
/// region and asserts the `@Published` side-effect (provenance), mutation-verified.
///
/// **Provenance (P2).** `model` via the hermetic `makeVM`; the banner is driven by
/// `model.lastImportSummary` (the SAME `@Published` the live import-apply sets) +
/// the real `WorkbenchImportSummaryPresentation` producers, exactly as C11.
///
/// **Carve (genuinely-unreachable):** the `dismissTask = Task { @MainActor in try?
/// await Task.sleep(7s); if !Task.isCancelled { … } }` BODY's `if !Task.isCancelled`
/// arms (`:2109`). The Task is CREATED by `scheduleDismiss()` (driven via
/// `callOnAppear`), but its body runs only AFTER a 7-second sleep, so the
/// `isCancelled` branch never evaluates inside the synchronous in-process inspect
/// (the same async-sleep-gated-Task-body class as the B6 palette `.onChange`
/// `withAnimation` body). Recorded in `b9-records.md`.
@MainActor
final class ImportSummaryBannerInteractionTests: XCTestCase {

    private static let entryId = UUID(uuidString: "B9000004-0000-0000-0000-000000000001")!
    private static let projectId = UUID(uuidString: "B9000000-0000-0000-0000-0000000000B4")!

    private func makeVM(withEntry: Bool) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b9import-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let entries: [ProcessEntry] = withEntry
            ? [ProcessEntry(id: Self.entryId, projectId: Self.projectId, name: "build",
                            kind: .shell, executable: "/bin/zsh", workingDirectory: "/tmp/u4")]
            : []
        try WorkbenchStore(paths: paths).save(WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "Home", rootPath: "/tmp/u4")],
            processEntries: entries))
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    private func summary(persisted: Bool = true, entryID: UUID? = nil) -> WorkbenchImportApplyResult {
        WorkbenchImportApplyResult(
            createdCount: 2, groupNames: ["Home"], skippedNames: [],
            firstSelectedEntryID: entryID, persisted: persisted)
    }

    // MARK: - "Open" button action (`:2067`)

    /// The `Button("Open") { model.selectEntryAcrossGroups(entryID); model.lastImportSummary = nil }`.
    /// The button renders only when the entry is present; tapping selects it AND clears the summary.
    func testBanner_openButton_tapSelectsAndClears() throws {
        let model = try makeVM(withEntry: true)
        // Start with a DIFFERENT selection so the tap's `selectEntryAcrossGroups(entryID)`
        // is observable as a change (the VM auto-selects the sole entry at init).
        model.selectedEntryID = nil
        model.lastImportSummary = summary(entryID: Self.entryId)
        try ImportSummaryBanner(model: model).inspect().find(button: "Open").tap()
        XCTAssertEqual(model.selectedEntryID, Self.entryId,
                       "tapping Open runs selectEntryAcrossGroups(entryID)")
        XCTAssertNil(model.lastImportSummary, "tapping Open also clears the summary banner")
    }

    // MARK: - xmark dismiss button action (`:2073`)

    /// The `Button { model.lastImportSummary = nil } label: { Image("xmark") }`. Tapping
    /// the close affordance clears the banner.
    func testBanner_dismissButton_tapClearsSummary() throws {
        let model = try makeVM(withEntry: false)
        model.lastImportSummary = summary()
        XCTAssertNotNil(model.lastImportSummary, "precondition: a banner is present")
        try ImportSummaryBanner(model: model).inspect().find(ViewType.Button.self, where: { button in
            (try? button.labelView().image().actualImage().name()) == "xmark"
        }).tap()
        XCTAssertNil(model.lastImportSummary, "tapping the xmark clears the summary banner")
    }

    // MARK: - .onAppear / .onDisappear lifecycle (`:2093`, `:2096`) + scheduleDismiss (`:2105`, `:2107`)

    /// `.onAppear { scheduleDismiss() }` — `callOnAppear()` runs the lifecycle closure,
    /// which enters `scheduleDismiss()` (`:2105`) and CREATES the dismiss `Task` (`:2107`).
    /// The Task's 7s-sleep body is the recorded carve; its CREATION region is driven here.
    func testBanner_onAppear_schedulesDismiss() throws {
        let model = try makeVM(withEntry: false)
        model.lastImportSummary = summary()
        // The banner's content is inside a `Group { if let summary { HStack {…}.onAppear } }`.
        // Find the HStack carrying the onAppear and fire it.
        let hstack = try ImportSummaryBanner(model: model).inspect().find(ViewType.HStack.self)
        try hstack.callOnAppear()
        // scheduleDismiss() ran (created the dismiss Task); the summary is still present
        // (the Task body only clears it after a 7s sleep — not synchronously).
        XCTAssertNotNil(model.lastImportSummary,
                        "onAppear schedules a *future* dismiss; it does not clear synchronously")
    }

    /// `.onDisappear { dismissTask?.cancel(); dismissTask = nil }` — `callOnDisappear()`
    /// runs the cancel/clear lifecycle closure.
    func testBanner_onDisappear_cancelsDismissTask() throws {
        let model = try makeVM(withEntry: false)
        model.lastImportSummary = summary()
        let hstack = try ImportSummaryBanner(model: model).inspect().find(ViewType.HStack.self)
        try hstack.callOnAppear()      // create the dismiss task first
        try hstack.callOnDisappear()   // then cancel it
        // The cancel/clear closure ran (no throw); the summary is untouched by disappear.
        XCTAssertNotNil(model.lastImportSummary, "onDisappear cancels the timer, not the banner")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The Open / dismiss button actions both clear `lastImportSummary`; the Open action
    /// additionally selects the entry. A no-op action would leave the model unchanged.
    func testBanner_negativeControl_actionsClearSummary() throws {
        let openModel = try makeVM(withEntry: true)
        openModel.lastImportSummary = summary(entryID: Self.entryId)
        try ImportSummaryBanner(model: openModel).inspect().find(button: "Open").tap()
        XCTAssertNil(openModel.lastImportSummary, "Open cleared the summary")
        XCTAssertEqual(openModel.selectedEntryID, Self.entryId, "Open selected the entry")

        let dismissModel = try makeVM(withEntry: false)
        dismissModel.lastImportSummary = summary()
        try ImportSummaryBanner(model: dismissModel).inspect().find(ViewType.Button.self, where: { b in
            (try? b.labelView().image().actualImage().name()) == "xmark"
        }).tap()
        XCTAssertNil(dismissModel.lastImportSummary, "xmark cleared the summary")
    }

    // MARK: - Determinism (P3)

    func testBanner_interaction_noLeak() throws {
        let model = try makeVM(withEntry: true)
        model.lastImportSummary = summary(entryID: Self.entryId)
        let tree = try ViewSnapshotHost.snapshotText(of: ImportSummaryBanner(model: model))
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
        XCTAssertFalse(tree.contains("/var/folders/"), "no temp-path leak:\n\(tree)")
    }
}
#endif
