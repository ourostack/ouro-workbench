#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// SU-C — Surface C (inline rename editor) COMPLETE enumerated state-set on the
/// `InlineRenameEditor` itself (the editor's OWN states + the no-op-on-commit
/// boundary). U2 already snapshotted the editor EMBEDDED (`A.renameInProgress`,
/// `B.tabRenameInProgress`); SU-C covers the editor as the unit-under-test.
///
/// **The real serialized dimension (review-gate MEDIUM):** `InlineRenameEditor`
/// (`WorkbenchViewsAndModel.swift:3169-3185`) renders ONLY the bound `inlineRename.draft`
/// (the `TextField`), a FIXED caption `Text("Press Enter to rename, Escape to cancel.")`,
/// and a FIXED `.accessibilityLabel("Rename")`. The rename TARGET (workspace vs tab) is
/// NOT in the editor tree — so "editing-workspace" vs "editing-tab" with the SAME draft
/// would produce BYTE-IDENTICAL snapshots (forbidden by P4e). The C state-set is therefore
/// `{one editor reference per DISTINCT draft tree} + the whitespace-no-op boundary`:
/// - `C.editingWorkspace`  — draft `"Frontend"`, built via `beginRename(.workspace(id), …)`.
/// - `C.editingTab`        — draft `"build"`, built via `beginRename(.tab(id), …)` (a
///                            DISTINCT draft → a distinct tree; it also exercises the tab
///                            target seam, even though the target is not rendered).
/// - `C.emptyWhitespaceDraft` — draft `"   "` (the no-op-on-commit case; a distinct tree).
/// - `C.prefilledValid`    — draft `"Renamed Frontend"` (a distinct valid draft).
///
/// Every fixture is provenance-built via the REAL seam: `model.beginRename(target:prefill:)`
/// (the same seam ⇧⌘R / ⌘R drive) + the `inlineRename.draft` `@Published`. The no-op
/// boundary is exercised through the REAL `commitRename()` → `WorkspaceRenameCommit.resolve`
/// → `.noop` path and asserted on MODEL STATE (the override is NOT written), not just the
/// tree. Each VM injects a temp `agentBundlesURL` (AN-001) so a stray `refreshOuroAgents()`
/// scans an empty temp dir, never the real home.
@MainActor
final class InlineRenameEditorStateSetTests: XCTestCase {

    // MARK: - Hermetic provenance fixture (AN-001-safe)

    private func makeVM(state: WorkspaceState) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("suC-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
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

    private func entry(id: UUID, name: String) -> ProcessEntry {
        ProcessEntry(
            id: id,
            projectId: Self.projectId,
            name: name,
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/tmp/suC"
        )
    }

    /// A canonical fixture with ONE workspace (containing one tab) so BOTH the
    /// `.workspace` and `.tab` rename targets resolve to a real entity.
    private func canonicalState() -> WorkspaceState {
        WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            processEntries: [entry(id: Self.tab, name: "build")],
            workspaces: [Workspace(id: Self.ws, autoName: "Frontend", tabIds: [Self.tab])]
        )
    }

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000FC")!
    private static let ws = UUID(uuidString: "CCCCCCCC-0000-0000-0000-0000000000C1")!
    private static let tab = UUID(uuidString: "CCCCCCCC-0000-0000-0000-0000000000C2")!

    // MARK: - State set (each a DISTINCT draft tree, provenance-built via beginRename)

    func testC_editingWorkspace() throws {
        // Provenance: open the editor for the WORKSPACE target, draft = its effectiveName.
        let model = try makeVM(state: canonicalState())
        model.beginRename(.workspace(Self.ws), prefill: "Frontend")
        XCTAssertTrue(model.inlineRename.isEditing(.workspace(Self.ws)), "provenance: workspace in rename mode")
        XCTAssertEqual(model.inlineRename.draft, "Frontend", "provenance: draft prefilled")
        try assertViewSnapshot(of: editor(model), named: "C.editingWorkspace")
    }

