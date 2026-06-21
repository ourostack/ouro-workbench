import XCTest
@testable import OuroWorkbenchCore

final class AutonomyReadinessRemediationTests: XCTestCase {

    // MARK: - remediation(forCheckId:state:)

    func testOkStateNeverOffersARemediation() {
        for id in ["terminal-trust", "terminal-resume", "boss-mcp", "recovery", "boss-watch", "open-at-login", "boss", "executables"] {
            XCTAssertNil(
                AutonomyRemediationMapper.remediation(forCheckId: id, state: .ok),
                "An .ok \(id) check must offer no repair button"
            )
        }
    }

    func testTerminalTrustMapsToTrustTerminals() {
        let remediation = AutonomyRemediationMapper.remediation(forCheckId: "terminal-trust", state: .blocker)
        XCTAssertEqual(remediation, AutonomyRemediation(actionLabel: "Trust", kind: .trustTerminals))
    }

    func testTerminalResumeMapsToEnableResume() {
        let remediation = AutonomyRemediationMapper.remediation(forCheckId: "terminal-resume", state: .blocker)
        XCTAssertEqual(remediation, AutonomyRemediation(actionLabel: "Enable resume", kind: .enableResume))
    }

    func testBossMcpMapsToConnectTools() {
        let remediation = AutonomyRemediationMapper.remediation(forCheckId: "boss-mcp", state: .blocker)
        XCTAssertEqual(remediation, AutonomyRemediation(actionLabel: "Connect tools", kind: .connectTools))
    }

    func testBossMcpWarningAlsoMapsToConnectTools() {
        // An unchecked bridge is .warning; it still offers the connect action.
        let remediation = AutonomyRemediationMapper.remediation(forCheckId: "boss-mcp", state: .warning)
        XCTAssertEqual(remediation, AutonomyRemediation(actionLabel: "Connect tools", kind: .connectTools))
    }

    func testRecoveryMapsToRecover() {
        let remediation = AutonomyRemediationMapper.remediation(forCheckId: "recovery", state: .blocker)
        XCTAssertEqual(remediation, AutonomyRemediation(actionLabel: "Recover", kind: .recover))
    }

    func testBossWatchMapsToEnableWatch() {
        let remediation = AutonomyRemediationMapper.remediation(forCheckId: "boss-watch", state: .warning)
        XCTAssertEqual(remediation, AutonomyRemediation(actionLabel: "Watch", kind: .enableWatch))
    }

    func testOpenAtLoginMapsToOpenAtLogin() {
        let remediation = AutonomyRemediationMapper.remediation(forCheckId: "open-at-login", state: .warning)
        XCTAssertEqual(remediation, AutonomyRemediation(actionLabel: "Login", kind: .openAtLogin))
    }

    func testBossCheckHasNoOneTapFix() {
        // A bad/missing boss bundle name needs a different boss pick, not a toggle.
        XCTAssertNil(AutonomyRemediationMapper.remediation(forCheckId: "boss", state: .blocker))
    }

    func testExecutablesCheckHasNoOneTapFix() {
        // A missing executable is genuinely degraded — no orphaned button.
        XCTAssertNil(AutonomyRemediationMapper.remediation(forCheckId: "executables", state: .blocker))
        XCTAssertNil(AutonomyRemediationMapper.remediation(forCheckId: "executables", state: .warning))
    }

    func testUnknownCheckIdHasNoRemediation() {
        XCTAssertNil(AutonomyRemediationMapper.remediation(forCheckId: "totally-new-check", state: .blocker))
    }

    func testNonRemediableCheckIdsContainsBossAndExecutables() {
        XCTAssertTrue(AutonomyRemediationMapper.nonRemediableCheckIds.contains("boss"))
        XCTAssertTrue(AutonomyRemediationMapper.nonRemediableCheckIds.contains("executables"))
    }

    // MARK: - reason(for:degradedCheckIds:)

    func testAllGreenReadsAsOneTapSetup() {
        // No blockers → trivially one-tap (the caller only consults this when non-green).
        let checks = [check("terminal-trust", .ok), check("boss-watch", .ok)]
        XCTAssertEqual(AutonomyRemediationMapper.reason(for: checks), .oneTapSetup)
    }

