import XCTest
@testable import OuroWorkbenchCore

/// The boss-facing TTFA readout seam (#U20): pure snapshot → readout shaping that the
/// `workbench_autonomy_readiness` MCP sensor returns. Mirrors the operator's popover but
/// for the boss: overall state, per-check fix hints, the boss-vs-operator-vs-degraded
/// distinction, and one human-relayable "get to green" summary with no enum/jargon leaks.
final class AutonomyReadinessReadoutTests: XCTestCase {
    private let renderer = WorkbenchAutonomyReadinessRenderer()

    // MARK: - ready

    func testReadySnapshotProducesNoFixesAndAClearSummary() {
        let snapshot = AutonomyReadinessSnapshot(checks: [
            check("boss", .ok),
            check("terminal-trust", .ok),
            check("boss-watch", .ok)
        ])

        let readout = renderer.readout(snapshot: snapshot, availability: allActionable())

        XCTAssertEqual(readout.state, "ready")
        XCTAssertEqual(readout.blockerCount, 0)
        XCTAssertEqual(readout.warningCount, 0)
        XCTAssertTrue(readout.checks.allSatisfy { $0.fix == nil }, "an all-green readout offers no fixes")
        XCTAssertTrue(readout.summary.contains("Hands-off ready"))
        // No raw enum value leaks into the relayable summary.
        XCTAssertFalse(readout.summary.contains("attention"))
        XCTAssertFalse(readout.summary.contains("blocker"))
    }

    func testStateMapsAttentionToWatchNotTheRawEnum() {
        let snapshot = AutonomyReadinessSnapshot(checks: [
            check("boss", .ok),
            check("boss-watch", .warning)
        ])

        let readout = renderer.readout(snapshot: snapshot, availability: allActionable())

        XCTAssertEqual(readout.state, "watch", "the boss sees 'watch', never the internal 'attention'")
        XCTAssertEqual(readout.warningCount, 1)
    }

    // MARK: - per-check boss-actionable fixes

    func testUntrustedTerminalsOfferTheBossASetTrustVerb() {
        let snapshot = AutonomyReadinessSnapshot(checks: [
            check("terminal-trust", .blocker, detail: "Claude is not trusted.")
        ])

        let readout = renderer.readout(snapshot: snapshot, availability: allActionable())
        let trust = readoutCheck(readout, "terminal-trust")

        XCTAssertEqual(trust?.state, "blocker")
        XCTAssertEqual(trust?.fix?.kind, .bossAction)
        XCTAssertEqual(trust?.fix?.bossAction, "setTrust")
        XCTAssertFalse(trust?.fix?.summary.isEmpty ?? true)
        XCTAssertFalse(trust?.fix?.summary.contains("trustTerminals") ?? false, "no remediation enum name leaks")
    }

    func testEachBossActionableCheckMapsToItsRequestActionVerb() {
        let cases: [(id: String, verb: String, availability: AutonomyRemediationAvailability)] = [
            ("terminal-trust", "setTrust", allActionable()),
            ("terminal-resume", "setAutoResume", allActionable()),
            ("boss-mcp", "registerWorkbenchMCP", allActionable()),
            ("recovery", "recover", allActionable())
        ]
        for c in cases {
            let snapshot = AutonomyReadinessSnapshot(checks: [check(c.id, .blocker)])
            let readout = renderer.readout(snapshot: snapshot, availability: c.availability)
            let fix = readoutCheck(readout, c.id)?.fix
            XCTAssertEqual(fix?.kind, .bossAction, "\(c.id) should be boss-queueable")
            XCTAssertEqual(fix?.bossAction, c.verb, "\(c.id) should map to \(c.verb)")
        }
    }

    // MARK: - operator one-tap (relay, not act)

    func testPausedBossWatchIsAnOperatorOneTapNotABossVerb() {
        let snapshot = AutonomyReadinessSnapshot(checks: [check("boss-watch", .warning)])

        let readout = renderer.readout(snapshot: snapshot, availability: allActionable())
        let watch = readoutCheck(readout, "boss-watch")?.fix

        XCTAssertEqual(watch?.kind, .operatorOneTap, "the boss relays the watch ask, it doesn't flip it")
        XCTAssertNil(watch?.bossAction, "no request_action verb for an operator-only toggle")
        XCTAssertFalse(watch?.summary.isEmpty ?? true)
    }

    func testOpenAtLoginIsAnOperatorOneTapWhenActionable() {
        let snapshot = AutonomyReadinessSnapshot(checks: [check("open-at-login", .warning)])

        let readout = renderer.readout(snapshot: snapshot, availability: allActionable())
        let login = readoutCheck(readout, "open-at-login")?.fix

        XCTAssertEqual(login?.kind, .operatorOneTap)
        XCTAssertNil(login?.bossAction)
    }

    // MARK: - degraded distinction

