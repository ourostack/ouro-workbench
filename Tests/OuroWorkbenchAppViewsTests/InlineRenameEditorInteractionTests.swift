#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B1 — `InlineRenameEditor` (`:3271`) event-closure INTERACTION drive-to-100%.
///
/// The SU-C `InlineRenameEditorStateSetTests` snapshot the editor and call `commitRename()`
/// DIRECTLY, but never drive the editor's `.onSubmit { model.commitRename() }` (`L3278`) nor
/// `.onExitCommand { model.cancelRename() }` (`L3279`) closures THROUGH the view — so both event
/// closures were uncovered. This suite invokes each via ViewInspector (`callOnSubmit()` /
/// `callOnExitCommand()`) → asserting the model side-effect, then MUTATION-VERIFIES both.
///
/// **Provenance (P2).** The editor's `inlineRename` state is opened via the REAL `beginRename`
/// seam; the draft is set through `@Published inlineRename.draft`. The commit routes through the
/// real `WorkspaceRenameCommit` → `setWorkspaceNameOverride` path. AN-001 hermetic.
///
/// **Determinism (P3).** Fixed ids; no clock; `!contains("/Users/")`.
@MainActor
final class InlineRenameEditorInteractionTests: XCTestCase {

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FC")!
    private static let ws = UUID(uuidString: "CCCCCCCC-0000-0000-0000-0000000000D1")!
    private static let tab = UUID(uuidString: "CCCCCCCC-0000-0000-0000-0000000000D2")!

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("b1-ire-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let entry = ProcessEntry(id: Self.tab, projectId: Self.projectId, name: "build", kind: .shell,
                                 executable: "/bin/zsh", workingDirectory: "/tmp/u5b1ire")
        let state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"),
                                   processEntries: [entry],
                                   workspaces: [Workspace(id: Self.ws, autoName: "Frontend", tabIds: [Self.tab])])
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
    }

    private func editor(_ model: WorkbenchViewModel) -> InlineRenameEditor {
        InlineRenameEditor(model: model)
    }

    // MARK: - onSubmit (Enter → commitRename)

    func testOnSubmit_validDraft_commitsRename() throws {
        let model = try makeVM()
        model.beginRename(.workspace(Self.ws), prefill: "Frontend")
        model.inlineRename.draft = "Renamed"
        XCTAssertTrue(model.inlineRename.isEditing(.workspace(Self.ws)), "provenance: editing")
        try editor(model).inspect().find(ViewType.TextField.self).callOnSubmit()
        XCTAssertEqual(model.state.workspaces.first?.nameOverride, "Renamed",
                       "onSubmit committed the valid rename (the override is written)")
        XCTAssertFalse(model.inlineRename.isEditing(.workspace(Self.ws)), "onSubmit closed the editor")
    }

    // MARK: - onExitCommand (Escape → cancelRename)

    func testOnExitCommand_cancelsRenameWithoutWriting() throws {
        let model = try makeVM()
        model.beginRename(.workspace(Self.ws), prefill: "Frontend")
        model.inlineRename.draft = "DiscardMe"
        XCTAssertTrue(model.inlineRename.isEditing(.workspace(Self.ws)), "provenance: editing")
        try editor(model).inspect().find(ViewType.TextField.self).callOnExitCommand()
        XCTAssertFalse(model.inlineRename.isEditing(.workspace(Self.ws)), "onExitCommand closed the editor")
        XCTAssertNil(model.state.workspaces.first?.nameOverride,
                     "onExitCommand cancelled — the discarded draft is NOT written")
    }

    // MARK: - Negative controls (P2 — mutation-verified)

    /// onSubmit is load-bearing: a valid draft submit writes the override. (Mutation-verify:
    /// replacing `model.commitRename()` with a no-op leaves nameOverride nil → RED.)
    func testNegativeControl_onSubmitCommits() throws {
        let model = try makeVM()
        model.beginRename(.workspace(Self.ws), prefill: "Frontend")
        model.inlineRename.draft = "NewName"
        XCTAssertNil(model.state.workspaces.first?.nameOverride, "provenance: no override yet")
        try editor(model).inspect().find(ViewType.TextField.self).callOnSubmit()
        XCTAssertEqual(model.state.workspaces.first?.nameOverride, "NewName",
                       "onSubmit must commit the rename (write the override)")
    }

    /// onExitCommand is load-bearing: it closes the editor (cancels). (Mutation-verify: replacing
    /// `model.cancelRename()` with a no-op leaves isEditing true → RED.)
    func testNegativeControl_onExitCommandCancels() throws {
        let model = try makeVM()
        model.beginRename(.workspace(Self.ws), prefill: "Frontend")
        XCTAssertTrue(model.inlineRename.isEditing(.workspace(Self.ws)), "provenance: editing")
        try editor(model).inspect().find(ViewType.TextField.self).callOnExitCommand()
        XCTAssertFalse(model.inlineRename.isEditing(.workspace(Self.ws)),
                       "onExitCommand must close (cancel) the editor")
    }
}
#endif
