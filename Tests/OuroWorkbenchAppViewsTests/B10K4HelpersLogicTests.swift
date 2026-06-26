#if os(macOS)
import XCTest
import SwiftUI
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 Unit 2 — batch B10 (K4 non-View behavioral helpers).
///
/// These are the pure enums / structs / extensions that stayed in `WorkbenchViews.swift` after
/// the Unit-1 split. They render NO captured node through `ViewSnapshotHost.mapNode` (no
/// Text/Image/a11y node), so the snapshot campaign never touched them and they sat as uncovered
/// region-entries on the gated views file. They are NOT snapshot-able — so this drives them with
/// **direct `XCTAssert` logic tests**: construct each, exercise every computed-property / init /
/// switch arm, assert the result. Each arm is mutation-verifiable (mutating the source arm makes
/// the corresponding assertion RED — recorded in `b10-records.md`).
///
/// `SwiftUI.Color`'s standard named colors (`.green`, `.orange`, `.red`, `.secondary`, …) are
/// `Equatable`, so `XCTAssertEqual(helper, .green)` both COVERS the switch arm and ASSERTS its
/// mapping (anneal P2: no executed-but-unasserted region).
final class B10K4HelpersLogicTests: XCTestCase {

    // MARK: - WorkbenchGroupColor.swiftUIColor (10 regions — 8 switch arms + entry + ext)

    /// Every `WorkbenchGroupColor` case maps to its semantic SwiftUI color. Exercises all 8
    /// switch arms (`L10653–10660`) plus the property/extension entry region. `allCases`
    /// guarantees a NEW case can't silently slip past this (it would have no expectation).
    func testWorkbenchGroupColor_swiftUIColor_everyArm() {
        let expected: [WorkbenchGroupColor: SwiftUI.Color] = [
            .gray: .gray,
            .blue: .blue,
            .green: .green,
            .orange: .orange,
            .red: .red,
            .purple: .purple,
            .pink: .pink,
            .teal: .teal,
        ]
        // Every case is in the expectation table (no case un-asserted).
        XCTAssertEqual(Set(WorkbenchGroupColor.allCases), Set(expected.keys),
                       "every WorkbenchGroupColor case must have an asserted swiftUIColor mapping")
        for color in WorkbenchGroupColor.allCases {
            XCTAssertEqual(color.swiftUIColor, expected[color],
                           "WorkbenchGroupColor.\(color.rawValue).swiftUIColor")
        }
    }
}
#endif