    func testToggleOnlyBlockersReadAsOneTapSetup() {
        let checks = [
            check("terminal-trust", .blocker),
            check("terminal-resume", .blocker),
            check("recovery", .blocker)
        ]
        XCTAssertEqual(AutonomyRemediationMapper.reason(for: checks), .oneTapSetup)
    }

    func testPausedWatchWarningDoesNotForceDegraded() {
        // A paused Boss Watch is .warning, not a blocker — keep it OUT of the degraded reframe.
        let checks = [
            check("terminal-trust", .blocker),
            check("boss-watch", .warning)
        ]
        XCTAssertEqual(AutonomyRemediationMapper.reason(for: checks), .oneTapSetup)
    }

    func testMissingExecutableBlockerReadsAsDegraded() {
        let checks = [
            check("terminal-trust", .blocker),
            check("executables", .blocker)
        ]
        XCTAssertEqual(AutonomyRemediationMapper.reason(for: checks), .degraded)
    }

    func testBadBossBundleBlockerReadsAsDegraded() {
        let checks = [check("boss", .blocker)]
        XCTAssertEqual(AutonomyRemediationMapper.reason(for: checks), .degraded)
    }

    func testAppSuppliedDegradedCheckIdForcesDegraded() {
        // boss-mcp executableMissing is .blocker but degraded — the App tells us via degradedCheckIds.
        let checks = [check("boss-mcp", .blocker)]
        XCTAssertEqual(AutonomyRemediationMapper.reason(for: checks), .oneTapSetup)
        XCTAssertEqual(
            AutonomyRemediationMapper.reason(for: checks, degradedCheckIds: ["boss-mcp"]),
            .degraded
        )
    }

    func testUnknownBlockerIdReadsAsDegraded() {
        // A blocker we have no mapping for must NOT read as calmly fixable.
        let checks = [check("mystery-blocker", .blocker)]
        XCTAssertEqual(AutonomyRemediationMapper.reason(for: checks), .degraded)
    }

    // MARK: - reframe(state:checks:degradedCheckIds:)

    func testBlockedButOneTapReframesCalmlyWithCount() {
        let checks = [
            check("terminal-trust", .blocker),
            check("recovery", .blocker),
            check("boss-watch", .warning)
        ]
        let reframe = AutonomyReadinessReframe.present(state: .blocked, checks: checks)

        XCTAssertEqual(reframe.tone, .calm)
        // Two blockers → "2 things"; never the "blocked" / "cannot recover" / octagon language.
        XCTAssertTrue(reframe.headline.contains("2"), "headline should name the blocker count: \(reframe.headline)")
        XCTAssertFalse(reframe.headline.lowercased().contains("blocked"))
        XCTAssertFalse(reframe.detail.lowercased().contains("cannot"))
        XCTAssertEqual(reframe.pillText, "needs you")
    }

    func testSingleOneTapBlockerReadsAsOneThing() {
        let checks = [check("terminal-trust", .blocker)]
        let reframe = AutonomyReadinessReframe.present(state: .blocked, checks: checks)

        XCTAssertEqual(reframe.tone, .calm)
        XCTAssertTrue(reframe.headline.contains("1"), "headline should say 1 thing: \(reframe.headline)")
        XCTAssertFalse(reframe.headline.contains("1 things"), "should read '1 thing', not '1 things'")
    }

    func testGenuinelyDegradedKeepsTheLoudCopy() {
        let checks = [check("executables", .blocker)]
        let reframe = AutonomyReadinessReframe.present(state: .blocked, checks: checks)

        XCTAssertEqual(reframe.tone, .degraded)
        // Reserve the wall language for the degraded case — keep the Core blocked headline/detail.
        XCTAssertEqual(reframe.headline, AutonomyReadinessSnapshot(checks: checks).headline)
        XCTAssertEqual(reframe.detail, AutonomyReadinessSnapshot(checks: checks).detail)
        XCTAssertEqual(reframe.pillText, "blocked")
    }