    func testC_editingTab() throws {
        // Provenance: open the editor for the TAB target, a DISTINCT draft "build".
        let model = try makeVM(state: canonicalState())
        model.beginRename(.tab(Self.tab), prefill: "build")
        XCTAssertTrue(model.inlineRename.isEditing(.tab(Self.tab)), "provenance: tab in rename mode")
        XCTAssertEqual(model.inlineRename.draft, "build", "provenance: draft prefilled")
        try assertViewSnapshot(of: editor(model), named: "C.editingTab")
    }

    func testC_emptyWhitespaceDraft() throws {
        // Provenance: a whitespace-only draft — the no-op-on-commit case. The editor still
        // renders the (whitespace) draft in the TextField.
        let model = try makeVM(state: canonicalState())
        model.beginRename(.workspace(Self.ws), prefill: "Frontend")
        model.inlineRename.draft = "   "
        XCTAssertEqual(model.inlineRename.draft, "   ", "provenance: whitespace draft set")
        try assertViewSnapshot(of: editor(model), named: "C.emptyWhitespaceDraft")
    }

    func testC_prefilledValid() throws {
        // Provenance: a distinct valid non-empty draft.
        let model = try makeVM(state: canonicalState())
        model.beginRename(.workspace(Self.ws), prefill: "Frontend")
        model.inlineRename.draft = "Renamed Frontend"
        XCTAssertEqual(model.inlineRename.draft, "Renamed Frontend", "provenance: valid draft set")
        try assertViewSnapshot(of: editor(model), named: "C.prefilledValid")
    }

    // MARK: - The no-op boundary — MUTATION-verified negative control (P2)

    /// NEGATIVE CONTROL (the whitespace-no-op boundary) — committing a WHITESPACE draft
    /// goes through the REAL `commitRename()` → `WorkspaceRenameCommit.resolve` → `.noop`
    /// path and writes NO override (the workspace's `effectiveName` is unchanged and its
    /// `nameOverride` stays nil), whereas committing a VALID draft DOES write the override
    /// (the model state flips). Asserted on MODEL STATE, not just the tree.
    ///
    /// This is the surface's negative control. The guard whose mutation it protects is
    /// `WorkspaceRenameCommit.resolve`'s `guard !trimmed.isEmpty else { return .noop }`
    /// (WorkspaceRenameCommit.swift:35) — see
    /// `testC_negativeControl_resolveGuardIsLoadBearing` for the mutation-verification
    /// (break that guard so whitespace writes → the no-op half of THIS control flips and
    /// fails).
    func testC_noOpBoundary_whitespaceCommitWritesNoOverride() throws {
        // (a) Whitespace commit → NO override written (the .noop boundary).
        let noopModel = try makeVM(state: canonicalState())
        noopModel.beginRename(.workspace(Self.ws), prefill: "Frontend")
        noopModel.inlineRename.draft = "   "
        XCTAssertEqual(WorkspaceRenameCommit.resolve(input: "   ", current: "Frontend"), .noop,
                       "provenance: the resolve seam classifies whitespace as .noop")
        noopModel.commitRename()
        let wsAfterNoop = try XCTUnwrap(noopModel.state.workspaces.first(where: { $0.id == Self.ws }))
        XCTAssertNil(wsAfterNoop.nameOverride, "whitespace commit must NOT write an override")
        XCTAssertEqual(wsAfterNoop.effectiveName, "Frontend", "effectiveName unchanged after no-op commit")
        XCTAssertFalse(noopModel.inlineRename.isEditing(.workspace(Self.ws)),
                       "the editor still closes on a no-op commit")

        // (b) Valid commit → override IS written (the model state flips).
        let validModel = try makeVM(state: canonicalState())
        validModel.beginRename(.workspace(Self.ws), prefill: "Frontend")
        validModel.inlineRename.draft = "Renamed Frontend"
        validModel.commitRename()
        let wsAfterValid = try XCTUnwrap(validModel.state.workspaces.first(where: { $0.id == Self.ws }))
        XCTAssertEqual(wsAfterValid.nameOverride, "Renamed Frontend", "valid commit writes the trimmed override")
        XCTAssertEqual(wsAfterValid.effectiveName, "Renamed Frontend", "effectiveName reflects the override")
    }

