import XCTest
@testable import OuroWorkbenchCore

/// Durable wiring assertions for the count + boss-menu false-green sweep (Unit 3).
///
/// Two more surfaces derived readiness from raw config `agent.status`:
///   * `ouroAgentStatusLine` — the "N local, M ready" tally counted
///     `agent.status == .ready`, so an expired-token agent inflated the "ready"
///     count even though no live check confirmed it. It must count
///     `liveReadiness(...) == .ready` (working-verdict only), matching the harness
///     `readyCount` semantics #262 established.
///   * `BossSelectorView.menuLabel` — appended only CONFIG suffixes; a
///     confirmed-bad live verdict (auth-expired / unreachable) showed a bare name.
///     It must append an honest "— sign-in needed" / "— offline" for a confirmed-bad
///     `liveReadiness`, while keeping pending/ready a bare name (calm — the Connect
///     step still verifies on actual selection).
///
/// The App target isn't coverage-gated, so we pin the wiring in source (the same
/// approach as `AgentReadinessOverlayWiringTests`).
final class AgentStatusLineAndMenuReadinessWiringTests: XCTestCase {

    // MARK: - ouroAgentStatusLine counts LIVE readiness, not config status

    func testStatusLineNoLongerCountsConfigReady() throws {
        let body = try ouroAgentStatusLineDecl()
        XCTAssertFalse(
            body.contains("$0.status == .ready"),
            "the ready count must NOT filter on the config-only agent.status == .ready (that double-counted expired-token agents)"
        )
    }

    func testStatusLineCountsLiveReadiness() throws {
        let body = try ouroAgentStatusLineDecl()
        XCTAssertTrue(
            body.contains("InstalledAgentRowPresentation.liveReadiness"),
            "the ready count must resolve a live readiness via the Core seam"
        )
        XCTAssertTrue(
            body.contains("== .ready"),
            "the count must tally liveReadiness == .ready (the only state a working live verdict produces)"
        )
        XCTAssertTrue(
            body.contains("agentOutwardVerdicts"),
            "the count must fold in the live per-agent outward verdict map"
        )
        XCTAssertTrue(
            body.contains("agentChecksInFlight"),
            "the count must fold in the in-flight set (a mid-check agent isn't 'ready' yet)"
        )
    }

    // MARK: - BossSelectorView.menuLabel: honest suffix for a confirmed-bad verdict

    func testMenuLabelConsultsLiveReadiness() throws {
        let body = try menuLabelDecl()
        XCTAssertTrue(
            body.contains("InstalledAgentRowPresentation.liveReadiness"),
            "menuLabel must consult the live readiness to honestly flag a confirmed-bad agent"
        )
        XCTAssertTrue(
            body.contains("model.agentOutwardVerdicts[agentName]"),
            "menuLabel must fold in the live per-agent outward verdict"
        )
    }

    func testMenuLabelAppendsHonestSignInNeededAndOffline() throws {
        let body = try menuLabelDecl()
        XCTAssertTrue(
            body.contains("sign-in needed"),
            "a confirmed auth-expired verdict must append '— sign-in needed'"
        )
        XCTAssertTrue(
            body.contains("offline"),
            "a confirmed unreachable verdict must append '— offline'"
        )
    }

    func testMenuLabelKeepsConfigSuffixes() throws {
        // The config suffixes must survive — they were already honest.
        let body = try menuLabelDecl()
        XCTAssertTrue(body.contains("— disabled"), "config-disabled suffix must remain")
        XCTAssertTrue(body.contains("— no agent.json"), "config-missing suffix must remain")
        XCTAssertTrue(body.contains("— invalid config"), "config-invalid suffix must remain")
        XCTAssertTrue(body.contains("— missing"), "the unresolved-name (missing) suffix must remain")
    }

    func testMenuLabelLeavesPendingAndReadyBare() throws {
        // CALM: a pending/unverified/ready agent must NOT pick up an alarm suffix —
        // the Connect step still verifies on actual selection. Only confirmed-bad warns.
        // Pin this by asserting NO emitted "— <pending>" suffix string exists; the only
        // readiness-derived suffixes are the two confirmed-bad ones (sign-in / offline).
        // (We match the emitted "— …" suffix form, not the bare word, so the `.checking` /
        //  `.unverified` enum case labels in the calm bare-name arm don't trip the assertion.)
        let body = try menuLabelDecl()
        XCTAssertFalse(
            body.contains("— not verified"),
            "an unverified agent must stay a calm bare name in the menu (no alarm suffix)"
        )
        XCTAssertFalse(
            body.contains("— checking"),
            "a mid-check agent must stay a calm bare name in the menu (no alarm suffix)"
        )
        XCTAssertFalse(
            body.contains("— credentials locked"),
            "a vault-locked agent must stay a calm bare name in the menu (the task scopes the suffix to auth-expired/unreachable; vault is a local unlock)"
        )
    }

    // MARK: - Helpers (mirror AgentReadinessOverlayWiringTests)

    private func ouroAgentStatusLineDecl() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "var ouroAgentStatusLine: String {",
            to: "\n    var bossAgentChoices: [String] {"
        )
    }

    private func menuLabelDecl() throws -> String {
        let source = try WorkbenchAppSource.appSource()
        return try WorkbenchAppSource.sourceSlice(
            in: source,
            from: "private func menuLabel(for agentName: String) -> String {",
            to: "\nstruct BossAgentNamePopover: View {"
        )
    }
}