    func testAppSuppliedDegradedIdKeepsLoudCopyEvenForToggleLikeId() {
        // boss-mcp executableMissing is .blocker but degraded — the App flags it; copy stays loud.
        let checks = [check("boss-mcp", .blocker)]
        let reframe = AutonomyReadinessReframe.present(
            state: .blocked,
            checks: checks,
            degradedCheckIds: ["boss-mcp"]
        )

        XCTAssertEqual(reframe.tone, .degraded)
        XCTAssertEqual(reframe.pillText, "blocked")
    }

    func testAttentionStateStaysCalmWatchCopy() {
        let checks = [check("boss-watch", .warning)]
        let reframe = AutonomyReadinessReframe.present(state: .attention, checks: checks)

        XCTAssertEqual(reframe.tone, .calm)
        XCTAssertEqual(reframe.pillText, "watch")
        XCTAssertEqual(reframe.headline, AutonomyReadinessSnapshot(checks: checks).headline)
    }

    func testReadyStateUsesReadyCopy() {
        let checks = [check("terminal-trust", .ok)]
        let reframe = AutonomyReadinessReframe.present(state: .ready, checks: checks)

        XCTAssertEqual(reframe.tone, .calm)
        XCTAssertEqual(reframe.pillText, "ready")
        XCTAssertEqual(reframe.headline, AutonomyReadinessSnapshot(checks: checks).headline)
    }

    func testBlockedWithNoBlockerChecksIsTreatedAsCalmSetup() {
        // Defensive: state says blocked but no check is a blocker → don't invent the wall.
        let reframe = AutonomyReadinessReframe.present(state: .blocked, checks: [check("boss-watch", .warning)])
        XCTAssertEqual(reframe.tone, .calm)
        XCTAssertTrue(reframe.headline.contains("0") || reframe.tone == .calm)
    }

    // MARK: - Runtime button availability (FIX 1 / U9-1)

    /// Every kind has a live button when its actuator has work to do.
    private func allLiveAvailability() -> AutonomyRemediationAvailability {
        AutonomyRemediationAvailability(
            hasUntrustedTerminals: true,
            hasResumableDisabledTerminals: true,
            mcpRegistrationActionable: true,
            hasRecoverableEntries: true,
            bossWatchDisabled: true,
            loginItemActionable: true
        )
    }

    /// Nothing the in-app toggles can act on — every per-kind button is suppressed.
    private func noLiveAvailability() -> AutonomyRemediationAvailability {
        AutonomyRemediationAvailability(
            hasUntrustedTerminals: false,
            hasResumableDisabledTerminals: false,
            mcpRegistrationActionable: false,
            hasRecoverableEntries: false,
            bossWatchDisabled: false,
            loginItemActionable: false
        )
    }

    func testHasLiveButtonMirrorsEachKindsRuntimeGate() {
        let all = allLiveAvailability()
        for kind in [AutonomyRemediationKind.trustTerminals, .enableResume, .connectTools, .recover, .enableWatch, .openAtLogin] {
            XCTAssertTrue(AutonomyRemediationMapper.hasLiveButton(for: kind, availability: all), "\(kind) should be live when its actuator has work")
        }
        let none = noLiveAvailability()
        for kind in [AutonomyRemediationKind.trustTerminals, .enableResume, .connectTools, .recover, .enableWatch, .openAtLogin] {
            XCTAssertFalse(AutonomyRemediationMapper.hasLiveButton(for: kind, availability: none), "\(kind) button must be suppressed when its actuator has nothing to do")
        }
    }

