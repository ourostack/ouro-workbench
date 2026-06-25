#if os(macOS)
import XCTest

/// U0 Unit 2 — the `appSource()` retarget "no-op proof".
///
/// Proves the shared `WorkbenchAppSource.appSource()` reader correctly returns the UNION of the
/// thinning exe file AND the extracted views library, in a deterministic adjacency-preserving
/// order — BEFORE any guarded declaration has moved into the lib. At this point only the unguarded
/// `DashboardRowLabel` leaf lives in the lib, so the union must (a) still contain every marker the
/// 257 guards look for (they all live in the exe file) and (b) ALSO contain the moved leaf's
/// marker (proving the lib side is actually concatenated, not silently dropped). The full guard
/// suite passing alongside this is the regression oracle that the retarget did not break anything.
final class WorkbenchAppSourceRetargetTests: XCTestCase {
    func testUnionContainsBothExeAndLibSides() throws {
        let source = try WorkbenchAppSource.appSource()

        // Exe side: a marker that has NOT moved (the view-model still lives in the exe file).
        XCTAssertTrue(
            source.contains("final class WorkbenchViewModel"),
            "union must include the exe file (WorkbenchViewModel still lives there)"
        )

        // Lib side: the one leaf view moved in Unit 1 — its public declaration only exists in the
        // lib now, so finding it proves the lib files are concatenated into the union.
        XCTAssertTrue(
            source.contains("public struct DashboardRowLabel: View"),
            "union must include the lib files (DashboardRowLabel moved to OuroWorkbenchAppViews)"
        )
    }

    func testEveryLibFileIsExplicitlyOrdered() {
        // A newly-added lib file must be placed in declaration order in
        // WorkbenchAppSource.orderedLibFiles — not left to the deterministic-sort fallback —
        // so cross-declaration slices stay adjacency-correct.
        WorkbenchAppSource.assertEveryLibFileIsOrdered()
    }

    func testSelfReadingSliceRoutesThroughTheSharedReader() throws {
        // The self-reading sourceSlice(from:to:) overload must read the same union. Slice a
        // region wholly inside the exe file to confirm it resolves through the shared reader.
        let slice = try WorkbenchAppSource.sourceSlice(
            from: "final class WorkbenchViewModel",
            to: "\n    func "
        )
        XCTAssertFalse(slice.isEmpty, "self-reading slice must resolve through the shared union reader")
    }
}
#endif
