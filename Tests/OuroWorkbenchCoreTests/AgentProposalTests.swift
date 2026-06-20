import XCTest
@testable import OuroWorkbenchCore

final class AgentProposalTests: XCTestCase {
    // MARK: - Fixtures

    private func sampleItem(
        id: String = "item-1",
        label: String = "Resume Claude session",
        detail: String? = "Working on the onboarding audit",
        command: String? = "claude --resume abc123",
        cwd: String? = "/Users/me/project",
        harness: AgentHarness? = .claudeCode,
        selected: Bool = true,
        editableFields: [AgentProposalItem.Field] = AgentProposalItem.Field.allCases
    ) -> AgentProposalItem {
        AgentProposalItem(
            id: id,
            label: label,
            detail: detail,
            command: command,
            cwd: cwd,
            harness: harness,
            selected: selected,
            editableFields: editableFields
        )
    }

    private func sampleProposal() -> AgentProposal {
        AgentProposal(
            id: "prop-1",
            title: "Bring back your work",
            items: [
                sampleItem(id: "a", label: "First", selected: true),
                sampleItem(id: "b", label: "Second", selected: false),
            ]
        )
    }

    // MARK: - AgentProposalItem.Field

    func testFieldRawValuesAreStable() {
        XCTAssertEqual(AgentProposalItem.Field.label.rawValue, "label")
        XCTAssertEqual(AgentProposalItem.Field.detail.rawValue, "detail")
        XCTAssertEqual(AgentProposalItem.Field.command.rawValue, "command")
        XCTAssertEqual(AgentProposalItem.Field.cwd.rawValue, "cwd")
    }

    func testFieldAllCasesCoversEveryEditableField() {
        XCTAssertEqual(
            Set(AgentProposalItem.Field.allCases),
            [.label, .detail, .command, .cwd]
        )
    }

    func testFieldDecodesUnknownRawValueToNil() throws {
        // An item from a newer producer may list a field we don't model; decoding
        // the editableFields array drops unknown entries rather than throwing.
        let json = Data("""
        {
            "id": "x",
            "label": "L",
            "selected": true,
            "editableFields": ["label", "somethingNew", "cwd"]
        }
        """.utf8)
        let item = try JSONDecoder().decode(AgentProposalItem.self, from: json)
        XCTAssertEqual(item.editableFields, [.label, .cwd])
    }

    // MARK: - Codable / Equatable

    func testItemRoundTripsWithAllFields() throws {
        let item = sampleItem()
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(AgentProposalItem.self, from: data)
        XCTAssertEqual(decoded, item)
    }

    func testItemRoundTripsWithNilOptionalFields() throws {
        let item = sampleItem(
            detail: nil,
            command: nil,
            cwd: nil,
            harness: nil,
            editableFields: []
        )
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(AgentProposalItem.self, from: data)
        XCTAssertEqual(decoded, item)
        XCTAssertNil(decoded.detail)
        XCTAssertNil(decoded.command)
        XCTAssertNil(decoded.cwd)
        XCTAssertNil(decoded.harness)
    }

    func testItemDecodesWithMissingOptionalKeys() throws {
        let json = Data("""
        {"id": "y", "label": "L", "selected": false}
        """.utf8)
        let item = try JSONDecoder().decode(AgentProposalItem.self, from: json)
        XCTAssertEqual(item.id, "y")
        XCTAssertEqual(item.label, "L")
        XCTAssertFalse(item.selected)
        XCTAssertNil(item.detail)
        XCTAssertNil(item.command)
        XCTAssertNil(item.cwd)
        XCTAssertNil(item.harness)
        XCTAssertEqual(item.editableFields, [])
    }

    func testProposalRoundTrips() throws {
        let proposal = sampleProposal()
        let data = try JSONEncoder().encode(proposal)
        let decoded = try JSONDecoder().decode(AgentProposal.self, from: data)
        XCTAssertEqual(decoded, proposal)
    }

    func testProposalEqualityIsValueBased() {
        XCTAssertEqual(sampleProposal(), sampleProposal())
        var changed = sampleProposal()
        changed.title = "Different"
        XCTAssertNotEqual(changed, sampleProposal())
    }

    // MARK: - toggle

    func testToggleFlipsSelection() {
        var proposal = sampleProposal()
        XCTAssertTrue(proposal.items[0].selected)
        proposal.toggle(itemID: "a")
        XCTAssertFalse(proposal.items[0].selected)
        proposal.toggle(itemID: "a")
        XCTAssertTrue(proposal.items[0].selected)
    }