    func testNonRemediableChecksReadAsDegraded() {
        for id in ["boss", "executables"] {
            let snapshot = AutonomyReadinessSnapshot(checks: [check(id, .blocker)])
            let readout = renderer.readout(snapshot: snapshot, availability: allActionable())
            let fix = readoutCheck(readout, id)?.fix
            XCTAssertEqual(fix?.kind, .degraded, "\(id) has no one-tap fix")
            XCTAssertNil(fix?.bossAction)
            XCTAssertFalse(fix?.summary.isEmpty ?? true)
        }
    }

    func testRuntimeSuppressedBlockerIsDegradedNotAFalseOneTap() {
        // A recovery blocker whose only recovering entries are manual (no live Recover button)
        // must read degraded, never a boss-queueable fix the runtime would suppress.
        let snapshot = AutonomyReadinessSnapshot(checks: [check("recovery", .blocker)])
        var availability = allActionable()
        availability.hasRecoverableEntries = false

        let readout = renderer.readout(snapshot: snapshot, availability: availability)
        let fix = readoutCheck(readout, "recovery")?.fix

        XCTAssertEqual(fix?.kind, .degraded)
        XCTAssertNil(fix?.bossAction)
    }

    func testResumeWithNoResumableTerminalsIsDegraded() {
        let snapshot = AutonomyReadinessSnapshot(checks: [check("terminal-resume", .blocker)])
        var availability = allActionable()
        availability.hasResumableDisabledTerminals = false

        let readout = renderer.readout(snapshot: snapshot, availability: availability)
        XCTAssertEqual(readoutCheck(readout, "terminal-resume")?.fix?.kind, .degraded)
    }

    func testOpenAtLoginWithNoActionableLoginItemIsDegraded() {
        let snapshot = AutonomyReadinessSnapshot(checks: [check("open-at-login", .warning)])
        var availability = allActionable()
        availability.loginItemActionable = false

        let readout = renderer.readout(snapshot: snapshot, availability: availability)
        let fix = readoutCheck(readout, "open-at-login")?.fix
        XCTAssertEqual(fix?.kind, .degraded)
        XCTAssertTrue(fix?.summary.contains("Reinstall Workbench") ?? false)
    }

    func testTrustAndWatchWithoutLiveButtonsReadAsDegradedWithTheirOwnCopy() {
        var availability = allActionable()
        availability.hasUntrustedTerminals = false
        availability.bossWatchDisabled = false

        let trust = renderer.readout(
            snapshot: AutonomyReadinessSnapshot(checks: [check("terminal-trust", .blocker)]),
            availability: availability
        )
        XCTAssertEqual(readoutCheck(trust, "terminal-trust")?.fix?.kind, .degraded)
        XCTAssertEqual(readoutCheck(trust, "terminal-trust")?.fix?.summary, "No agent terminals are open to trust.")

        let watch = renderer.readout(
            snapshot: AutonomyReadinessSnapshot(checks: [check("boss-watch", .warning)]),
            availability: availability
        )
        XCTAssertEqual(readoutCheck(watch, "boss-watch")?.fix?.kind, .degraded)
        XCTAssertTrue(readoutCheck(watch, "boss-watch")?.fix?.summary.contains("Boss Watch can't be turned on") ?? false)
    }

    func testNoTerminalsYetWatchPointsReadAsCalmNotBlockerCopy() {
        // The terminal-trust / terminal-resume checks are .warning only in the "no agent terminals
        // open yet" state — a watch point. The relayable copy must not claim a wall (no resume
        // strategy / can't trust) that only applies to the blocker case.
        var availability = allActionable()
        availability.hasUntrustedTerminals = false
        availability.hasResumableDisabledTerminals = false

        let readout = renderer.readout(
            snapshot: AutonomyReadinessSnapshot(checks: [
                check("terminal-trust", .warning),
                check("terminal-resume", .warning)
            ]),
            availability: availability
        )
        let trust = readoutCheck(readout, "terminal-trust")?.fix
        let resume = readoutCheck(readout, "terminal-resume")?.fix
        XCTAssertEqual(trust?.kind, .degraded)
        XCTAssertEqual(trust?.summary, "Open an agent terminal — there's nothing to trust yet.")
        XCTAssertEqual(resume?.kind, .degraded)
        XCTAssertEqual(resume?.summary, "Open an agent terminal — there's nothing to set a resume strategy on yet.")
    }

    func testManualStrategyResumeBlockerKeepsTheWallCopy() {
        var availability = allActionable()
        availability.hasResumableDisabledTerminals = false

        let readout = renderer.readout(
            snapshot: AutonomyReadinessSnapshot(checks: [check("terminal-resume", .blocker)]),
            availability: availability
        )
        XCTAssertEqual(readoutCheck(readout, "terminal-resume")?.fix?.summary, "These terminals have no automatic resume strategy to turn on.")
    }

