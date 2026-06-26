#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// SU2 — Surface F (④ proposal card) COMPLETE enumerated state-set (campaign
/// §Surfaces F): list {none / one / many}; card {0 items / one / many; counter
/// none / some / all}; itemRow {selected vs not; each of label/detail/command/cwd
/// × editable / static / absent} — `editableFields` is the boundary driver.
///
/// Every fixture is provenance-built via the REAL seam
/// (`AgentProposalQueue.enqueue` → VM → `loadPendingProposals` → `pendingProposals`)
/// — NEVER hand-assembled (P2). Each VM injects a temp `agentBundlesURL` so no test
/// touches the real `~/AgentBundles` (AN-001). The host pins the locale to
/// `en_US_POSIX` and the serializer whitelist makes a machine-path / clock / UUID
/// leak structurally impossible (P3).
///
/// **Coverage mapping (minimal, non-redundant — P4c/P4e):**
///   - `F.list.none`                — LIST none → empty tree.
///   - `F.list.many`                — LIST many (2 cards, distinct titles); also
///                                    COUNTER all (1/1) + none (0/1) and itemRow
///                                    selected + not (one card each).
///   - `F.card.zeroItems`           — CARD 0 items; COUNTER none-via-zero (0/0).
///   - `F.card.manyItems`           — CARD many (3 items); COUNTER some (1/3);
///                                    selected + not within ONE card.
///   - `F.fields.allEditable`       — LIST one; CARD one item; per-field EDITABLE
///                                    × {label, detail, command, cwd} (bound values).
///   - `F.fields.allStatic`         — per-field STATIC × {label, detail, command,
///                                    cwd} (present, `editableFields: []`).
///   - `F.fields.absentAndEmpty`    — per-field ABSENT (detail/cwd nil + static →
///                                    skipped) AND editable-with-nil (command nil +
///                                    editable → empty `TextField`).
@MainActor
final class BossProposalCardStateSetTests: XCTestCase {

    // MARK: - Hermetic provenance fixture (AN-001-safe)

