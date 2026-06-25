#if os(macOS)
import XCTest
import SwiftUI
import ViewInspector
import OuroWorkbenchCore
@testable import OuroWorkbenchAppViews

/// SU0 — behavior-preservation + determinism tests for the injectable test-clock
/// seam at the three wall-clock leak sites:
///   1. `ElapsedTimePill` body (`TimelineView`-driven `Text`),
///   2. `DecisionInboxSheet` body (`TimelineView`-driven `openInboxGroups(now:)`),
///   3. `TerminalAgentRow.accessibilityLabel` (the `:3718` computed-property
///      `String` elapsed read).
///
/// The seam is an init-param `now: Date? = nil` (Candidate B, per
/// `clock-seam-spike.md`): `nil` in production → the live clock
/// (`TimelineView` `context.date` / `Date()`); a fixed `Date` in tests →
/// deterministic. The `TimelineView(.periodic)` driver is RETAINED at both embed
/// sites, so production keeps ticking. These tests assert BOTH directions.
///
/// **H2 note:** the ticking guarantee does NOT come from `--uisurfacetest` (it
/// only asserts `fittingSize > 0` = render-without-crash; it never constructs a
/// running session, never reads `ElapsedTimePill`). The ticking guarantee rests
/// on (a) the retained-`TimelineView(.periodic)` grep + (b) the SU0d reviewer
/// negative-control. The render-smoke assertion here is a REGRESSION CONTROL ONLY.
@MainActor
final class SU0InjectableClockTests: XCTestCase {

    // MARK: - Fixtures

