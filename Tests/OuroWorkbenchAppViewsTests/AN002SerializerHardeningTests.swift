#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// SU1 — AN-002 serializer-hardening negative control (the P4-fidelity fix).
///
/// The bug: an EDITABLE `TextField` node serializes the PLACEHOLDER literal
/// (`"Label"`) instead of the BOUND value (`item.label`), and `findAll` re-emits
/// that placeholder's inner label `Text` as a SECOND node. Consequence: a
/// regression to an editable field's DATA value does NOT change the snapshot
/// (only `"Label"` + `"Label"` show), so the regression is uncaught — while
/// STATIC fields ARE caught. These tests pin the FIXED behavior:
///   (1) the editable node carries the bound `item.label` as its `text`, so two
///       fixtures with DIFFERENT labels produce DIFFERENT trees; and
///   (2) the placeholder is NOT re-emitted as a separate `Text` node.
///
/// Every fixture is provenance-built via the REAL seam
/// (`AgentProposalQueue.enqueue` → VM → `pendingProposals`) — never
/// hand-assembled (P2). The VM is made hermetic (the AN-001 detached-cleanup task
/// is redirected at a temp AgentBundles dir).
@MainActor
final class AN002SerializerHardeningTests: XCTestCase {

    // MARK: - Hermetic provenance fixture (AN-001-safe)

    private func makeVM(enqueueing proposal: AgentProposal) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("an002-\(UUID().uuidString)", isDirectory: true)
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

    /// A one-item proposal whose `.label` field is editable and carries `label`.
    /// `detail`/`command`/`cwd` are dropped so the tree is just: counter, checkbox,
    /// the editable label node (+ its placeholder-dup, pre-fix), and the buttons.
    private func labelEditableProposal(label: String) -> AgentProposal {
        AgentProposal(
            id: "an002-1",
            title: "Bring back your work",
            items: [
                AgentProposalItem(
                    id: "item-1",
                    label: label,
                    selected: true,
                    editableFields: [.label]
                )
            ]
        )
    }

    // MARK: - (1) editable DATA-value regression must be CAUGHT

    /// Two provenance-built fixtures differing ONLY in the editable `item.label`
    /// bound value MUST produce DIFFERENT serialized trees. PRE-FIX this FAILS
    /// (both render the placeholder `"Label"`), proving AN-002 is real.
    func testEditableLabelValueChangesTree() throws {
        let treeA = try ViewSnapshotHost.snapshotText(of: BossProposalCardList(
            model: try makeVM(enqueueing: labelEditableProposal(label: "Restore terminal A"))
        ))
        let treeB = try ViewSnapshotHost.snapshotText(of: BossProposalCardList(
            model: try makeVM(enqueueing: labelEditableProposal(label: "Restore terminal Z"))
        ))

        XCTAssertNotEqual(
            treeA, treeB,
            "an editable field's bound-value change must change the tree (AN-002):\nA:\n\(treeA)\nB:\n\(treeB)"
        )
        // The editable node must carry the BOUND value, not the placeholder.
        XCTAssertTrue(
            treeA.contains(#"kind=editable text="Restore terminal A""#),
            "editable node must serialize the bound value, not the \"Label\" placeholder:\n\(treeA)"
        )
        XCTAssertFalse(
            treeA.contains(#"text="Label""#),
            "the \"Label\" placeholder must NOT appear anywhere (neither as the editable text nor a dup):\n\(treeA)"
        )
    }

    // MARK: - (2) NO duplicate placeholder Text node for an editable field

    /// An editable field must emit EXACTLY ONE node (the `kind=editable` TextField).
    /// PRE-FIX `findAll` re-emits the placeholder's inner label `Text` as a SECOND
    /// `kind=static` node → this assertion FAILS.
    func testEditableFieldEmitsNoDuplicatePlaceholderNode() throws {
        let nodes = try ViewSnapshotHost.extractNodes(
            of: BossProposalCardList(
                model: try makeVM(enqueueing: labelEditableProposal(label: "Restore terminal A"))
            ),
            locale: ViewSnapshotHost.posixLocale
        )

        // Exactly one node carries the editable label content; none is a static
        // duplicate of the placeholder OR the bound value.
        let editableLabelNodes = nodes.filter { $0.kind == .editable && $0.text == "Restore terminal A" }
        XCTAssertEqual(
            editableLabelNodes.count, 1,
            "exactly one editable node must carry the bound label value:\n\(nodes)"
        )
        let staticDuplicates = nodes.filter {
            $0.kind == .static && ($0.text == "Restore terminal A" || $0.text == "Label")
        }
        XCTAssertTrue(
            staticDuplicates.isEmpty,
            "no static duplicate of the editable label (bound value or placeholder) may be emitted:\n\(nodes)"
        )
    }
}
#endif