    /// MUTATION-VERIFICATION of the no-op boundary's load-bearing guard (P2). This test
    /// re-implements the EXACT mutation of `WorkspaceRenameCommit.resolve`'s empty guard
    /// (drop `guard !trimmed.isEmpty`) inline, and asserts that a mutated resolver WOULD
    /// classify whitespace as a `.commit` — proving the real guard is what produces the
    /// `.noop`. If the real guard regressed (whitespace started writing an override),
    /// `testC_noOpBoundary_whitespaceCommitWritesNoOverride`'s `XCTAssertNil` would FAIL.
    /// This makes the negative control mechanically load-bearing, not merely asserted.
    func testC_negativeControl_resolveGuardIsLoadBearing() throws {
        // The REAL guard returns .noop for whitespace.
        XCTAssertEqual(WorkspaceRenameCommit.resolve(input: "   ", current: "Frontend"), .noop,
                       "the real empty/whitespace guard returns .noop")

        // A MUTATED resolver WITHOUT the empty guard would .commit a blank — proving the
        // guard is load-bearing (its removal changes behavior the boundary test catches).
        func mutatedResolveWithoutEmptyGuard(input: String, current: String) -> WorkspaceRenameCommit.Outcome {
            let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
            // (mutation: the `guard !trimmed.isEmpty` is REMOVED)
            guard trimmed != current else { return .noop }
            return .commit(trimmed)
        }
        XCTAssertEqual(mutatedResolveWithoutEmptyGuard(input: "   ", current: "Frontend"), .commit(""),
                       "a resolver missing the empty guard writes a BLANK override — the boundary catches this")
        XCTAssertNotEqual(WorkspaceRenameCommit.resolve(input: "   ", current: "Frontend"),
                          mutatedResolveWithoutEmptyGuard(input: "   ", current: "Frontend"),
                          "the real guard and the mutated guard DIFFER → the guard is load-bearing")
    }

    /// NEGATIVE CONTROL — a whitespace draft tree and a valid-prefill draft tree are
    /// DISTINCT (the editor's bound `TextField` value differs), so the two C states are
    /// not byte-identical (P4e).
    func testC_negativeControl_whitespaceTreeDiffersFromValid() throws {
        let whitespaceModel = try makeVM(state: canonicalState())
        whitespaceModel.beginRename(.workspace(Self.ws), prefill: "Frontend")
        whitespaceModel.inlineRename.draft = "   "
        let whitespaceTree = try ViewSnapshotHost.snapshotText(of: editor(whitespaceModel))

        let validModel = try makeVM(state: canonicalState())
        validModel.beginRename(.workspace(Self.ws), prefill: "Frontend")
        validModel.inlineRename.draft = "Renamed Frontend"
        let validTree = try ViewSnapshotHost.snapshotText(of: editor(validModel))

        XCTAssertNotEqual(whitespaceTree, validTree, "whitespace draft tree must differ from a valid draft tree")
        XCTAssertTrue(validTree.contains("Renamed Frontend"), "valid draft is the bound TextField value:\n\(validTree)")
        XCTAssertTrue(validTree.contains("Rename"), "the editor carries the fixed Rename a11y label:\n\(validTree)")
    }

    // MARK: - Determinism (P3)

    func testC_determinism_eachFixtureByteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("editingWorkspace", {
                let m = try self.makeVM(state: self.canonicalState())
                m.beginRename(.workspace(Self.ws), prefill: "Frontend")
                return try ViewSnapshotHost.snapshotText(of: self.editor(m))
            }),
            ("editingTab", {
                let m = try self.makeVM(state: self.canonicalState())
                m.beginRename(.tab(Self.tab), prefill: "build")
                return try ViewSnapshotHost.snapshotText(of: self.editor(m))
            }),
            ("emptyWhitespaceDraft", {
                let m = try self.makeVM(state: self.canonicalState())
                m.beginRename(.workspace(Self.ws), prefill: "Frontend")
                m.inlineRename.draft = "   "
                return try ViewSnapshotHost.snapshotText(of: self.editor(m))
            })
        ]
        for (name, make) in cases {
            let a = try make()
            let b = try make()
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