    func testToggleUnknownItemIsNoOp() {
        var proposal = sampleProposal()
        let before = proposal
        proposal.toggle(itemID: "missing")
        XCTAssertEqual(proposal, before)
    }

    // MARK: - setSelected

    func testSetSelectedSetsExplicitValue() {
        var proposal = sampleProposal()
        proposal.setSelected(itemID: "b", true)
        XCTAssertTrue(proposal.items[1].selected)
        // Setting the same value again is stable (no flip).
        proposal.setSelected(itemID: "b", true)
        XCTAssertTrue(proposal.items[1].selected)
        proposal.setSelected(itemID: "a", false)
        XCTAssertFalse(proposal.items[0].selected)
    }

    func testSetSelectedUnknownItemIsNoOp() {
        var proposal = sampleProposal()
        let before = proposal
        proposal.setSelected(itemID: "missing", false)
        XCTAssertEqual(proposal, before)
    }

    func testSelectAllAndSelectNone() {
        var proposal = sampleProposal()
        proposal.setSelected(itemID: "a", true)
        proposal.setSelected(itemID: "b", true)
        XCTAssertTrue(proposal.items.allSatisfy(\.selected))
        proposal.setSelected(itemID: "a", false)
        proposal.setSelected(itemID: "b", false)
        XCTAssertFalse(proposal.items.contains(where: \.selected))
    }

    // MARK: - edit

    func testEditUpdatesLabel() {
        var proposal = sampleProposal()
        proposal.edit(itemID: "a", field: .label, value: "Edited label")
        XCTAssertEqual(proposal.items[0].label, "Edited label")
    }

    func testEditUpdatesEachEditableField() {
        var proposal = sampleProposal()
        proposal.edit(itemID: "a", field: .detail, value: "new detail")
        proposal.edit(itemID: "a", field: .command, value: "claude --resume zzz")
        proposal.edit(itemID: "a", field: .cwd, value: "/new/dir")
        XCTAssertEqual(proposal.items[0].detail, "new detail")
        XCTAssertEqual(proposal.items[0].command, "claude --resume zzz")
        XCTAssertEqual(proposal.items[0].cwd, "/new/dir")
    }

    func testEditFieldNotInEditableFieldsIsNoOp() {
        // command is NOT in the item's editableFields → the edit is rejected.
        var proposal = AgentProposal(
            id: "p",
            title: "t",
            items: [sampleItem(id: "a", command: "original", editableFields: [.label])]
        )
        proposal.edit(itemID: "a", field: .command, value: "hacked")
        XCTAssertEqual(proposal.items[0].command, "original")
    }

    func testEditUnknownItemIsNoOp() {
        var proposal = sampleProposal()
        let before = proposal
        proposal.edit(itemID: "missing", field: .label, value: "x")
        XCTAssertEqual(proposal, before)
    }

    func testEditDetailCwdCommandToValueWhenPreviouslyNil() {
        var proposal = AgentProposal(
            id: "p",
            title: "t",
            items: [sampleItem(id: "a", detail: nil, command: nil, cwd: nil)]
        )
        proposal.edit(itemID: "a", field: .detail, value: "d")
        XCTAssertEqual(proposal.items[0].detail, "d")
    }

    // MARK: - result()

    func testResultReturnsOnlySelectedItems() {
        let proposal = sampleProposal() // a selected, b not selected
        let result = proposal.result()
        XCTAssertEqual(result.id, "prop-1")
        XCTAssertEqual(result.items.count, 1)
        XCTAssertEqual(result.items.first?.id, "a")
    }

    func testResultReflectsEdits() {
        var proposal = sampleProposal()
        proposal.edit(itemID: "a", field: .command, value: "edited-command")
        let result = proposal.result()
        XCTAssertEqual(result.items.first?.command, "edited-command")
    }

    func testResultEmptyWhenNothingSelected() {
        var proposal = sampleProposal()
        proposal.setSelected(itemID: "a", false)
        proposal.setSelected(itemID: "b", false)
        let result = proposal.result()
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.id, "prop-1")
    }

    func testResultOfEmptyProposalIsEmpty() {
        let proposal = AgentProposal(id: "empty", title: "Nothing", items: [])
        let result = proposal.result()
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.id, "empty")
    }

    func testResultRoundTrips() throws {
        let result = sampleProposal().result()
        let data = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(AgentProposalResult.self, from: data)
        XCTAssertEqual(decoded, result)
    }
}