    func testUnknownNonGreenCheckIdFallsBackToTheGenericDegradedCopy() {
        let snapshot = AutonomyReadinessSnapshot(checks: [check("future-check", .warning)])

        let readout = renderer.readout(snapshot: snapshot, availability: allActionable())
        let fix = readoutCheck(readout, "future-check")?.fix
        XCTAssertEqual(fix?.kind, .degraded, "an unmapped check has no one-tap fix")
        XCTAssertEqual(fix?.summary, "This needs setup beyond a one-tap fix.")
    }

    func testAppSuppliedDegradedCheckIdForcesDegradedEvenWhenAbstractFixExists() {
        // The App knows a boss-mcp blocker is a missing binary (degraded) even though the
        // abstract mapper offers Connect tools; an explicit degradedCheckId honors that.
        let snapshot = AutonomyReadinessSnapshot(checks: [check("boss-mcp", .blocker)])

        let readout = renderer.readout(
            snapshot: snapshot,
            availability: allActionable(),
            degradedCheckIds: ["boss-mcp"]
        )
        let fix = readoutCheck(readout, "boss-mcp")?.fix

        XCTAssertEqual(fix?.kind, .degraded)
        XCTAssertNil(fix?.bossAction)
    }

    // MARK: - relayable summary

    func testBlockedSummaryNamesEveryNonGreenFixBlockersFirstWithNoJargon() {
        let snapshot = AutonomyReadinessSnapshot(checks: [
            check("boss-watch", .warning),
            check("terminal-trust", .blocker),
            check("boss-mcp", .blocker)
        ])

        let readout = renderer.readout(snapshot: snapshot, availability: allActionable())

        XCTAssertEqual(readout.state, "blocked")
        XCTAssertTrue(readout.summary.hasPrefix("To get to green, the operator needs to:"))
        // Blocker fixes come before the warning fix in the relayable order.
        let trustRange = readout.summary.range(of: "Trust the agent terminals")
        let connectRange = readout.summary.range(of: "Connect the boss")
        let watchRange = readout.summary.range(of: "Boss Watch")
        XCTAssertNotNil(trustRange)
        XCTAssertNotNil(connectRange)
        XCTAssertNotNil(watchRange)
        XCTAssertTrue(trustRange!.lowerBound < watchRange!.lowerBound, "blockers before warnings")
        XCTAssertTrue(connectRange!.lowerBound < watchRange!.lowerBound, "blockers before warnings")
        // No raw enum / remediation-kind / check-id jargon leaks into the relayable line.
        for jargon in ["attention", "warning", "blocker", "terminal-trust", "trustTerminals", "connectTools", "enableWatch"] {
            XCTAssertFalse(readout.summary.contains(jargon), "summary leaked '\(jargon)'")
        }
    }

    func testWatchOnlySummaryStillNamesTheWatchPoint() {
        let snapshot = AutonomyReadinessSnapshot(checks: [
            check("boss", .ok),
            check("boss-watch", .warning)
        ])

        let readout = renderer.readout(snapshot: snapshot, availability: allActionable())

        XCTAssertTrue(readout.summary.hasPrefix("To get to green, the operator needs to:"))
        XCTAssertTrue(readout.summary.contains("Boss Watch"))
    }

    func testReadoutPointsAtTheInAppPopoverSoTheBossCanRelayWhereToFix() {
        let snapshot = AutonomyReadinessSnapshot(checks: [check("terminal-trust", .blocker)])
        let readout = renderer.readout(snapshot: snapshot, availability: allActionable())
        XCTAssertTrue(readout.operatorFixLocation.contains("popover"))
        XCTAssertTrue(readout.operatorFixLocation.contains("header"))
    }

    func testReadoutEncodesStablyAsJSON() throws {
        let snapshot = AutonomyReadinessSnapshot(checks: [check("terminal-trust", .blocker)])
        let readout = renderer.readout(snapshot: snapshot, availability: allActionable())

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = String(data: try encoder.encode(readout), encoding: .utf8)!

        XCTAssertTrue(json.contains("\"state\":\"blocked\""))
        XCTAssertTrue(json.contains("\"bossAction\":\"setTrust\""))
        XCTAssertTrue(json.contains("\"kind\":\"bossAction\""))
    }

    // MARK: - helpers

    private func check(_ id: String, _ state: AutonomyReadinessCheckState, detail: String = "detail") -> AutonomyReadinessCheck {
        AutonomyReadinessCheck(id: id, label: id.capitalized, detail: detail, state: state)
    }

    private func readoutCheck(_ readout: AutonomyReadinessReadout, _ id: String) -> AutonomyReadinessReadoutCheck? {
        readout.checks.first { $0.id == id }
    }

    private func allActionable() -> AutonomyRemediationAvailability {
        AutonomyRemediationAvailability(
            hasUntrustedTerminals: true,
            hasResumableDisabledTerminals: true,
            mcpRegistrationActionable: true,
            hasRecoverableEntries: true,
            bossWatchDisabled: true,
            loginItemActionable: true
        )
    }
}