    /// Build a hermetic VM that has loaded the given proposals through the real
    /// queue seam. `agentBundlesURL` is redirected at a temp dir (AN-001).
    private func makeVM(enqueueing proposals: [AgentProposal]) throws -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("su2-\(UUID().uuidString)", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        let queue = AgentProposalQueue(paths: paths)
        for proposal in proposals {
            try queue.enqueue(proposal)
        }
        let model = WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(
                agentBundlesURL: tmp.appendingPathComponent("AgentBundles", isDirectory: true)
            )
        )
        model.loadPendingProposals()
        XCTAssertEqual(
            model.pendingProposals.count, proposals.count,
            "every enqueued proposal must reach the VM via the seam (provenance, P2)"
        )
        return model
    }

    private func card(_ model: WorkbenchViewModel) -> BossProposalCardList {
        BossProposalCardList(model: model)
    }

    // MARK: - LIST none / many

    func testF_list_none() throws {
        // No proposals enqueued → the list renders NOTHING (empty tree).
        let model = try makeVM(enqueueing: [])
        try assertViewSnapshot(of: card(model), named: "F.list.none")
    }

    func testF_list_many() throws {
        // Two cards (sorted by id): an all-selected card (counter 1/1, selected
        // row) and an all-unselected card (counter 0/1, not-selected row).
        let alpha = AgentProposal(
            id: "p-alpha", title: "Alpha plan",
            items: [AgentProposalItem(id: "a1", label: "Alpha item", selected: true, editableFields: [])]
        )
        let bravo = AgentProposal(
            id: "p-bravo", title: "Bravo plan",
            items: [AgentProposalItem(id: "b1", label: "Bravo item", selected: false, editableFields: [])]
        )
        let model = try makeVM(enqueueing: [alpha, bravo])
        try assertViewSnapshot(of: card(model), named: "F.list.many")
    }

    // MARK: - CARD 0 items / many items

    func testF_card_zeroItems() throws {
        // A card whose `items` is empty → header + counter "0/0" + buttons, no rows.
        let proposal = AgentProposal(id: "p-zero", title: "Empty plan", items: [])
        let model = try makeVM(enqueueing: [proposal])
        try assertViewSnapshot(of: card(model), named: "F.card.zeroItems")
    }

    func testF_card_manyItems() throws {
        // One card, THREE items, exactly one selected → counter "1/3" (some); the
        // selected + not-selected checkbox states both appear within one card.
        let proposal = AgentProposal(
            id: "p-many", title: "Three-item plan",
            items: [
                AgentProposalItem(id: "i1", label: "First item", selected: true, editableFields: []),
                AgentProposalItem(id: "i2", label: "Second item", selected: false, editableFields: []),
                AgentProposalItem(id: "i3", label: "Third item", selected: false, editableFields: [])
            ]
        )
        let model = try makeVM(enqueueing: [proposal])
        try assertViewSnapshot(of: card(model), named: "F.card.manyItems")
    }

    // MARK: - per-field editable / static / absent

    func testF_fields_allEditable() throws {
        // One item, ALL FOUR fields editable → four `kind=editable` TextFields each
        // carrying its DISTINCT bound value (the AN-002-hardened path).
        let proposal = AgentProposal(
            id: "p-edit", title: "Editable plan",
            items: [
                AgentProposalItem(
                    id: "e1",
                    label: "Editable label",
                    detail: "Editable detail",
                    command: "ouro do edit",
                    cwd: "/edit/cwd",
                    selected: true,
                    editableFields: [.label, .detail, .command, .cwd]
                )
            ]
        )
        let model = try makeVM(enqueueing: [proposal])
        try assertViewSnapshot(of: card(model), named: "F.fields.allEditable")
    }

    func testF_fields_allStatic() throws {
        // One item, ALL FOUR fields present but NONE editable → four `kind=static`
        // Text nodes carrying their values.
        let proposal = AgentProposal(
            id: "p-static", title: "Static plan",
            items: [
                AgentProposalItem(
                    id: "s1",
                    label: "Static label",
                    detail: "Static detail",
                    command: "ouro do static",
                    cwd: "/static/cwd",
                    selected: false,
                    editableFields: []
                )
            ]
        )
        let model = try makeVM(enqueueing: [proposal])
        try assertViewSnapshot(of: card(model), named: "F.fields.allStatic")
    }

    func testF_fields_absentAndEmpty() throws {
        // detail + cwd ABSENT (nil, not editable → skipped entirely); command is
        // EDITABLE-but-nil → renders an EMPTY `TextField`; label is static. Hits the
        // "absent" and "editable-with-nil-value" per-field cells.
        let proposal = AgentProposal(
            id: "p-absent", title: "Sparse plan",
            items: [
                AgentProposalItem(
                    id: "x1",
                    label: "Only a label",
                    detail: nil,
                    command: nil,
                    cwd: nil,
                    selected: true,
                    editableFields: [.command]
                )
            ]
        )
        let model = try makeVM(enqueueing: [proposal])
        try assertViewSnapshot(of: card(model), named: "F.fields.absentAndEmpty")
    }

    // MARK: - U5 B8 — card/item INTERACTIONS (drive the action + binding closures)

    /// U5 B8 — the "Dismiss" `Button` action (`:7517` — `Button("Dismiss") { model.dismissProposal(
    /// proposalID:) }`). Tapping it writes an empty result, removes the pending proposal, and reloads
    /// → `pendingProposals` drops the card. ASSERT the proposal is gone.
    func testF_dismissTap_removesProposal() throws {
        let proposal = AgentProposal(
            id: "p-dismiss", title: "Dismiss me",
            items: [AgentProposalItem(id: "d1", label: "An item", selected: true, editableFields: [])])
        let model = try makeVM(enqueueing: [proposal])
        XCTAssertEqual(model.pendingProposals.count, 1, "precondition: one pending proposal")
        try card(model).inspect().find(button: "Dismiss").tap()
        XCTAssertTrue(model.pendingProposals.isEmpty,
                      "Dismiss tap → dismissProposal removes the pending proposal")
    }

    /// U5 B8 — the "Approve" `Button` action (`:7523` — `Button("Approve") { model.approveProposal(
    /// proposalID:) }`). Tapping it writes the proposal's result, removes it, and reloads → the card
    /// disappears. ASSERT the proposal is gone.
    func testF_approveTap_removesProposal() throws {
        let proposal = AgentProposal(
            id: "p-approve", title: "Approve me",
            items: [AgentProposalItem(id: "a1", label: "An item", selected: true, editableFields: [])])
        let model = try makeVM(enqueueing: [proposal])
        XCTAssertEqual(model.pendingProposals.count, 1, "precondition: one pending proposal")
        try card(model).inspect().find(button: "Approve").tap()
        XCTAssertTrue(model.pendingProposals.isEmpty,
                      "Approve tap → approveProposal removes the pending proposal")
    }

    /// U5 B8 — the checkbox `Button` action (`:7558` — `Button { model.toggleProposalItem(...) }`).
    /// Tapping the (only) checkbox button flips the item's `selected` flag in `pendingProposals`.
    /// We start `selected: false` and assert it becomes true (the captured `1/1` counter would follow).
    func testF_checkboxTap_togglesSelection() throws {
        let proposal = AgentProposal(
            id: "p-toggle", title: "Toggle me",
            items: [AgentProposalItem(id: "t1", label: "An item", selected: false, editableFields: [])])
        let model = try makeVM(enqueueing: [proposal])
        XCTAssertEqual(model.pendingProposals.first?.items.first?.selected, false, "precondition: not selected")
        // Buttons: [0] checkbox, then Dismiss/Approve. The checkbox is the first button.
        let buttons = try card(model).inspect().findAll(ViewType.Button.self)
        try buttons[0].tap()  // the row checkbox
        XCTAssertEqual(model.pendingProposals.first?.items.first?.selected, true,
                       "tapping the checkbox toggles the item's selected flag")
    }

    /// U5 B8 — the editable-field binding SETTER (`:7552` — `set: { model.editProposalItem(...) }`).
    /// An editable `.label` field renders a bound `TextField`; calling `setInput("…")` on it routes
    /// through the `fieldBinding` `set:` closure → `editProposalItem` → the value changes in
    /// `pendingProposals`. ASSERT the edited value lands.
    func testF_editableBindingSetter_routesEditThroughModel() throws {
        let proposal = AgentProposal(
            id: "p-edit", title: "Edit me",
            items: [AgentProposalItem(id: "e1", label: "Original", selected: true, editableFields: [.label])])
        let model = try makeVM(enqueueing: [proposal])
        XCTAssertEqual(model.pendingProposals.first?.items.first?.label, "Original", "precondition")
        try card(model).inspect().find(ViewType.TextField.self).setInput("Edited via binding")
        XCTAssertEqual(model.pendingProposals.first?.items.first?.label, "Edited via binding",
                       "the TextField binding setter routes the edit through editProposalItem")
    }

    /// U5 B8 — the editable-with-NIL-value `?? ""` fallbacks for detail + cwd (`:7583`/`:7605` —
    /// `fieldBinding(.detail, current: item.detail ?? "")` / `.cwd, current: item.cwd ?? ""`). The
    /// existing `absentAndEmpty` test only made `.command` editable-with-nil; here `.detail` AND `.cwd`
    /// are editable but nil → their `?? ""` fallback autoclosures fire when the bound `TextField`s are
    /// built (rendering EMPTY editable fields). ASSERT both empty editable fields render.
    func testF_editableNilDetailAndCwd_emptyFallbackFields() throws {
        let proposal = AgentProposal(
            id: "p-nilfields", title: "Sparse editable",
            items: [AgentProposalItem(
                id: "n1", label: "Only label", detail: nil, command: "cmd", cwd: nil,
                selected: true, editableFields: [.detail, .cwd])])
        let model = try makeVM(enqueueing: [proposal])
        let tree = try ViewSnapshotHost.snapshotText(of: card(model))
        // Two empty editable TextFields (detail + cwd) render — the `?? ""` fallbacks were taken.
        let editableEmpty = tree.components(separatedBy: #"kind=editable text="""#).count - 1
        XCTAssertGreaterThanOrEqual(editableEmpty, 2,
                                    "the nil detail + nil cwd editable fields render empty (?? \"\" taken):\n\(tree)")
        try assertViewSnapshot(of: card(model), named: "F.fields.editableNilDetailCwd")
    }

    // MARK: - Negative controls (P2) — beyond the existing isEditable flip

    /// NEGATIVE CONTROL #1 — toggling an item's `selected` flips the checkbox image
    /// + accessibility label AND the card counter. (Beyond the isEditable flip.)
    func testF_negativeControl_selectionFlipsCheckboxAndCounter() throws {
        func tree(selected: Bool) throws -> String {
            let proposal = AgentProposal(
                id: "p-sel", title: "Selection plan",
                items: [AgentProposalItem(id: "s1", label: "An item", selected: selected, editableFields: [])]
            )
            return try ViewSnapshotHost.snapshotText(of: card(try makeVM(enqueueing: [proposal])))
        }
        let selectedTree = try tree(selected: true)
        let notSelectedTree = try tree(selected: false)

        XCTAssertNotEqual(selectedTree, notSelectedTree, "toggling selected must change the tree")
        XCTAssertTrue(selectedTree.contains(#"image="checkmark.circle.fill" label="Selected""#), selectedTree)
        XCTAssertTrue(selectedTree.contains(#"text="1/1""#), "counter all when selected:\n\(selectedTree)")
        XCTAssertTrue(notSelectedTree.contains(#"image="circle" label="Not selected""#), notSelectedTree)
        XCTAssertTrue(notSelectedTree.contains(#"text="0/1""#), "counter none when not selected:\n\(notSelectedTree)")
    }

    /// NEGATIVE CONTROL #2 — changing an EDITABLE field's bound DATA value changes
    /// the tree (the regression AN-002 made catchable; only possible now that the
    /// node carries the bound value, not the placeholder).
    func testF_negativeControl_editableBoundValueRegressionIsCaught() throws {
        func tree(label: String) throws -> String {
            let proposal = AgentProposal(
                id: "p-edval", title: "Edit plan",
                items: [AgentProposalItem(id: "e1", label: label, selected: true, editableFields: [.label])]
            )
            return try ViewSnapshotHost.snapshotText(of: card(try makeVM(enqueueing: [proposal])))
        }
        let a = try tree(label: "Original label")
        let b = try tree(label: "Tampered label")
        XCTAssertNotEqual(a, b, "an editable field's bound-value change must change the tree (AN-002)")
        XCTAssertTrue(a.contains(#"kind=editable text="Original label""#), a)
        XCTAssertTrue(b.contains(#"kind=editable text="Tampered label""#), b)
    }

    /// NEGATIVE CONTROL #3 — dropping an item from a card changes the tree (item
    /// count + counter denominator both move).
    func testF_negativeControl_droppingAnItemChangesTree() throws {
        func tree(itemCount: Int) throws -> String {
            let items = (0..<itemCount).map {
                AgentProposalItem(id: "i\($0)", label: "Item \($0)", selected: false, editableFields: [])
            }
            let proposal = AgentProposal(id: "p-drop", title: "Drop plan", items: items)
            return try ViewSnapshotHost.snapshotText(of: card(try makeVM(enqueueing: [proposal])))
        }
        let two = try tree(itemCount: 2)
        let one = try tree(itemCount: 1)
        XCTAssertNotEqual(two, one, "dropping an item must change the tree")
        XCTAssertTrue(two.contains(#"text="0/2""#), "two items → counter denominator 2:\n\(two)")
        XCTAssertTrue(one.contains(#"text="0/1""#), "one item → counter denominator 1:\n\(one)")
    }

    // MARK: - Determinism — every fixture serializes byte-identically twice; no leak

    func testF_determinism_eachFixtureByteIdenticalTwiceAndNoLeak() throws {
        let cases: [(String, () throws -> String)] = [
            ("none", { try ViewSnapshotHost.snapshotText(of: self.card(try self.makeVM(enqueueing: []))) }),
            ("many", {
                try ViewSnapshotHost.snapshotText(of: self.card(try self.makeVM(enqueueing: [
                    AgentProposal(id: "p-alpha", title: "Alpha plan",
                                  items: [AgentProposalItem(id: "a1", label: "Alpha item", selected: true, editableFields: [])]),
                    AgentProposal(id: "p-bravo", title: "Bravo plan",
                                  items: [AgentProposalItem(id: "b1", label: "Bravo item", selected: false, editableFields: [])])
                ])))
            }),
            ("allEditable", {
                try ViewSnapshotHost.snapshotText(of: self.card(try self.makeVM(enqueueing: [
                    AgentProposal(id: "p-edit", title: "Editable plan", items: [
                        AgentProposalItem(id: "e1", label: "Editable label", detail: "Editable detail",
                                          command: "ouro do edit", cwd: "/edit/cwd",
                                          selected: true, editableFields: [.label, .detail, .command, .cwd])
                    ])
                ])))
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
