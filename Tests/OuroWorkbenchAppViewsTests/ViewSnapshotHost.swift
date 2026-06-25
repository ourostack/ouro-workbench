#if os(macOS)
import Foundation
import SwiftUI
import ViewInspector

/// `@MainActor` host that turns a SwiftUI view into the deterministic serialized
/// tree text. It runs ViewInspector's traversal over the view-under-test via the
/// no-`ViewHosting` `@ObservedObject` synchronous `inspect()` path (D-U1-VI; the
/// regime Unit 0 confirmed), maps each content-bearing node onto a
/// `ViewSnapshotNode` (the extraction adapter), and feeds `ViewTreeSerializer`.
///
/// **Determinism (L7 / ViewInspector #317):** content is read through an explicit
/// fixed `Locale(identifier: "en_US_POSIX")` passed to `Text.string(locale:)` —
/// that is the GUARANTEE. `.environment(\.locale,…)` does NOT reach `find()`-
/// descended nodes, so the host does not rely on it (no env wrap is needed for the
/// guarantee; `string(locale:)` already pins every read). `.string()` with no arg
/// would default to `.testsDefault` (≠ POSIX), so the explicit arg is mandatory.
///
/// **Node shape (D-U1-9, decided mid-flight — recorded in the doing doc):** the
/// adapter emits a FLAT depth-first list of the content-bearing nodes
/// (`Text`/`TextField`/`Image`/accessibility-labelled), because ViewInspector's
/// public API exposes a clean depth-first enumeration (`findAll`) but not a robust
/// public parent→child hierarchy walk (its recursion uses internal `UnwrappedView`
/// APIs, and positional `AnyView` reconstruction is the cross-toolchain hazard L6
/// forbids). The load-bearing signals — declared content + the `kind=editable`
/// vs `kind=static` flip — are fully captured by the flat list (Unit 0 proved it),
/// with zero machine-path leak. The serializer's nesting support is retained
/// (fake-node-tested, Unit 1) for a future hierarchy walk.
@MainActor
enum ViewSnapshotHost {
    static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Inspect `view`, extract the content-bearing nodes, and serialize to text.
    /// `throws` because ViewInspector's traversal is throwing: a node-not-found /
    /// unsupported node propagates ViewInspector's `InspectionError` (which has a
    /// readable `localizedDescription`), and `assertViewSnapshot` reports it as a
    /// clear failure at the call site — never a crash.
    static func snapshotText<V: View>(of view: V, locale: Locale = posixLocale) throws -> String {
        let nodes = try extractNodes(of: view, locale: locale)
        return ViewTreeSerializer.serialize(nodes)
    }

    /// The extraction adapter: inspect → flat depth-first `ViewSnapshotNode` list.
    /// `try view.inspect()` and the per-node typed reads are throwing ViewInspector
    /// calls; an inspection failure propagates as ViewInspector's own `Error`.
    ///
    /// **AN-002 de-dup:** `findAll` enumerates a `TextField`'s supplementary
    /// `labelView()` (the placeholder `Text`) as a SEPARATE node. That placeholder
    /// is NOT load-bearing — the `TextField` node itself already carries the bound
    /// value (read via `input()` in `mapNode`) — so re-emitting it would (a) noise
    /// the tree (P4b) and (b) mask a bound-value regression behind a constant
    /// placeholder. We drop it by skipping any node whose `pathToRoot` marks it as
    /// a `TextField`'s `labelView()` child (`isTextFieldPlaceholder`).
    static func extractNodes<V: View>(of view: V, locale: Locale) throws -> [ViewSnapshotNode] {
        let classifiedNodes = try view.inspect().findAll(where: { _ in true })
        var nodes: [ViewSnapshotNode] = []
        for classified in classifiedNodes {
            if isTextFieldPlaceholder(classified) { continue }
            if let node = mapNode(classified, locale: locale) {
                nodes.append(node)
            }
        }
        return nodes
    }

    /// True when `view` is the supplementary `labelView()` (placeholder `Text`) of
    /// a `TextField` — i.e. its `pathToRoot` contains a `.textField(…)` hop
    /// immediately followed by a `.labelView()` hop. ViewInspector builds the
    /// placeholder child with `call: "labelView()"` (TextField.swift:43), so this
    /// is a robust, content-independent identity signal (a genuine `Text` whose
    /// string happens to equal the placeholder literal is NOT skipped, because it
    /// is not under a `.textField(…).labelView()` path).
    private static func isTextFieldPlaceholder(
        _ view: InspectableView<ViewType.ClassifiedView>
    ) -> Bool {
        let path = view.pathToRoot
        guard let labelRange = path.range(of: ".labelView()") else { return false }
        // The hop immediately preceding the `.labelView()` must be a `.textField(`.
        let prefix = path[..<labelRange.lowerBound]
        guard let dotRange = prefix.range(of: ".textField(", options: .backwards) else { return false }
        // Nothing but the `textField(…)` token may sit between the two hops.
        return !prefix[dotRange.upperBound...].contains(".")
    }

    /// Map one inspected node to a `ViewSnapshotNode` IFF it carries whitelisted
    /// content. A structural-only node (a bare `VStack`/`HStack`/`AnyView` with no
    /// own text/image/label) contributes nothing — keeping the snapshot to
    /// load-bearing content (P4b). Returns nil for such nodes.
    private static func mapNode(
        _ view: InspectableView<ViewType.ClassifiedView>,
        locale: Locale
    ) -> ViewSnapshotNode? {
        // Accessibility label/value/id are read regardless of node type.
        let label = (try? view.accessibilityLabel().string(locale: locale))
        let value = (try? view.accessibilityValue().string(locale: locale))
        let id = try? view.accessibilityIdentifier()

        // A TextField → an EDITABLE node (the load-bearing Mirror-gap signal). Its
        // node text is the BOUND VALUE (via `input()` = `inputBinding().wrappedValue`,
        // TextField.swift:96), NOT the placeholder literal — so a regression to an
        // editable field's DATA value is caught (AN-002). The placeholder's inner
        // `Text` is de-duped upstream in `extractNodes` (`isTextFieldPlaceholder`).
        if let textField = try? view.textField() {
            let bound = try? textField.input()
            return ViewSnapshotNode(
                viewType: "TextField",
                kind: .editable,
                text: bound,
                label: label, value: value, id: id
            )
        }

        // A Text → a STATIC node.
        if let string = try? view.text().string(locale: locale) {
            return ViewSnapshotNode(
                viewType: "Text",
                kind: .static,
                text: string,
                label: label, value: value, id: id
            )
        }

        // An Image → its SF Symbol / asset name.
        if let name = try? view.image().actualImage().name() {
            return ViewSnapshotNode(
                viewType: "Image",
                image: name,
                label: label, value: value, id: id
            )
        }

        // A non-content node that nonetheless carries an accessibility label/value/id
        // (e.g. a labelled container) is still load-bearing — keep it.
        if label != nil || value != nil || id != nil {
            return ViewSnapshotNode(viewType: "View", label: label, value: value, id: id)
        }

        // Pure structure (stacks, AnyView wrappers, spacers) → contributes nothing.
        return nil
    }
}
#endif
