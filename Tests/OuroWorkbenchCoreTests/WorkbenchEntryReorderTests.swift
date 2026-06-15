import XCTest
@testable import OuroWorkbenchCore

private struct Item: Identifiable, Equatable {
    let id: String
    let group: String
}

final class WorkbenchEntryReorderTests: XCTestCase {
    /// `global` has multiple groups interleaved; `visible` is the
    /// project-scoped slice. Moving the second visible row to the front
    /// must reorder only within `groupA` items in the global array, leaving
    /// `groupB` entries in place.
    func testMoveWithinFilteredViewPreservesOtherGroups() {
        let global: [Item] = [
            Item(id: "a1", group: "A"),
            Item(id: "b1", group: "B"),
            Item(id: "a2", group: "A"),
            Item(id: "b2", group: "B"),
            Item(id: "a3", group: "A")
        ]
        let visible = global.filter { $0.group == "A" }
        // Move "a3" (index 2 in visible) to before "a1" (destination 0).
        let result = WorkbenchEntryReorder.move(
            global: global,
            visible: visible,
            fromOffsets: IndexSet(integer: 2),
            toOffset: 0
        )
        XCTAssertEqual(result.map(\.id), ["a3", "a1", "b1", "a2", "b2"])
    }

    func testMoveToEndOfVisibleRange() {
        let global: [Item] = [
            Item(id: "x1", group: "X"),
            Item(id: "x2", group: "X"),
            Item(id: "x3", group: "X")
        ]
        let result = WorkbenchEntryReorder.move(
            global: global,
            visible: global,
            fromOffsets: IndexSet(integer: 0),
            toOffset: 3 // SwiftUI's "drop after last" destination
        )
        XCTAssertEqual(result.map(\.id), ["x2", "x3", "x1"])
    }

    func testMoveToEndWithEmptyVisibleUsesGlobalEndAsAnchor() {
        let global: [Item] = [Item(id: "a", group: "A"), Item(id: "b", group: "B")]

        let result = WorkbenchEntryReorder.move(
            global: global,
            visible: [],
            fromOffsets: IndexSet(),
            toOffset: 0
        )

        XCTAssertEqual(result.map(\.id), ["a", "b"])
    }

    func testMissingDestinationAnchorFallsBackToEndOfGlobalOrder() {
        let global: [Item] = [Item(id: "a", group: "A"), Item(id: "b", group: "A")]
        let visible = [Item(id: "ghost", group: "A"), Item(id: "a", group: "A")]

        let result = WorkbenchEntryReorder.move(
            global: global,
            visible: visible,
            fromOffsets: IndexSet(integer: 1),
            toOffset: 0
        )

        XCTAssertEqual(result.map(\.id), ["b", "a"])
    }

    func testMultipleSelectionMovesAsContiguousBlock() {
        let global: [Item] = [
            Item(id: "a", group: "A"),
            Item(id: "b", group: "A"),
            Item(id: "c", group: "A"),
            Item(id: "d", group: "A")
        ]
        // Move "a" + "c" (offsets {0, 2}) to position 4 (end). They should
        // land contiguously after "b" and "d", in their original order.
        let result = WorkbenchEntryReorder.move(
            global: global,
            visible: global,
            fromOffsets: IndexSet([0, 2]),
            toOffset: 4
        )
        XCTAssertEqual(result.map(\.id), ["b", "d", "a", "c"])
    }

    func testOutOfBoundsDestinationLeavesArrayUnchanged() {
        let global: [Item] = [Item(id: "a", group: "A"), Item(id: "b", group: "A")]
        let result = WorkbenchEntryReorder.move(
            global: global,
            visible: global,
            fromOffsets: IndexSet(integer: 0),
            toOffset: 999
        )
        XCTAssertEqual(result.map(\.id), ["a", "b"])
    }

    func testEmptyMoveLeavesArrayUnchanged() {
        let global: [Item] = [Item(id: "a", group: "A"), Item(id: "b", group: "A")]
        let result = WorkbenchEntryReorder.move(
            global: global,
            visible: global,
            fromOffsets: IndexSet(),
            toOffset: 0
        )
        XCTAssertEqual(result.map(\.id), ["a", "b"])
    }
}
