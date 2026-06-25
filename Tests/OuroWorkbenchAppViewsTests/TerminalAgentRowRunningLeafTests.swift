#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// SU3r — the standalone `TerminalAgentRow(runningSince:)` LEAF snapshot: the ONE
/// place the elapsed seam is exercised + asserted deterministic (campaign C1).
///
/// **Why a standalone leaf, not the sidebar surface (C1).** Through the real
/// `WorkbenchSidebarView` seam, `TerminalAgentRow` is constructed in exactly one
/// place (the Archived section) WITHOUT `runningSince:`, so `ElapsedTimePill` is
/// never rendered and no elapsed substring can appear in a sidebar reference
/// (asserted by `SidebarSurfaceStateSetTests.testSidebar_isClockFree…`). Snapshotting
/// the elapsed substring on the SURFACE would assert a state the seam can't produce
/// (a P2 §2b violation). So — exactly as U1 snapshotted the `SidebarWorkspaceEmptyRow`
/// / `DashboardRowLabel` leaves — this constructs `TerminalAgentRow` DIRECTLY via its
/// own initializer (a legitimate `View` seam; P2 forbids hand-assembling serializer
/// OUTPUT / model STATE, not instantiating a `View`) with a FIXED `runningSince` + the
/// SU0 injected `now`, so the `ElapsedTimePill` body AND the `:3731` computed
/// `accessibilityLabel` elapsed read render a DETERMINISTIC string ("5m"), with no
/// live-`Date()` drift. SU3r DEPENDS ON SU0 (the injectable-clock seam, on main).
///
/// Negative controls (P2):
///   - changing the injected `now` (5m → 2h) flips the elapsed substring deterministically;
///   - inverting the SU0 seam (`now: nil` → the LIVE clock, against a far-PAST
///     `runningSince`) makes the elapsed substring a large live value (NOT "5m"),
///     proving the seam is load-bearing and SU0 actually closed the leak.
@MainActor
final class TerminalAgentRowRunningLeafTests: XCTestCase {

    /// A minimal fixed `ProcessEntry` (the row's own input — not hand-assembled
    /// serializer output / model state). Distinctive name; `.shell` kind.
    private func runningEntry() -> ProcessEntry {
        ProcessEntry(
            id: UUID(uuidString: "DDDDDDDD-0000-0000-0000-00000000000A")!,
            projectId: UUID(uuidString: "00000000-0000-0000-0000-0000000000FF")!,
            name: "running-agent",
            kind: .shell,
            executable: "/bin/zsh",
            workingDirectory: "/tmp/su3r"
        )
    }

    /// `TerminalAgentRow` built directly with a fixed `runningSince` + injected `now`.
    private func row(runningSince: Date, now: Date?) -> TerminalAgentRow {
        TerminalAgentRow(entry: runningEntry(), isSelected: false, runningSince: runningSince, now: now)
    }

    // A FIXED clock pair: `now` is a fixed epoch; `runningSince` is 5 minutes before it.
    private static let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
    private static var fiveMinutesAgo: Date { fixedNow.addingTimeInterval(-5 * 60) }
    private static var twoHoursAgo: Date { fixedNow.addingTimeInterval(-2 * 60 * 60) }

    // MARK: - The committed deterministic reference (the CLOCK case)

    /// The leaf with a FIXED `now` 5 minutes after `runningSince` → both the
    /// `ElapsedTimePill` body Text and the computed `accessibilityLabel` elapsed read
    /// render the FIXED "5m" string. Recorded once eyeballed for the fixed value + no drift.
    func testTerminalAgentRow_running_fixedNowRendersDeterministicElapsed() throws {
        let view = row(runningSince: Self.fiveMinutesAgo, now: Self.fixedNow)
        // Provenance/no-drift check at the call site before the reference assertion.
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="5m""#), "pill body must read 5m:\n\(tree)")
        XCTAssertTrue(tree.contains("running for 5m"), "a11y label must read 5m:\n\(tree)")
        try assertViewSnapshot(of: view, named: "TerminalAgentRow.running")
    }

    // MARK: - Negative controls (P2)

    /// NEGATIVE CONTROL #1 — a DIFFERENT injected `now` (2h elapsed) produces a
    /// DIFFERENT, deterministic tree. Committed as a second (non-redundant) reference.
    func testTerminalAgentRow_running_differentNowFlipsElapsed() throws {
        let view = row(runningSince: Self.twoHoursAgo, now: Self.fixedNow)
        let tree = try ViewSnapshotHost.snapshotText(of: view)
        XCTAssertTrue(tree.contains(#"text="2h""#), "pill body must read 2h:\n\(tree)")
        XCTAssertTrue(tree.contains("running for 2h"), "a11y label must read 2h:\n\(tree)")

        let fiveMin = try ViewSnapshotHost.snapshotText(of: row(runningSince: Self.fiveMinutesAgo, now: Self.fixedNow))
        XCTAssertNotEqual(tree, fiveMin, "a different injected now must flip the elapsed substring")
        try assertViewSnapshot(of: view, named: "TerminalAgentRow.running.2h")
    }

    /// NEGATIVE CONTROL #2 — INVERT the SU0 seam: with `now: nil` (the production
    /// default = the LIVE clock) against a far-PAST `runningSince`, the elapsed
    /// substring becomes a LARGE live wall-clock value — NOT the fixed "5m". This
    /// proves (a) the seam is load-bearing (the injected `now` actually pins the
    /// value) and (b) SU0 genuinely closed the leak (the default reads the live
    /// clock). Not snapshotted (it is live-clock-dependent by design); asserted on
    /// the substring only.
    func testTerminalAgentRow_seamInversion_liveDefaultDiffersFromInjected() throws {
        // A row started ~2h in the PAST, read with the LIVE default (now: nil).
        let livePast = try ViewSnapshotHost.snapshotText(
            of: row(runningSince: Date().addingTimeInterval(-2 * 60 * 60), now: nil))
        XCTAssertFalse(livePast.contains(#"text="5m""#),
                       "the live default for a 2h-old row must NOT read the injected 5m:\n\(livePast)")
        XCTAssertTrue(livePast.contains(#"text="2h""#),
                      "the live default for a 2h-old row must read ~2h from the live clock:\n\(livePast)")

        // The injected-now leaf for the SAME elapsed is deterministic and differs from
        // a far-future injected now — the seam pins the value either way.
        let injectedNow = Self.fixedNow
        let injected5m = try ViewSnapshotHost.snapshotText(
            of: row(runningSince: injectedNow.addingTimeInterval(-5 * 60), now: injectedNow))
        let injected3h = try ViewSnapshotHost.snapshotText(
            of: row(runningSince: injectedNow.addingTimeInterval(-3 * 60 * 60), now: injectedNow))
        XCTAssertTrue(injected5m.contains(#"text="5m""#), injected5m)
        XCTAssertNotEqual(injected5m, injected3h, "the injected now pins the elapsed value")
    }

    // MARK: - Determinism (P3)

    func testTerminalAgentRow_running_twiceRunByteIdentical_noLeak() throws {
        let make = { try ViewSnapshotHost.snapshotText(of: self.row(runningSince: Self.fiveMinutesAgo, now: Self.fixedNow)) }
        let a = try make()
        let b = try make()
        XCTAssertEqual(a, b, "the injected-now leaf must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }
}
#endif
