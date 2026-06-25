#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// Unit 4 — THE PROOF. Snapshots the complex ④ surface (the internal
/// `BossProposalCardList`, descending into the PRIVATE `BossProposalCard` /
/// `BossProposalItemRow`) in editable vs static item states, plus the 2 simpler
/// leaf views, against committed references. Asserts:
///   (a) match-committed-reference (via `assertViewSnapshot`);
///   (b) determinism (serialize twice → byte-identical);
///   (c) the RENDERED-control flip Mirror FAILED to produce — an
///       `editableFields`-driven `TextField`(kind=editable) ↔ `Text`(kind=static)
///       change at the label node (the diff is at the rendered control, NOT the
///       data array);
///   (input control) a mutated fixture diverges from its reference.
///
/// Every fixture is built via the REAL seam (`AgentProposalQueue.enqueue` → VM →
/// `pendingProposals`) — never hand-assembled (provenance, P2). The VM is made
/// hermetic (the L8 detached-cleanup task is redirected at a temp AgentBundles dir).
@MainActor
final class ViewSnapshotProofTests: XCTestCase {

    // MARK: - Hermetic provenance fixture

    private func makeVM(enqueueing proposal: AgentProposal) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u1-proof-\(UUID().uuidString)", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try AgentProposalQueue(paths: paths).enqueue(proposal)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(
                agentBundlesURL: tmp.appendingPathComponent("AgentBundles", isDirectory: true)
            )
        )
        model.loadPendingProposals()
        XCTAssertEqual(model.pendingProposals.count, 1, "fixture must reach the VM via the seam")
        return model
    }

    /// The ④ fixture. `editableFields` drives the per-field TextField-vs-Text render.
    private func bringBackProposal(editableFields: [AgentProposalItem.Field]) -> AgentProposal {
        AgentProposal(
            id: "bring-back-1",
            title: "Bring back your work",
            items: [
                AgentProposalItem(
                    id: "item-1",
                    label: "Restore terminal A",
                    detail: "agent-a in ~/proj",
                    command: "ouro resume agent-a",
                    cwd: "/repo/agent-a",
                    selected: true,
                    editableFields: editableFields
                ),
                AgentProposalItem(
                    id: "item-2",
                    label: "Restore terminal B",
                    detail: "agent-b idle",
                    command: "ouro resume agent-b",
                    cwd: "/repo/agent-b",
                    selected: false,
                    editableFields: editableFields
                )
            ]
        )
    }

    // MARK: - (a) committed references — the complex ④ surface (editable + static)

    func testBossProposalCardList_editable() throws {
        let model = try makeVM(enqueueing: bringBackProposal(editableFields: [.label]))
        try assertViewSnapshot(of: BossProposalCardList(model: model), named: "BossProposalCardList.editable")
    }

    func testBossProposalCardList_static() throws {
        let model = try makeVM(enqueueing: bringBackProposal(editableFields: []))
        try assertViewSnapshot(of: BossProposalCardList(model: model), named: "BossProposalCardList.static")
    }

    // MARK: - (a) committed references — the 2 simpler leaf views

    func testDashboardRowLabel_default() throws {
        try assertViewSnapshot(
            of: DashboardRowLabel(title: "Workbench MCP", systemImage: "point.3.connected.trianglepath.dotted"),
            named: "DashboardRowLabel.default"
        )
    }

    func testSidebarWorkspaceEmptyRow_default() throws {
        try assertViewSnapshot(of: SidebarWorkspaceEmptyRow(), named: "SidebarWorkspaceEmptyRow.default")
    }

    // MARK: - (c) THE negative control Mirror FAILED — the rendered-control flip

    func testNegativeControl_editableFieldsFlipsRenderedKind() throws {
        // Same provenance-built item, two `editableFields` values. The label node
        // MUST flip from a rendered TextField (kind=editable) to a rendered Text
        // (kind=static) — the diff is at the RENDERED control, not the data array
        // (the exact distinction Mirror could not make).
        let editable = try ViewSnapshotHost.snapshotText(of: BossProposalCardList(
            model: try makeVM(enqueueing: bringBackProposal(editableFields: [.label]))
        ))
        let staticTree = try ViewSnapshotHost.snapshotText(of: BossProposalCardList(
            model: try makeVM(enqueueing: bringBackProposal(editableFields: []))
        ))

        // The trees differ.
        XCTAssertNotEqual(editable, staticTree, "editable vs static must produce different trees")

        // Editable renders ≥1 TextField (kind=editable); static renders none.
        XCTAssertTrue(editable.contains("kind=editable"),
                      "editable: label node must render kind=editable (TextField):\n\(editable)")
        XCTAssertFalse(staticTree.contains("kind=editable"),
                       "static: NO node may render kind=editable (all Text):\n\(staticTree)")

        // The SAME label content "Restore terminal A" is present in both — proving
        // the flip is at the CONTROL TYPE, not the data (the label string is constant).
        // In editable it's the TextField's content/placeholder context; in static it's
        // a Text. The static tree carries the label text statically.
        XCTAssertTrue(staticTree.contains(#"kind=static text="Restore terminal A""#),
                      "static label renders as Text:\n\(staticTree)")
    }

    // MARK: - (b) determinism — serialize twice → byte-identical

    func testDeterminism_eachProofFixtureSerializesByteIdenticalTwice() throws {
        let cases: [(String, () throws -> String)] = [
            ("editable", { try ViewSnapshotHost.snapshotText(of: BossProposalCardList(
                model: try self.makeVM(enqueueing: self.bringBackProposal(editableFields: [.label])))) }),
            ("static", { try ViewSnapshotHost.snapshotText(of: BossProposalCardList(
                model: try self.makeVM(enqueueing: self.bringBackProposal(editableFields: [])))) }),
            ("dashboard", { try ViewSnapshotHost.snapshotText(
                of: DashboardRowLabel(title: "Workbench MCP", systemImage: "point.3.connected.trianglepath.dotted")) }),
            ("emptyrow", { try ViewSnapshotHost.snapshotText(of: SidebarWorkspaceEmptyRow()) })
        ]
        for (name, make) in cases {
            let a = try make()
            let b = try make()
            XCTAssertEqual(a, b, "\(name) must serialize byte-identically twice")
            XCTAssertFalse(a.contains("/Users/"), "\(name): no machine path leak:\n\(a)")
        }
    }

    // MARK: - (input control) a mutated fixture diverges from its reference

    func testInputControl_mutatedFixtureDiffersFromStaticReference() throws {
        // The committed static reference is the unmutated tree. A fixture with a
        // different label must NOT match it.
        let referenceTree = try ViewSnapshotHost.snapshotText(of: BossProposalCardList(
            model: try makeVM(enqueueing: bringBackProposal(editableFields: []))
        ))
        let mutated = AgentProposal(
            id: "bring-back-1",
            title: "Bring back your work",
            items: [
                AgentProposalItem(
                    id: "item-1", label: "DIFFERENT LABEL", detail: "agent-a in ~/proj",
                    command: "ouro resume agent-a", cwd: "/repo/agent-a",
                    selected: true, editableFields: []
                )
            ]
        )
        let mutatedTree = try ViewSnapshotHost.snapshotText(of: BossProposalCardList(
            model: try makeVM(enqueueing: mutated)
        ))
        XCTAssertNotEqual(mutatedTree, referenceTree, "a mutated fixture must change the tree")
        XCTAssertTrue(mutatedTree.contains(#"text="DIFFERENT LABEL""#), mutatedTree)
    }
}
#endif
