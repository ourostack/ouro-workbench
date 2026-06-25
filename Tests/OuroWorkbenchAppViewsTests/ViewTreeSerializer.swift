#if os(macOS)
import Foundation

/// Pure, deterministic node→text formatter (D-U1-8). Emits one indented line per
/// node in depth-first order:
///
///     viewType[/role] kind=<static|editable> text="…" image="…" label="…" value="…" id="…"
///
/// Children are indented +2 spaces per depth. A field that is `nil` (absent) is
/// OMITTED; a field that is present-but-empty renders as `name=""` (a present→
/// absent transition across states is therefore a visible diff — P2/P4e sensitivity).
/// The field ORDER is fixed. Because `ViewSnapshotNode` is the whitelist, the
/// formatter can emit nothing but whitelisted content — no geometry/color/font/
/// `.help`/address/raw-object can appear (P4b/P3).
enum ViewTreeSerializer {
    /// Two-space indent per depth level (D-U1-8).
    private static let indentUnit = "  "

    /// Serialize a single root node (and its subtree) to text.
    static func serialize(_ node: ViewSnapshotNode) -> String {
        serialize([node])
    }

    /// Serialize a forest (zero or more roots) to text. An empty forest → "".
    static func serialize(_ forest: [ViewSnapshotNode]) -> String {
        var lines: [String] = []
        for root in forest {
            appendLines(for: root, depth: 0, into: &lines)
        }
        return lines.joined(separator: "\n")
    }

    /// Depth-first: emit this node's line, then recurse into children at depth+1.
    private static func appendLines(for node: ViewSnapshotNode, depth: Int, into lines: inout [String]) {
        lines.append(line(for: node, depth: depth))
        for child in node.children {
            appendLines(for: child, depth: depth + 1, into: &lines)
        }
    }

    /// Format one node's single line (without children).
    private static func line(for node: ViewSnapshotNode, depth: Int) -> String {
        let indent = String(repeating: indentUnit, count: depth)

        // viewType[/role] — the leading token, never quoted.
        var head = node.viewType
        if let role = node.role {
            head += "/\(role)"
        }

        // Fixed field order: kind text image label value id.
        var fields: [String] = []
        if let kind = node.kind {
            fields.append("kind=\(kind.rawValue)")
        }
        appendQuoted("text", node.text, to: &fields)
        appendQuoted("image", node.image, to: &fields)
        appendQuoted("label", node.label, to: &fields)
        appendQuoted("value", node.value, to: &fields)
        appendQuoted("id", node.id, to: &fields)

        let body = fields.isEmpty ? head : "\(head) \(fields.joined(separator: " "))"
        return indent + body
    }

    /// Append `name="value"` when `value` is present (including the empty string);
    /// omit entirely when `value` is nil.
    private static func appendQuoted(_ name: String, _ value: String?, to fields: inout [String]) {
        guard let value else { return }
        fields.append("\(name)=\"\(value)\"")
    }
}
#endif
