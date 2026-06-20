import Foundation

/// A GENERAL, editable proposal the boss hands to the operator: a titled list of
/// items the operator ticks / edits / approves in a native card, after which the
/// selected (and possibly edited) items flow back to the boss as an
/// `AgentProposalResult`.
///
/// This is a CAPABILITY, never a gate. The boss reaches for it when it judges a
/// plan should be shown for approval; nothing in the discover/reconstruct/adopt
/// flow requires it. The model carries ZERO agency/MS knowledge — an item is just
/// a label plus optional `detail`/`command`/`cwd`/`harness` the boss filled in,
/// and the operator's edits/selections come back verbatim. The boss decides what
/// the items mean.
///
/// Pure value type: every mutation (`toggle`, `setSelected`, `edit`) is an
/// in-place struct update, so the App's queue/transport and the SwiftUI card both
/// drive it without any reference semantics.
public struct AgentProposal: Codable, Equatable, Sendable {
    /// Stable id the boss chooses (or the queue assigns) — the App writes the
    /// result back under this id so the boss can correlate.
    public var id: String
    /// Operator-facing heading for the card (e.g. "Bring back your work").
    public var title: String
    /// The proposed items, in presentation order.
    public var items: [AgentProposalItem]

    public init(id: String, title: String, items: [AgentProposalItem]) {
        self.id = id
        self.title = title
        self.items = items
    }

    /// Flip an item's `selected` flag. Unknown id is a no-op.
    public mutating func toggle(itemID: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].selected.toggle()
    }

    /// Set an item's `selected` flag to an explicit value. Unknown id is a no-op.
    public mutating func setSelected(itemID: String, _ selected: Bool) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        items[index].selected = selected
    }

    /// Edit one editable field of an item to a new value. The edit is applied only
    /// when `field` is listed in that item's `editableFields` — an item the boss
    /// marked non-editable for a given field can't be changed by the operator (or
    /// a malformed card). Unknown id, or a field the item didn't expose, is a
    /// no-op.
    public mutating func edit(itemID: String, field: AgentProposalItem.Field, value: String) {
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return }
        guard items[index].editableFields.contains(field) else { return }
        items[index].setValue(value, for: field)
    }

    /// Project the operator's decision back to the boss: only the SELECTED items,
    /// carrying their (possibly edited) values, under the same proposal `id`. This
    /// is the shape the boss reads to know what was approved.
    public func result() -> AgentProposalResult {
        AgentProposalResult(
            id: id,
            items: items.filter(\.selected)
        )
    }
}

/// One proposed item in an `AgentProposal`. GENERAL: a label plus optional fields
/// the boss populated for the operator to review/edit. `editableFields` names
/// exactly which fields the operator may change in the card; everything else is
/// display-only.
public struct AgentProposalItem: Codable, Equatable, Identifiable, Sendable {
    /// The fields of an item the operator is allowed to edit in the card. The boss
    /// lists the subset it wants editable; the card renders only those as inputs.
    public enum Field: String, CaseIterable, Codable, Sendable {
        case label
        case detail
        case command
        case cwd
    }

    public var id: String
    public var label: String
    public var detail: String?
    public var command: String?
    public var cwd: String?
    public var harness: AgentHarness?
    public var selected: Bool
    public var editableFields: [Field]

    public init(
        id: String,
        label: String,
        detail: String? = nil,
        command: String? = nil,
        cwd: String? = nil,
        harness: AgentHarness? = nil,
        selected: Bool,
        editableFields: [Field] = Field.allCases
    ) {
        self.id = id
        self.label = label
        self.detail = detail
        self.command = command
        self.cwd = cwd
        self.harness = harness
        self.selected = selected
        self.editableFields = editableFields
    }

    private enum CodingKeys: String, CodingKey {
        case id, label, detail, command, cwd, harness, selected, editableFields
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        label = try container.decode(String.self, forKey: .label)
        detail = try container.decodeIfPresent(String.self, forKey: .detail)
        command = try container.decodeIfPresent(String.self, forKey: .command)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        harness = try container.decodeIfPresent(AgentHarness.self, forKey: .harness)
        selected = try container.decode(Bool.self, forKey: .selected)
        // Decode editableFields as raw strings and drop any unknown field a newer
        // producer may list, so an item from a later build is still usable (with
        // only the fields this build understands editable).
        let rawFields = try container.decodeIfPresent([String].self, forKey: .editableFields) ?? []
        editableFields = rawFields.compactMap(Field.init(rawValue:))
    }

    /// Assign `value` to the given field. Pure helper used by `AgentProposal.edit`
    /// after it has already verified the field is editable.
    mutating func setValue(_ value: String, for field: Field) {
        switch field {
        case .label: label = value
        case .detail: detail = value
        case .command: command = value
        case .cwd: cwd = value
        }
    }
}

/// The operator's approved decision, projected from an `AgentProposal` via
/// `result()`: the proposal `id` plus only the SELECTED items (carrying any
/// edits). This is what the App writes back through the queue and the boss reads.
public struct AgentProposalResult: Codable, Equatable, Sendable {
    public var id: String
    public var items: [AgentProposalItem]

    public init(id: String, items: [AgentProposalItem]) {
        self.id = id
        self.items = items
    }
}