    func testManualOnlyRecoveryBlockerIsRuntimeSuppressedDegraded() {
        // A `recovery` .blocker whose only recovering entries are .manualActionNeeded
        // (excluded from recoverableEntries) maps to a remediation in the abstract
        // mapper, but its button is suppressed at runtime → it must be folded into
        // the degraded set so the reframe does NOT promise a one-tap fix it can't show.
        let checks = [check("recovery", .blocker)]
        var availability = allLiveAvailability()
        availability.hasRecoverableEntries = false

        let degraded = AutonomyRemediationMapper.runtimeSuppressedDegradedCheckIds(
            checks: checks,
            availability: availability
        )
        XCTAssertEqual(degraded, ["recovery"])

        // Folded into degradedCheckIds, the reframe goes loud, not calm one-tap.
        XCTAssertEqual(
            AutonomyRemediationMapper.reason(for: checks, degradedCheckIds: degraded),
            .degraded
        )
        let reframe = AutonomyReadinessReframe.present(
            state: .blocked,
            checks: checks,
            degradedCheckIds: degraded
        )
        XCTAssertEqual(reframe.tone, .degraded)
        XCTAssertEqual(reframe.pillText, "blocked")
    }

    func testManualStrategyTerminalResumeBlockerIsRuntimeSuppressedDegraded() {
        // A `terminal-resume` .blocker whose blocking agents are all .manual strategy
        // (excluded from resumableDisabledAutonomyAgentEntries) has its Enable-resume
        // button suppressed at runtime → degraded.
        let checks = [check("terminal-resume", .blocker)]
        var availability = allLiveAvailability()
        availability.hasResumableDisabledTerminals = false

        let degraded = AutonomyRemediationMapper.runtimeSuppressedDegradedCheckIds(
            checks: checks,
            availability: availability
        )
        XCTAssertEqual(degraded, ["terminal-resume"])
        XCTAssertEqual(
            AutonomyRemediationMapper.reason(for: checks, degradedCheckIds: degraded),
            .degraded
        )
    }

    func testFixableRecoveryBlockerStaysOneTap() {
        // The genuinely one-tap case: recoverable entries exist → button is live →
        // NOT folded into the degraded set, reframe stays calm one-tap.
        let checks = [check("recovery", .blocker)]
        let availability = allLiveAvailability()

        let degraded = AutonomyRemediationMapper.runtimeSuppressedDegradedCheckIds(
            checks: checks,
            availability: availability
        )
        XCTAssertTrue(degraded.isEmpty)
        XCTAssertEqual(
            AutonomyRemediationMapper.reason(for: checks, degradedCheckIds: degraded),
            .oneTapSetup
        )
    }

    func testMixedFixableAndSuppressedBlockerIsDegraded() {
        // One blocker is fixable (terminal-trust, untrusted terminals exist) and one
        // is runtime-suppressed (recovery, only manual entries). A single
        // unfixable-in-app blocker makes the whole snapshot degraded — the headline
        // must not promise "N things to make this hands-off" over a blocker with no
        // tappable fix.
        let checks = [
            check("terminal-trust", .blocker),
            check("recovery", .blocker)
        ]
        var availability = allLiveAvailability()
        availability.hasRecoverableEntries = false

        let degraded = AutonomyRemediationMapper.runtimeSuppressedDegradedCheckIds(
            checks: checks,
            availability: availability
        )
        XCTAssertEqual(degraded, ["recovery"])
        XCTAssertEqual(
            AutonomyRemediationMapper.reason(for: checks, degradedCheckIds: degraded),
            .degraded
        )
        let reframe = AutonomyReadinessReframe.present(
            state: .blocked,
            checks: checks,
            degradedCheckIds: degraded
        )
        XCTAssertEqual(reframe.tone, .degraded)
    }

    func testRuntimeSuppressionOnlyAppliesToBlockersWithAbstractRemediation() {
        // A non-blocker (warning) check, and a non-remediable id, are never folded
        // in by the runtime-suppression pass — it only escalates a blocker that the
        // abstract mapper WOULD offer a button for but the runtime gate suppresses.
        let checks = [
            check("boss-watch", .warning),   // warning, not a blocker
            check("executables", .blocker)   // blocker but no abstract remediation
        ]
        let degraded = AutonomyRemediationMapper.runtimeSuppressedDegradedCheckIds(
            checks: checks,
            availability: noLiveAvailability()
        )
        XCTAssertTrue(degraded.isEmpty, "got: \(degraded)")
    }

    private func check(_ id: String, _ state: AutonomyReadinessCheckState) -> AutonomyReadinessCheck {
        AutonomyReadinessCheck(id: id, label: id, detail: id, state: state)
    }
}
