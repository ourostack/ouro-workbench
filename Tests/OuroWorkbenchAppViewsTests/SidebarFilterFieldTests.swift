#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// C1 — `SidebarFilterField` (`:2906`). The filter field's data-driven tree:
///   - `if !model.sidebarFilter.isEmpty` → the clear button (`xmark.circle.fill` + a
///     "Clear session filter" a11y) appears once the operator has typed.
///   - `if model.sidebarFilterIsActive` → the scope indicator `Text`
///     (`SidebarFilterPresentation.scopeIndicator`: "Searching all workspaces" for a
///     STRUCTURED query, "Searching <workspace>" for a PLAIN one) REPLACES the three
///     tap-to-insert suggestion chips ("Waiting"/"Agent"/"Idle").
///   - the bound `TextField` carries the typed value (captured via `input()`, AN-002).
///
/// **Provenance (P2).** The field reads the model's REAL `@Published sidebarFilter` + the
/// derived `sidebarFilterIsActive`/`sidebarFilterIsGlobal` (both pure `SidebarSessionFilter`
/// seams) + `selectedProject?.name`. The VM is built through the real store seam
/// (`WorkbenchStore(paths:).save(state)` → fresh VM), with a FIXED project so the scope
/// indicator names a deterministic workspace; the typed filter is set through `model.sidebarFilter`
/// (the SAME `@Published` the live `TextField` binding writes — direct set IS the production
/// seam). AN-001: the temp `agentBundlesURL` dual-injection keeps the inventory scan hermetic.
///
/// **Determinism (P3).** A fixed project name + a fixed `/tmp/u4` rootPath; no clock; the
/// `.help(...)` tooltips are dropped (AN-004). Byte-identical twice; `!contains("/Users/")`.
///
/// **Enumerated state-set:**
///   - `empty`        — no filter → the suggestion chips render; NO clear button, NO scope.
///   - `plainActive`  — a plain free-text filter → clear button + "Searching <workspace>".
///   - `structured`   — a `status:waiting` structured query → clear button + "Searching all
///                      workspaces" (the global-scope arm).
@MainActor
final class SidebarFilterFieldTests: XCTestCase {

    private static let projectId = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!

    private func makeVM(filter: String) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("c1filter-\(UUID().uuidString)", isDirectory: true)
        let agentBundles = tmp.appendingPathComponent("AgentBundles", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "boss"),
            projects: [WorkbenchProject(id: Self.projectId, name: "Frontend", rootPath: "/tmp/u4")]
        )
        try WorkbenchStore(paths: paths).save(state)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(agentBundlesURL: agentBundles),
            ouroAgentInventory: OuroAgentInventory(agentBundlesURL: agentBundles)
        )
        model.sidebarFilter = filter // the @Published the live TextField binding writes
        return model
    }

    private func field(filter: String) throws -> SidebarFilterField {
        SidebarFilterField(model: try makeVM(filter: filter))
    }

    // MARK: - Enumerated state-set

    func testFilter_empty() throws {
        let view = try field(filter: "")
        XCTAssertFalse(view.model.sidebarFilterIsActive, "provenance: blank filter → not active")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertFalse(tree.contains("Clear session filter"), "empty: no clear button:\n\(tree)")
        XCTAssertFalse(tree.contains("Searching"), "empty: no scope indicator:\n\(tree)")
        XCTAssertTrue(tree.contains(#"text="Waiting""#), "empty: the suggestion chips render:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SidebarFilterField.empty")
    }

    func testFilter_plainActive() throws {
        let view = try field(filter: "build")
        XCTAssertTrue(view.model.sidebarFilterIsActive, "provenance: a typed filter → active")
        XCTAssertFalse(view.model.sidebarFilterIsGlobal, "provenance: plain text → scoped (not global)")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Clear session filter"), "plain: the clear button appears:\n\(tree)")
        XCTAssertTrue(tree.contains("Searching Frontend"), "plain: scope names the workspace:\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="Waiting""#), "plain: suggestion chips are replaced:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SidebarFilterField.plainActive")
    }

    func testFilter_structuredGlobal() throws {
        let view = try field(filter: "status:waiting")
        XCTAssertTrue(view.model.sidebarFilterIsGlobal, "provenance: a structured query searches globally")
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains("Clear session filter"), "structured: the clear button appears:\n\(tree)")
        XCTAssertTrue(tree.contains("Searching all workspaces"), "structured: the global scope:\n\(tree)")
        try assertViewSnapshot(of: view, named: "SidebarFilterField.structured")
    }

    // MARK: - Negative control (P2 mutation-verified)

    /// The filter's two gates drive the tree: a non-empty filter adds the clear button AND
    /// flips the suggestion chips → the scope indicator; a structured query flips the scope
    /// text from "Searching <workspace>" → "Searching all workspaces".
    func testFilter_negativeControl_filterGatesFlipTree() throws {
        let empty = try ViewSnapshotHost.snapshotText(of: try field(filter: ""))
        let plain = try ViewSnapshotHost.snapshotText(of: try field(filter: "build"))
        let structured = try ViewSnapshotHost.snapshotText(of: try field(filter: "owner:agent"))

        XCTAssertNotEqual(empty, plain, "typing a filter must change the tree (clear button + scope)")
        XCTAssertFalse(empty.contains("Clear session filter"), "empty: no clear button:\n\(empty)")
        XCTAssertTrue(plain.contains("Clear session filter"), "typed: clear button present:\n\(plain)")
        XCTAssertTrue(empty.contains(#"text="Idle""#), "empty: suggestion chips present:\n\(empty)")
        XCTAssertFalse(plain.contains(#"text="Idle""#), "typed: suggestion chips gone:\n\(plain)")

        XCTAssertNotEqual(plain, structured, "a structured query must flip the scope text")
        XCTAssertTrue(plain.contains("Searching Frontend"), "plain: scoped:\n\(plain)")
        XCTAssertTrue(structured.contains("Searching all workspaces"), "structured: global:\n\(structured)")
    }

    // MARK: - Determinism (P3)

    func testFilter_determinism_byteIdenticalTwiceAndNoLeak() throws {
        let cases = ["", "build", "status:waiting"]
        for filter in cases {
            let a = try ViewSnapshotHost.snapshotText(of: try field(filter: filter))
            let b = try ViewSnapshotHost.snapshotText(of: try field(filter: filter))
            XCTAssertEqual(a, b, "filter=\(filter.isEmpty ? "<empty>" : filter) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "filter=\(filter): no machine-path leak:\n\(a)")
        }
    }
}
#endif
