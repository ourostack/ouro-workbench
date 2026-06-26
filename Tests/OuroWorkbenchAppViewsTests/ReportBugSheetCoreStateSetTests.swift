#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C5-1 — `ReportBugSheet` CORE states (the high-fan-out Report-a-Bug sheet, #U16/#U30).
/// The sheet's `body` is a stack of `@Published`-driven gates that each flip a CAPTURED
/// subtree:
///   - `if model.bugReportNote.isEmpty` → the placeholder `Text("Describe what you were
///       doing…")` (the note's empty/typed flip — see the harness note below).
///   - `if let error = model.bugReportError` → the red error `Label(error, …triangle.fill)`.
///   - `if model.bugReportIsSubmitting` → the "collecting" `ProgressView` + the submit
///       button `.disabled` — see the NON-VACUITY note: this arm is structurally
///       UNOBSERVABLE through the host whitelist (a `ProgressView` emits no node and
///       `.disabled` is dropped), so it is CLASSIFIED + recorded, NOT snapshotted vacuously.
/// The static disclosure `Label(ReportBugDisclosureCopy.disclosure, …info.circle)` always
/// renders (pure-Core copy — leak-free + deterministic). The success/issue-URL gates
/// (`if let url = model.lastBugReportURL`) are the C5-2 file.
///
/// **Provenance (P2).** Every state is built through the REAL model seam: `bugReportNote`,
/// `bugReportError`, and `bugReportIsSubmitting` are the SAME writable `@Published` the live
/// submit flow (`submitBugReport()`) sets — direct injection IS the production seam (the
/// AN-001 / BossDashboard precedent). `model` is built via the `makeVM` dual-injection store
/// seam (AN-001 hermetic — no `~/AgentBundles` scan leaks a machine agent name).
///
/// **Determinism (P3).** No timestamp / `NSFullUserName()` / machine name reaches this
/// surface's captured tree: the error + note are fixed fixture strings, the disclosure is
/// static pure-Core copy, and the `.help("Create the report (⌘↩)")` submit tooltip is
/// dropped by the host (AN-004). Byte-identical twice + `!contains("/Users/")`.
///
/// **Harness note (the note-field flip).** The host's `mapNode` special-cases only
/// `textField()`; a `TextEditor`'s bound value is NOT emitted as a node. So the
/// `bugReportNote` empty→typed transition is captured via the PLACEHOLDER `Text` (gated by
/// `if bugReportNote.isEmpty`) appearing/disappearing — that IS the real captured-tree
/// LOGIC, asserted directly.
///
/// **Enumerated CORE state-set:**
///   - `empty`       — `bugReportNote == ""`, no error, not submitting → placeholder shows,
///       submit enabled, no spinner (the pristine baseline).
///   - `typed`       — `bugReportNote == "…"` → the placeholder DISAPPEARS (note-field flip).
///   - `error`       — `bugReportError != nil` → the red error Label renders.
///
/// **NON-VACUITY — the `collecting` (`bugReportIsSubmitting == true`) arm is DEFERRED
/// (structurally-unobservable, recorded NOT fabricated; the C1/AN-006 + non-vacuity
/// discipline):** the only difference the submitting arm makes to the body is a node-less
/// `ProgressView` spinner and a `.disabled(true)` on the submit button — and the host
/// whitelist captures NEITHER (a `ProgressView` maps to no `ViewSnapshotNode`; `.disabled`
/// is dropped, P4b). The captured tree is therefore BYTE-IDENTICAL to `empty`. Committing a
/// `collecting` reference identical to `empty` would be a VACUOUS green (it would pass even
/// if the arm broke). We instead PROVE the arm is unobservable
/// (`testReportBug_collectingArm_isUnobservableThroughWhitelist`) and record it as a
/// deferred surface — never fabricating a duplicate snapshot.
@MainActor
final class ReportBugSheetCoreStateSetTests: XCTestCase {

    // MARK: - Hermetic model (AN-001 dual-injection)

