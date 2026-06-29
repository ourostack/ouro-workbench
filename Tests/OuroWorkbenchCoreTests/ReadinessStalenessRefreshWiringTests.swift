import XCTest
@testable import OuroWorkbenchCore

/// Unit 2 — durable wiring assertions for the readiness staleness re-check.
///
/// PRs #261/#262/#264 made the readiness overlay honest, refreshed on launch +
/// the navigation/action triggers that call `refreshOuroAgents()`. The gap this
/// closes: an app left FOCUSED + IDLE never re-checks, so a token that expires
/// mid-session leaves a STALE "ready" pill. This change adds two new triggers —
/// an app-became-active re-check (60s debounce) and a periodic backstop (300s) —
/// both routed through `AgentReadinessRefreshPolicy.shouldRefresh` so they never
/// hammer the daemon or double-fire.
///
/// The App target isn't coverage-gated and can't be click-tested in CI, so — like
/// the #261/#262 sibling wiring tests — we PIN the structural wiring in source:
///  1. `WorkbenchRootView` re-checks on `scenePhase == .active` via the IfStale guard.
///  2. `WorkbenchRootView` has a periodic `Task.sleep` loop re-checking via the IfStale guard.
///  3. `refreshOutwardReadinessIfStale` consults `AgentReadinessRefreshPolicy.shouldRefresh`.
///  4. `refreshAgentOutwardReadiness` records `lastOutwardReadinessCheckAt` at its START.
final class ReadinessStalenessRefreshWiringTests: XCTestCase {

    // MARK: - Surface 1: WorkbenchRootView scene-phase + periodic wiring

    func testRootViewObservesScenePhase() throws {
        let body = try rootViewDecl()
        XCTAssertTrue(
            body.contains("@Environment(\\.scenePhase)"),
            "WorkbenchRootView must observe the scene phase to re-check when the app regains focus"
        )
    }

    func testRootViewRechecksOnBecomingActive() throws {
        let body = try rootViewDecl()
        XCTAssertTrue(
            body.contains(".onChange(of: scenePhase)"),
            "WorkbenchRootView must react to scene-phase changes"
        )
        XCTAssertTrue(
            body.contains("newPhase == .active"),
            "the re-check must gate on the app becoming .active (regaining focus)"
        )
        // The on-active path must route through the debounced IfStale guard at 60s.
        XCTAssertTrue(
            body.contains("refreshOutwardReadinessIfStale(staleAfter: 60)"),
            "becoming active must re-check via the 60s-debounced IfStale guard (no spam on rapid app-switching)"
        )
    }

    func testRootViewHasPeriodicBackstopLoop() throws {
        let body = try rootViewDecl()
        // A periodic backstop loop that sleeps and re-checks while the view is alive.
        XCTAssertTrue(
            body.contains("while !Task.isCancelled"),
            "WorkbenchRootView must run a periodic loop (cancelled when the view disappears)"
        )
        XCTAssertTrue(
            body.contains("Task.sleep(nanoseconds: 300_000_000_000)"),
            "the periodic backstop must sleep 300s (5 min) between re-checks"
        )
        XCTAssertTrue(
            body.contains("refreshOutwardReadinessIfStale(staleAfter: 300)"),
            "the periodic backstop must re-check via the 300s-debounced IfStale guard"
        )
    }

    // MARK: - Surface 2: the debounce method consults the pure Core policy

    func testIfStaleMethodConsultsTheCorePolicy() throws {
        let decl = try refreshIfStaleDecl()
        XCTAssertTrue(
            decl.contains("AgentReadinessRefreshPolicy.shouldRefresh"),
            "refreshOutwardReadinessIfStale must delegate the debounce decision to the pure Core policy"
        )
        XCTAssertTrue(
            decl.contains("lastCheckedAt: lastOutwardReadinessCheckAt"),
            "the policy must be fed the recorded last-checked timestamp"
        )
        XCTAssertTrue(
            decl.contains("refreshAgentOutwardReadiness()"),
            "when stale, the method must trigger the real outward-readiness refresh"
        )
    }

    // MARK: - Surface 3: the refresh records its freshness timestamp up front

    func testRefreshRecordsTimestampAtStart() throws {
        let decl = try refreshReadinessDecl()
        // The timestamp must be set BEFORE the guard/TaskGroup so an empty-target
        // early return still records freshness AND a concurrent trigger sees the
        // in-flight refresh (debounce). Assert it precedes the `guard`.
        let stampRange = try XCTUnwrap(
            decl.range(of: "lastOutwardReadinessCheckAt = "),
            "refreshAgentOutwardReadiness must record lastOutwardReadinessCheckAt"
        )
        let guardRange = try XCTUnwrap(
            decl.range(of: "let targets = ouroAgents.filter"),
            "refreshAgentOutwardReadiness must still snapshot its targets"
        )
        XCTAssertTrue(
            stampRange.lowerBound < guardRange.lowerBound,
            "lastOutwardReadinessCheckAt must be set at the START (before the target snapshot/guard)"
        )
    }

    // MARK: - Helpers (mirror AgentDetailReadinessWiringTests)

    private func rootViewDecl() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "struct WorkbenchRootView: View {",
            to: "\nfinal class WorkbenchMenuBarController"
        )
    }

    private func refreshIfStaleDecl() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func refreshOutwardReadinessIfStale(",
            to: "\n    func refreshAgentOutwardReadiness()"
        )
    }

    private func refreshReadinessDecl() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "func refreshAgentOutwardReadiness() {",
            // VM-GATE: `private`-agnostic — runColdStartProviderCheck was widened private->internal.
            to: "\n    func runColdStartProviderCheck("
        )
    }
}
