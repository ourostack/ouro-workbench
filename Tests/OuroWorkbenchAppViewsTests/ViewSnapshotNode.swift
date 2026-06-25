#if os(macOS)
import Foundation

/// One node of a serialized SwiftUI view tree — the WHITELIST itself. It carries
/// ONLY declared content + structure (D-U1-VI / P4b): the view-type/role, the
/// editable-vs-static `kind`, `Text` content, `Image` name, accessibility
/// `label`/`value`/`identifier`, and children. There is deliberately NO field for
/// geometry / color / font / `.help` tooltip / pointer-address / a raw model
/// object — so those CAN NOT leak through the serializer (the Mirror VM-graph
/// path leak is structurally impossible here, not merely filtered).
///
/// Lives in the test target (D-U1-1). The ViewInspector-extraction adapter
/// (`InspectedNodeAdapter`, Unit 2) maps an inspected node onto this model; this
/// pure value type lets Unit 1 drive the formatter without ViewInspector.
struct ViewSnapshotNode: Equatable {
    /// Whether a text-bearing node renders editably (a `TextField`) or statically
    /// (a `Text`). Absent for non-text nodes — the load-bearing distinction Mirror
    /// missed, the field the `editableFields`-driven negative control flips.
    enum Kind: String, Equatable {
        case `static`
        case editable
    }

    /// The view-type token (e.g. `Text`, `TextField`, `Image`, `VStack`).
    var viewType: String
    /// An optional role qualifier rendered as `viewType/role`.
    var role: String?
    /// Editable-vs-static classification; nil for non-text nodes.
    var kind: Kind?
    /// Declared `Text`/`TextField` content (read via `string(locale: en_US_POSIX)`).
    var text: String?
    /// SF Symbol / asset name of an `Image`.
    var image: String?
    /// Accessibility label.
    var label: String?
    /// Accessibility value.
    var value: String?
    /// Accessibility identifier.
    var id: String?
    /// Child nodes, in depth-first (declared) order.
    var children: [ViewSnapshotNode]

    init(
        viewType: String,
        role: String? = nil,
        kind: Kind? = nil,
        text: String? = nil,
        image: String? = nil,
        label: String? = nil,
        value: String? = nil,
        id: String? = nil,
        children: [ViewSnapshotNode] = []
    ) {
        self.viewType = viewType
        self.role = role
        self.kind = kind
        self.text = text
        self.image = image
        self.label = label
        self.value = value
        self.id = id
        self.children = children
    }
}
#endif