    private func makeVM() throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c5-reportbug-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let state = WorkspaceState(boss: BossAgentSelection(agentName: "boss"))
        try WorkbenchStore(paths: paths).save(state)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles))
    }

    /// The placeholder copy (the `if bugReportNote.isEmpty` gate's captured Text).
    private static let placeholder =
        "Describe what you were doing and what went wrong. Steps to reproduce help a lot."

    // MARK: - Enumerated state-set

    func testReportBug_empty() throws {
        let model = try makeVM()
        XCTAssertTrue(model.bugReportNote.isEmpty, "provenance: pristine empty note")
        XCTAssertNil(model.bugReportError, "provenance: no error")
        XCTAssertFalse(model.bugReportIsSubmitting, "provenance: not submitting")
        let tree = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: model))
        XCTAssertTrue(tree.contains(Self.placeholder), "empty: the note placeholder renders:\n\(tree)")
        XCTAssertTrue(tree.contains("Report a Bug"), "the sheet title renders:\n\(tree)")
        XCTAssertTrue(tree.contains("Create Report"), "the submit button renders:\n\(tree)")
        XCTAssertFalse(tree.contains("Saved bug report"), "empty: no success box:\n\(tree)")
        try assertViewSnapshot(of: ReportBugSheet(model: model), named: "ReportBugSheet.empty")
    }

    func testReportBug_typed() throws {
        let model = try makeVM()
        model.bugReportNote = "The boss watch loop stopped firing after I toggled it off and on."
        XCTAssertFalse(model.bugReportNote.isEmpty, "provenance: a typed note")
        let tree = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: model))
        XCTAssertFalse(tree.contains(Self.placeholder),
                       "typed: the placeholder DISAPPEARS (the note-field flip):\n\(tree)")
        XCTAssertTrue(tree.contains("Report a Bug"), "the sheet title still renders:\n\(tree)")
        try assertViewSnapshot(of: ReportBugSheet(model: model), named: "ReportBugSheet.typed")
    }

    func testReportBug_error() throws {
        let model = try makeVM()
        model.bugReportError = "Could not write the bundle: the reports folder is read-only."
        let tree = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: model))
        XCTAssertTrue(tree.contains("Could not write the bundle: the reports folder is read-only."),
                      "error: the error message renders:\n\(tree)")
        XCTAssertTrue(tree.contains("exclamationmark.triangle.fill"),
                      "error: the red triangle glyph renders:\n\(tree)")
        try assertViewSnapshot(of: ReportBugSheet(model: model), named: "ReportBugSheet.error")
    }

    /// The `collecting` (`bugReportIsSubmitting == true`) arm is DEFERRED as
    /// structurally-unobservable: it only adds a node-less `ProgressView` and a dropped
    /// `.disabled` — so the captured tree is byte-identical to `empty`. We PROVE that
    /// (so a future host change that DID capture the spinner would re-open this honestly)
    /// rather than commit a vacuous duplicate snapshot. Recorded NOT fabricated.
    func testReportBug_collectingArm_isUnobservableThroughWhitelist() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: try makeVM()))
        let submittingModel = try makeVM()
        submittingModel.bugReportIsSubmitting = true
        let submitting = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: submittingModel))
        XCTAssertEqual(empty, submitting,
                       "the bugReportIsSubmitting arm only adds a node-less ProgressView + a "
                       + "dropped .disabled → it does NOT flip the captured tree (deferred, NOT "
                       + "fabricated). If this ever differs, the arm became observable → cover it.")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The model gates flip whole captured subtrees: the note placeholder (empty vs typed)
    /// and the error Label (nil vs set) each appear only when their seam is in the gated
    /// state. (The `collecting` spinner is a node-less ProgressView; its tree-distinctness
    /// is covered by the byte-identical-twice determinism check, not a content assertion.)
    func testReportBug_negativeControl_gatesFlipTree() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: try makeVM()))

        let typedModel = try makeVM()
        typedModel.bugReportNote = "typed"
        let typed = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: typedModel))
        XCTAssertNotEqual(empty, typed, "the note-empty gate must flip the captured tree")
        XCTAssertTrue(empty.contains(Self.placeholder), "empty: placeholder present:\n\(empty)")
        XCTAssertFalse(typed.contains(Self.placeholder), "typed: placeholder gone:\n\(typed)")

        let errorModel = try makeVM()
        errorModel.bugReportError = "boom"
        let withError = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: errorModel))
        XCTAssertNotEqual(empty, withError, "the error gate must flip the captured tree")
        XCTAssertTrue(withError.contains("boom"), "error: the message renders:\n\(withError)")
        XCTAssertFalse(empty.contains("boom"), "empty: no error content:\n\(empty)")
    }

    // MARK: - Determinism (P3)

    func testReportBug_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let builders: [(String, () throws -> WorkbenchViewModel)] = [
            ("empty", { try self.makeVM() }),
            ("typed", {
                let m = try self.makeVM()
                m.bugReportNote = "typed note"
                return m
            }),
            ("error", {
                let m = try self.makeVM()
                m.bugReportError = "read-only folder"
                return m
            })
        ]
        for (name, makeModel) in builders {
            let model = try makeModel()
            let a = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: model))
            let b = try ViewSnapshotHost.snapshotText(of: ReportBugSheet(model: model))
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine-path leak:\n\(a)")
        }
    }
}
#endif
