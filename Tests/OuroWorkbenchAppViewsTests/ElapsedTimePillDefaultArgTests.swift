#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// U5 B1 — `ElapsedTimePill` (`:3886`) `now` default-argument drive-to-100%.
///
/// Every existing call site (`SU0InjectableClockTests`, `TerminalAgentRowRunningLeafTests`, and the
/// production `TerminalAgentRow` body) constructs the pill WITH an explicit `now:`, so the
/// `var now: Date? = nil` default-value region (`L3893:22`) — the storage region executed only when a
/// caller OMITS `now` — was uncovered. This suite constructs the pill via the default-arg path and
/// asserts the default took effect (`now == nil`), then MUTATION-VERIFIES the default.
///
/// **Provenance (P2).** The pill is a pure value view; constructing it with `ElapsedTimePill(startDate:)`
/// — omitting `now` — IS the default-arg seam. We assert the resulting `now` property is nil (the
/// default's effect) AND that the pill still renders (the live `TimelineView` clock path), proving the
/// default-arg construction yields a working view.
///
/// **Determinism (P3).** The default (`now == nil`) path uses the live `TimelineView` clock, so we do
/// NOT pin a snapshot of its rendered elapsed string (that lives in the SU3r deterministic leaf with an
/// injected `now`); here we assert the structural default + that no machine path leaks.
@MainActor
final class ElapsedTimePillDefaultArgTests: XCTestCase {

    private static let start = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - The default-arg path (omit `now`)

    func testDefaultArg_nowIsNil() throws {
        // Construct WITHOUT `now:` — exercising the `var now: Date? = nil` default-value region.
        let pill = ElapsedTimePill(startDate: Self.start)
        XCTAssertNil(pill.now, "omitting `now` takes the default-arg path (now == nil)")
    }

    func testDefaultArg_pillStillRenders() throws {
        // The default (live-clock) pill still produces a rendered tree (a coarse elapsed Text). The
        // exact value is the live clock, so we assert only that it renders a node + leaks no path.
        let pill = ElapsedTimePill(startDate: Self.start)
        let tree = try ViewSnapshotHost.snapshotText(of: pill)
        XCTAssertFalse(tree.isEmpty, "the default-arg pill renders a node:\n\(tree)")
        XCTAssertFalse(tree.contains("/Users/"), "no machine-path leak:\n\(tree)")
    }

    // MARK: - Negative control (P2 — mutation-verified)

    /// The default value is load-bearing: omitting `now` yields nil (the live-clock path); passing an
    /// explicit `now` yields that value. (Mutation-verify: changing the default `= nil` to `= Date()`
    /// makes the omit-path non-nil → `testDefaultArg_nowIsNil` RED.)
    func testNegativeControl_explicitNowOverridesDefault() throws {
        let defaulted = ElapsedTimePill(startDate: Self.start)
        let explicit = ElapsedTimePill(startDate: Self.start, now: Self.start.addingTimeInterval(300))
        XCTAssertNil(defaulted.now, "the default-arg path is nil")
        XCTAssertEqual(explicit.now, Self.start.addingTimeInterval(300), "an explicit now is carried")
        XCTAssertNotEqual(defaulted.now, explicit.now, "the default and an explicit value differ")
    }
}
#endif
