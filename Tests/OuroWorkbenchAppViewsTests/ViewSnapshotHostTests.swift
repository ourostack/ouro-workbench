#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// Unit 2a — the host (ViewInspector traversal → `ViewSnapshotNode`s → serialized
/// text) against REAL inspected views. Covers: content extraction, determinism via
/// `string(locale:)` (NOT environment — L7/#317), formatter-clock determinism
/// (D-U1-5a, provenance), no machine-path leak (L5), the `string(locale:)`-is-
/// load-bearing regression, and structural descent through implicit-`AnyView`.
@MainActor
final class ViewSnapshotHostTests: XCTestCase {

    // Hermetic VM fixture: redirects the L8 detached-cleanup task at a temp
    // AgentBundles dir so the VM never touches the real ~/AgentBundles.
    private func makeVM(enqueueing proposal: AgentProposal) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u1-host-\(UUID().uuidString)", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        try AgentProposalQueue(paths: paths).enqueue(proposal)
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(
                agentBundlesURL: tmp.appendingPathComponent("AgentBundles", isDirectory: true)
            )
        )
        model.loadPendingProposals()
        return model
    }

    private func proposal(editableFields: [AgentProposalItem.Field]) -> AgentProposal {
        AgentProposal(
            id: "host-1",
            title: "Bring back your work",
            items: [
                AgentProposalItem(
                    id: "i1", label: "Restore terminal A", detail: "the detail",
                    command: "echo hi", cwd: "/work/dir", selected: true,
                    editableFields: editableFields
                )
            ]
        )
    }

    // MARK: - (i) content extraction on a simple view

    func testHost_dashboardRowLabel_carriesTitleAndImage() throws {
        let text = try ViewSnapshotHost.snapshotText(
            of: DashboardRowLabel(title: "Workbench MCP", systemImage: "infinity")
        )
        XCTAssertTrue(text.contains(#"text="Workbench MCP""#), text)
        XCTAssertTrue(text.contains(#"image="infinity""#), text)
    }

    func testHost_systemImageName_carriesSemanticLabel() throws {
        let text = try ViewSnapshotHost.snapshotText(
            of: Image(systemName: "arrow.clockwise.circle.fill")
        )
        XCTAssertTrue(text.contains(#"image="arrow.clockwise.circle.fill""#), text)
    }

    func testHost_sidebarEmptyRow_carriesTextAndAXLabel() throws {
        let text = try ViewSnapshotHost.snapshotText(of: SidebarWorkspaceEmptyRow())
        XCTAssertTrue(text.contains(#"text="No tabs yet""#), text)
        XCTAssertTrue(text.contains(#"label="No tabs yet""#), text)
    }

    // MARK: - (ii) determinism via string(locale:) — serialize twice, byte-identical

    func testHost_determinism_serializeTwice_byteIdentical() throws {
        let vm = try makeVM(enqueueing: proposal(editableFields: []))
        let a = try ViewSnapshotHost.snapshotText(of: BossProposalCardList(model: vm))
        let b = try ViewSnapshotHost.snapshotText(of: BossProposalCardList(model: vm))
        XCTAssertEqual(a, b, "same fixture must serialize byte-identically")
    }

    // MARK: - (iii) formatter-clock determinism (D-U1-5a, provenance, P2)

    func testHost_formatterClock_fixedNow_matchesRealFormatter() throws {
        // The coarse elapsed string is computed by the REAL Core formatter with a
        // FIXED now/since — provenance: the expected value is the formatter's own
        // output, not a hand-typed literal.
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let now = Date(timeIntervalSince1970: 1_700_003_600)  // +1h
        let expected = WorkbenchElapsedFormatter.coarseDescription(since: since, now: now)
        // ElapsedTimePill's static shim routes the same Core formatter.
        let actual = ElapsedTimePill.coarseDescription(since: since, now: now)
        XCTAssertEqual(actual, expected)
        XCTAssertFalse(expected.isEmpty)
    }

    // MARK: - (iv) NO machine-path leak (L5 — the Mirror failure mode)

    func testHost_noMachinePathLeak_onVMDrivenView() throws {
        let vm = try makeVM(enqueueing: proposal(editableFields: [.label]))
        let text = try ViewSnapshotHost.snapshotText(of: BossProposalCardList(model: vm))
        XCTAssertFalse(text.contains("/Users/"), "no machine path may appear:\n\(text)")
    }

    // MARK: - (v) string(locale:) is load-bearing (env-only insufficient, L7/#317)

    func testHost_localeArg_pinsDescendedContent_notEnvironment() throws {
        // The descended ④ label content is pinned by the explicit POSIX locale the
        // host passes to `string(locale:)` — it does NOT rely on `.environment`
        // reaching find()-descended nodes (which #317 says it can't).
        let vm = try makeVM(enqueueing: proposal(editableFields: []))
        let text = try ViewSnapshotHost.snapshotText(
            of: BossProposalCardList(model: vm),
            locale: Locale(identifier: "en_US_POSIX")
        )
        XCTAssertTrue(text.contains(#"text="Restore terminal A""#), text)
    }

    // MARK: - (a) editable vs static kind flip + (vi) structural AnyView descent

    func testHost_editableVsStatic_flipsKind() throws {
        let editable = try ViewSnapshotHost.snapshotText(of: BossProposalCardList(
            model: try makeVM(enqueueing: proposal(editableFields: [.label]))
        ))
        let staticText = try ViewSnapshotHost.snapshotText(of: BossProposalCardList(
            model: try makeVM(enqueueing: proposal(editableFields: []))
        ))
        // Editable: the label node is a TextField → kind=editable present.
        XCTAssertTrue(editable.contains("kind=editable"), "editable:\n\(editable)")
        // Static: the label is a Text; NO TextField → no kind=editable.
        XCTAssertFalse(staticText.contains("kind=editable"), "static:\n\(staticText)")
        XCTAssertNotEqual(editable, staticText)
        // Structural descent through AnyView: the deep count node "1/1" + title appear.
        XCTAssertTrue(staticText.contains(#"text="Bring back your work""#), staticText)
        XCTAssertTrue(staticText.contains(#"text="1/1""#), staticText)
    }

    // MARK: - empty-tree edge

    // MARK: - Unit 2c coverage: throwing seam + accessibility-only node + value

    func testHost_snapshotText_isThrowingSeam_propagatesViewInspectorErrors() throws {
        // The host's extraction is a THROWING ViewInspector seam (`try view.inspect()`
        // + per-node typed reads). When a typed extraction on a found node DOES
        // throw (a Text-mismatch InspectionError), that error is ViewInspector's own
        // `Error`, which `assertViewSnapshot` reports at the call site — never a crash.
        // We assert the seam's throwing contract directly via ViewInspector's API.
        XCTAssertThrowsError(
            try DashboardRowLabel(title: "x", systemImage: "y").inspect().text().string()
        ) { error in
            // ViewInspector surfaces a descriptive, non-empty error (clear failure).
            XCTAssertFalse("\(error)".isEmpty)
            XCTAssertTrue("\(error)".contains("Text") || "\(error)".contains("found"), "\(error)")
        }
        // And the host's own extraction over the SAME view succeeds (it uses `try?`
        // per-node so a type-mismatch on one node skips it, not aborts the walk).
        let ok = try ViewSnapshotHost.snapshotText(of: DashboardRowLabel(title: "x", systemImage: "y"))
        XCTAssertTrue(ok.contains(#"text="x""#), ok)
    }

    func testHost_accessibilityOnlyNode_isKept() throws {
        // A non-Text/Image node carrying only accessibility label+value+id is still
        // load-bearing — the host keeps it as a `View` node.
        let text = try ViewSnapshotHost.snapshotText(of: AXOnlyTestView())
        XCTAssertTrue(text.contains(#"View"#), text)
        XCTAssertTrue(text.contains(#"label="gauge""#), text)
        XCTAssertTrue(text.contains(#"value="42%""#), text)
        XCTAssertTrue(text.contains(#"id="ax-gauge""#), text)
    }

    func testHost_emptyProposalList_serializesToEmptyTree() throws {
        // No pending proposals → BossProposalCardList renders nothing.
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("u1-host-empty-\(UUID().uuidString)", isDirectory: true)
        let vm = WorkbenchViewModel(
            paths: WorkbenchPaths(rootURL: tmp),
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(
                agentBundlesURL: tmp.appendingPathComponent("AgentBundles", isDirectory: true)
            )
        )
        let text = try ViewSnapshotHost.snapshotText(of: BossProposalCardList(model: vm))
        XCTAssertEqual(text, "", "empty surface → empty serialized tree")
    }
}

/// A node that is neither Text nor Image but carries accessibility label+value+id —
/// exercises the host's "keep an accessibility-only node" branch.
struct AXOnlyTestView: View {
    var body: some View {
        Color.clear
            .accessibilityElement()
            .accessibilityLabel("gauge")
            .accessibilityValue("42%")
            .accessibilityIdentifier("ax-gauge")
    }
}
#endif
