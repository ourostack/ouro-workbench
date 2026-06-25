#if os(macOS)
import SwiftUI
import XCTest

// THE KEYSTONE: `@testable import` against the new library target. This single
// line is the thing that was IMPOSSIBLE before U0 — you cannot `@testable import`
// an `executableTarget`, so the 121 views in `OuroWorkbenchApp.swift` had zero
// structural testability. Proving this import compiles + a view constructs across
// the module boundary is the end-to-end pipeline proof the rest of Phase 0 (the AX
// snapshot harness, snapshots, and the coverage gate) depends on.
@testable import OuroWorkbenchAppViews

@MainActor
final class ImportabilityProofTests: XCTestCase {
    /// Construct the smallest VM-free leaf view through its public init and assert
    /// it carries the values we passed — proving the lib is importable AND that a
    /// view it exports really constructs across the module boundary (not just that
    /// the symbol links).
    func testDashboardRowLabelConstructsAcrossTheModuleBoundary() throws {
        let label = DashboardRowLabel(title: "Workbench MCP", systemImage: "point.3.connected.trianglepath.dotted")

        // Reflect the stored properties: a real assertion the constructed value
        // holds the inputs (not a tautology like `XCTAssertNotNil(label)` which the
        // optimizer could elide). Mirror reads the view's declared children without
        // needing to render it.
        let children = Dictionary(
            uniqueKeysWithValues: Mirror(reflecting: label).children.compactMap { child -> (String, Any)? in
                guard let label = child.label else { return nil }
                return (label, child.value)
            }
        )
        XCTAssertEqual(children["title"] as? String, "Workbench MCP")
        XCTAssertEqual(children["systemImage"] as? String, "point.3.connected.trianglepath.dotted")

        // The view has a non-trivial `body` — accessing it exercises the SwiftUI
        // import path inside the lib (the lib is the first AppKit/SwiftUI-importing
        // library target in this package). Erasing to AnyView proves `body` is a
        // real `some View` that resolves through the module boundary.
        let erased = AnyView(label.body)
        _ = erased
    }
}
#endif