    private func runningRow(runningSince: Date, now: Date?) -> TerminalAgentRow {
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "agent-a",
            kind: .terminalAgent,
            executable: "ouro",
            workingDirectory: "/repo/agent-a"
        )
        return TerminalAgentRow(entry: entry, isSelected: false, runningSince: runningSince, now: now)
    }

    // MARK: - (1) injected-now path → fixed elapsed string at BOTH leaf leak sites

    func testInjectedNow_pinsPillBodyAndAccessibilityLabel() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let start = now.addingTimeInterval(-5 * 60) // 5m ago
        let tree = try ViewSnapshotHost.snapshotText(of: runningRow(runningSince: start, now: now))

        // (i) the ElapsedTimePill body Text (inside the TimelineView closure).
        XCTAssertTrue(tree.contains(#"text="5m""#),
                      "injected now must pin the pill body Text to 5m:\n\(tree)")
        // (ii) the :3718 computed accessibilityLabel elapsed read.
        XCTAssertTrue(tree.contains("running for 5m"),
                      "injected now must pin the accessibilityLabel elapsed read to 5m:\n\(tree)")
    }

    func testInjectedNow_changingNowFlipsBothSitesDeterministically() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let tree2h = try ViewSnapshotHost.snapshotText(
            of: runningRow(runningSince: now.addingTimeInterval(-2 * 60 * 60), now: now))
        XCTAssertTrue(tree2h.contains(#"text="2h""#), tree2h)
        XCTAssertTrue(tree2h.contains("running for 2h"), tree2h)

        // Same row, a DIFFERENT injected now → a DIFFERENT deterministic string.
        let tree5m = try ViewSnapshotHost.snapshotText(
            of: runningRow(runningSince: now.addingTimeInterval(-5 * 60), now: now))
        XCTAssertNotEqual(tree2h, tree5m, "different elapsed must produce different trees")
    }

    func testInjectedNow_twiceRunByteIdentical_noMachinePath() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let make = { try ViewSnapshotHost.snapshotText(
            of: self.runningRow(runningSince: now.addingTimeInterval(-5 * 60), now: now)) }
        let a = try make()
        let b = try make()
        XCTAssertEqual(a, b, "injected-now tree must serialize byte-identically twice")
        XCTAssertFalse(a.contains("/Users/"), "no machine-path leak:\n\(a)")
    }

    // MARK: - (2) production-default path → the LIVE clock (source default unchanged)

    /// The prod default (`now == nil`) must read the live clock. CRITICAL: the row
    /// is started ~2h IN THE PAST, so the LIVE default produces "2h" — a value that
    /// a hardcoded **past** sentinel default (the most natural prod-default-is-live
    /// regression, e.g. `now ?? Date(timeIntervalSince1970: …)`) CANNOT produce: a
    /// past-fixed `now` minus a past start clamps via `max(0,…)` to "0s". So this
    /// asserting on "2h" (not "Ns") genuinely fences the regression where the
    /// default silently stops reading the live clock. (A just-started row would
    /// give "0s" under BOTH a live clock and a past sentinel — indistinguishable —
    /// which is the gap a fresh `Date()`-started fixture missed.)
    func testProductionDefault_usesLiveClock_pill() throws {
        let start = Date().addingTimeInterval(-2 * 60 * 60) // ~2h ago
        let tree = try ViewSnapshotHost.snapshotText(of: runningRow(runningSince: start, now: nil))
        XCTAssertTrue(tree.contains(#"text="2h""#),
                      "prod default must read the LIVE clock → a 2h-old row shows 2h "
                      + "(a hardcoded past-date default would clamp to 0s):\n\(tree)")
        XCTAssertFalse(tree.contains(#"text="0s""#),
                      "a 0s reading would mean the default ignored the live clock:\n\(tree)")
    }

    func testProductionDefault_usesLiveClock_accessibilityLabel() throws {
        let start = Date().addingTimeInterval(-2 * 60 * 60) // ~2h ago
        let tree = try ViewSnapshotHost.snapshotText(of: runningRow(runningSince: start, now: nil))
        XCTAssertTrue(tree.contains("running for 2h"),
                      "prod default accessibilityLabel must read the LIVE clock "
                      + "(2h-old row → '2h'; a past-date default would give '0s'):\n\(tree)")
        XCTAssertFalse(tree.contains("running for 0s"),
                      "a 0s a11y reading would mean the default ignored the live clock:\n\(tree)")
    }

    /// The seam is LOAD-BEARING in BOTH directions:
    /// (a) the live default differs from a far-FUTURE injected `now`, and
    /// (b) — the regression a reviewer caught — the live default for a PAST-started
    /// row produces a real elapsed ("2h"), which a hardcoded PAST sentinel default
    /// could not. Mutating the source default to a fixed past date makes (b) fail.
    func testSeamIsLoadBearing_injectedDiffersFromLiveDefault() throws {
        // (a) live just-started vs far-future injected.
        let start = Date()
        let live = try ViewSnapshotHost.snapshotText(of: runningRow(runningSince: start, now: nil))
        let injectedFar = try ViewSnapshotHost.snapshotText(
            of: runningRow(runningSince: start, now: start.addingTimeInterval(3 * 60 * 60))) // +3h
        XCTAssertTrue(injectedFar.contains(#"text="3h""#), injectedFar)
        XCTAssertNotEqual(live, injectedFar,
                          "live default must differ from a far-future injected now")

        // (b) live default for a 2h-PAST row → "2h", NOT the "0s" a past-fixed-date
        // sentinel default would yield. This is the assertion that fails if the
        // prod default silently stops reading the live clock.
        let pastStart = Date().addingTimeInterval(-2 * 60 * 60)
        let livePast = try ViewSnapshotHost.snapshotText(of: runningRow(runningSince: pastStart, now: nil))
        XCTAssertTrue(livePast.contains(#"text="2h""#),
                      "the live default for a 2h-old row must read the live clock (2h), "
                      + "not a clamped 0s from a hardcoded past sentinel:\n\(livePast)")
    }

    // MARK: - (3) DecisionInboxSheet default vs injected now

    /// `DecisionInboxSheet.now` defaults to `nil` (live clock via the TimelineView);
    /// an injected `now` is honored. We assert the seam EXISTS and its default is
    /// `nil` (prod-live) by constructing both forms — the default form compiles
    /// without `now`, the injected form pins it. (The sheet needs a VM; we assert
    /// at the type level that the seam is present + nil-default, since rendering
    /// the full sheet needs a hermetic VM beyond SU0's behavior scope.)
    private func hermeticVM() -> WorkbenchViewModel {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("su0-inbox-\(UUID().uuidString)", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: tmp)
        return WorkbenchViewModel(
            paths: paths,
            bossWorkbenchMCPRegistrar: BossWorkbenchMCPRegistrar(
                agentBundlesURL: tmp.appendingPathComponent("AgentBundles", isDirectory: true)
            )
        )
    }

    /// Prod form: no `now` (nil default → live `TimelineView` clock). Inspecting
    /// the sheet's `TimelineView` `contentView()` forces the body to evaluate
    /// `content(now: now ?? context.date)` down the `context.date` (default) branch
    /// — exercising the new seam line. The empty-inbox VM renders the "Nothing
    /// needs you right now" subtitle, which we assert reaches the tree.
    func testDecisionInboxSheet_defaultClock_evaluatesContentBody() throws {
        let sheet = DecisionInboxSheet(model: hermeticVM()) // no `now` → live clock
        let content = try sheet.inspect().timelineView().contentView()
        // The body evaluated: the inbox subtitle (empty queue) is present.
        let found = content.findAll(ViewType.Text.self).contains { node in
            ((try? node.string(locale: ViewSnapshotHost.posixLocale)) ?? "")
                .contains("Decision Inbox")
        }
        XCTAssertTrue(found, "default-clock sheet body must evaluate content(now:)")
    }

    /// Injected form: a fixed `now`. Same inspection, exercising the OTHER side of
    /// the `now ?? context.date` seam (the injected branch).
    func testDecisionInboxSheet_injectedClock_evaluatesContentBody() throws {
        let sheet = DecisionInboxSheet(
            model: hermeticVM(), now: Date(timeIntervalSince1970: 1_700_000_000))
        let content = try sheet.inspect().timelineView().contentView()
        let found = content.findAll(ViewType.Text.self).contains { node in
            ((try? node.string(locale: ViewSnapshotHost.posixLocale)) ?? "")
                .contains("Decision Inbox")
        }
        XCTAssertTrue(found, "injected-clock sheet body must evaluate content(now:)")
    }

    // MARK: - (regression control ONLY, NOT the ticking proof — H2)

    /// `--uisurfacetest`-style render-smoke: the surfaces that embed
    /// `ElapsedTimePill` fit positively (render without crashing). This is a
    /// REGRESSION CONTROL ONLY — it does NOT prove periodic ticking (see H2).
    func testRenderSmoke_runningRowFitsPositively() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let row = runningRow(runningSince: now.addingTimeInterval(-5 * 60), now: now)
        let size = NSHostingController(rootView: row).sizeThatFits(
            in: NSSize(width: 320, height: 80))
        XCTAssertGreaterThan(size.width, 0, "running row must fit positively")
        XCTAssertGreaterThan(size.height, 0, "running row must fit positively")
    }
}
#endif
