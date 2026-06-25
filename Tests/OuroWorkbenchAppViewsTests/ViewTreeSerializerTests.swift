#if os(macOS)
import XCTest

/// Unit 1a — drives the PURE formatting logic of `ViewTreeSerializer` with a
/// hand-built `ViewSnapshotNode` tree (NO ViewInspector). Asserts the D-U1-8 line
/// format + field order, `kind=static|editable`, indentation, depth-first child
/// recursion, omit-vs-empty per field, unicode passthrough, the empty-tree edge,
/// and the WHITELIST negation (a node can only carry whitelisted fields — there is
/// no field for geometry/help/address/raw-object, so they can never appear).
///
/// The ViewInspector-extraction adapter (inspected node → `ViewSnapshotNode`) is
/// tested in Unit 2 against a real inspected view.
final class ViewTreeSerializerTests: XCTestCase {

    // MARK: - Line format + field order (D-U1-8)

    func testSingleNode_typeOnly() {
        let node = ViewSnapshotNode(viewType: "Text")
        XCTAssertEqual(ViewTreeSerializer.serialize(node), "Text")
    }

    func testSingleNode_role() {
        let node = ViewSnapshotNode(viewType: "Image", role: "decorative")
        XCTAssertEqual(ViewTreeSerializer.serialize(node), "Image/decorative")
    }

    func testFieldOrder_isFixed() {
        // viewType[/role] kind text image label value id — exactly this order.
        let node = ViewSnapshotNode(
            viewType: "Cell",
            role: "row",
            kind: .static,
            text: "T",
            image: "img",
            label: "L",
            value: "V",
            id: "the-id"
        )
        XCTAssertEqual(
            ViewTreeSerializer.serialize(node),
            #"Cell/row kind=static text="T" image="img" label="L" value="V" id="the-id""#
        )
    }

    func testKind_editable() {
        let node = ViewSnapshotNode(viewType: "TextField", kind: .editable, text: "Label")
        XCTAssertEqual(ViewTreeSerializer.serialize(node), #"TextField kind=editable text="Label""#)
    }

    func testKind_static() {
        let node = ViewSnapshotNode(viewType: "Text", kind: .static, text: "hi")
        XCTAssertEqual(ViewTreeSerializer.serialize(node), #"Text kind=static text="hi""#)
    }

    func testKind_absentForNonTextNodes() {
        // A node with no kind shows no `kind=` field at all.
        let node = ViewSnapshotNode(viewType: "Image", image: "checklist")
        XCTAssertEqual(ViewTreeSerializer.serialize(node), #"Image image="checklist""#)
    }

    // MARK: - Omit-vs-empty per field

    func testOmittedFields_doNotAppear() {
        // text present, everything else absent → only text= shows.
        let node = ViewSnapshotNode(viewType: "Text", text: "only")
        XCTAssertEqual(ViewTreeSerializer.serialize(node), #"Text text="only""#)
    }

    func testEmptyStringField_isRenderedAsEmptyQuotes() {
        // An explicit empty string (present-but-empty) is a VISIBLE field (diff
        // signal): it renders text="" rather than being dropped, so a field
        // appearing/disappearing across states is a diff.
        let node = ViewSnapshotNode(viewType: "Text", text: "")
        XCTAssertEqual(ViewTreeSerializer.serialize(node), #"Text text="""#)
    }

    func testLabelValueId_individually() {
        XCTAssertEqual(
            ViewTreeSerializer.serialize(ViewSnapshotNode(viewType: "X", label: "L")),
            #"X label="L""#
        )
        XCTAssertEqual(
            ViewTreeSerializer.serialize(ViewSnapshotNode(viewType: "X", value: "V")),
            #"X value="V""#
        )
        XCTAssertEqual(
            ViewTreeSerializer.serialize(ViewSnapshotNode(viewType: "X", id: "I")),
            #"X id="I""#
        )
    }

    // MARK: - Indentation + depth-first recursion

    func testChildren_indentedPlusTwo_depthFirst() {
        let tree = ViewSnapshotNode(
            viewType: "VStack",
            children: [
                ViewSnapshotNode(viewType: "Text", text: "a"),
                ViewSnapshotNode(
                    viewType: "HStack",
                    children: [
                        ViewSnapshotNode(viewType: "Image", image: "star"),
                        ViewSnapshotNode(viewType: "Text", text: "b")
                    ]
                ),
                ViewSnapshotNode(viewType: "Text", text: "c")
            ]
        )
        let expected = """
        VStack
          Text text="a"
          HStack
            Image image="star"
            Text text="b"
          Text text="c"
        """
        XCTAssertEqual(ViewTreeSerializer.serialize(tree), expected)
    }

    func testDeeplyNested_indentationScalesPerLevel() {
        let tree = ViewSnapshotNode(
            viewType: "L0",
            children: [ViewSnapshotNode(
                viewType: "L1",
                children: [ViewSnapshotNode(
                    viewType: "L2",
                    children: [ViewSnapshotNode(viewType: "L3", text: "deep")]
                )]
            )]
        )
        let expected = """
        L0
          L1
            L2
              L3 text="deep"
        """
        XCTAssertEqual(ViewTreeSerializer.serialize(tree), expected)
    }

    // MARK: - Edge cases

    func testEmptyTree_serializesToEmptyString() {
        // The "no nodes" case: serializing an absent forest is the empty string.
        XCTAssertEqual(ViewTreeSerializer.serialize([]), "")
    }

    func testForest_multipleRoots() {
        let forest = [
            ViewSnapshotNode(viewType: "A", text: "1"),
            ViewSnapshotNode(viewType: "B", text: "2")
        ]
        XCTAssertEqual(
            ViewTreeSerializer.serialize(forest),
            "A text=\"1\"\nB text=\"2\""
        )
    }

    func testUnicodeContent_passesThrough() {
        let node = ViewSnapshotNode(viewType: "Text", text: "Café — 北京 🚀 — \u{2014}")
        XCTAssertEqual(
            ViewTreeSerializer.serialize(node),
            "Text text=\"Café — 北京 🚀 — —\""
        )
    }

    // MARK: - Whitelist negation (P4b/P3)

    func testWhitelist_onlyWhitelistedFieldsExist() {
        // The node model carries ONLY whitelisted fields. There is no API to
        // attach geometry / help / address / a raw object — so a fully-populated
        // node's serialization can NEVER contain those tokens.
        let node = ViewSnapshotNode(
            viewType: "Cell",
            role: "row",
            kind: .editable,
            text: "T",
            image: "I",
            label: "L",
            value: "V",
            id: "ID"
        )
        let out = ViewTreeSerializer.serialize(node)
        for forbidden in ["frame", "CGRect", "0x", "Color", "Font", ".help(", "/Users/", "ObservableObject"] {
            XCTAssertFalse(out.contains(forbidden), "whitelist breach: \(forbidden) in \(out)")
        }
    }
}
#endif
