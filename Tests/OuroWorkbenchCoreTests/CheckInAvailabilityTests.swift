import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class CheckInAvailabilityTests: XCTestCase {
    // MARK: - resolve

    func testReadyWhenBossIsSetAndUsableAndNotRunning() {
        XCTAssertEqual(
            CheckInAvailability.resolve(bossAgentName: "scout", bossIsUsable: true, isRunning: false),
            .ready
        )
    }

    func testRunningTakesPrecedenceEvenWithAUsableBoss() {
        // A check-in already in flight is the running state regardless of boss —
        // the button shows "running" / disabled, never re-enters.
        XCTAssertEqual(
            CheckInAvailability.resolve(bossAgentName: "scout", bossIsUsable: true, isRunning: true),
            .running
        )
    }

    // MARK: - FIX 4: the no-boss / boss-unreachable split

    func testNoBossWhenNameIsEmpty() {
        // No boss chosen yet (fresh / factory-reset machine) → full onboarding pick.
        XCTAssertEqual(
            CheckInAvailability.resolve(bossAgentName: "", bossIsUsable: false, isRunning: false),
            .noBoss
        )
    }

    func testNoBossWhenNameIsWhitespaceOnly() {
        XCTAssertEqual(
            CheckInAvailability.resolve(bossAgentName: "   \n\t", bossIsUsable: false, isRunning: false),
            .noBoss
        )
    }

    func testBossUnreachableWhenNamedButNotUsable() {
        // THE fix: a boss IS configured but currently un-usable (daemon dead / bundle
        // missing). This must NOT collapse to no-boss/onboarding — it's a reconnect
        // case that carries the agent's name so the surface can say "X isn't
        // reachable — reconnect it" instead of dumping into the boss-pick onboarding.
        XCTAssertEqual(
            CheckInAvailability.resolve(bossAgentName: "scout", bossIsUsable: false, isRunning: false),
            .bossUnreachable(name: "scout")
        )
    }

    func testBossUnreachableTrimsTheName() {
        // The carried name is trimmed so the reconnect copy never shows padding.
        XCTAssertEqual(
            CheckInAvailability.resolve(bossAgentName: "  scout \n", bossIsUsable: false, isRunning: false),
            .bossUnreachable(name: "scout")
        )
    }

    func testRunningWinsOverNoBoss() {
        // Defensive: if a check-in is somehow in flight while the boss is no
        // longer usable, we still report running (the in-flight guard owns the
        // button) rather than flicker mid-run.
        XCTAssertEqual(
            CheckInAvailability.resolve(bossAgentName: "", bossIsUsable: false, isRunning: true),
            .running
        )
    }

    func testRunningWinsOverBossUnreachable() {
        XCTAssertEqual(
            CheckInAvailability.resolve(bossAgentName: "scout", bossIsUsable: false, isRunning: true),
            .running
        )
    }

    // MARK: - canRunNow

    func testCanRunNowOnlyWhenReady() {
        XCTAssertTrue(CheckInAvailability.ready.canRunNow)
        XCTAssertFalse(CheckInAvailability.noBoss.canRunNow)
        XCTAssertFalse(CheckInAvailability.bossUnreachable(name: "scout").canRunNow)
        XCTAssertFalse(CheckInAvailability.running.canRunNow)
    }

    // MARK: - routing: onboarding vs reconnect

    func testRoutesToBossSetupOnlyWhenNoBoss() {
        // Onboarding (the full boss-pick) is ONLY for the genuine no-boss case.
        XCTAssertTrue(CheckInAvailability.noBoss.routesToBossSetup)
        XCTAssertFalse(CheckInAvailability.bossUnreachable(name: "scout").routesToBossSetup)
        XCTAssertFalse(CheckInAvailability.ready.routesToBossSetup)
        XCTAssertFalse(CheckInAvailability.running.routesToBossSetup)
    }

    func testRoutesToReconnectOnlyWhenBossUnreachable() {
        // A configured-but-unreachable boss routes to a reconnect affordance for
        // THAT agent — never the full onboarding pick.
        XCTAssertTrue(CheckInAvailability.bossUnreachable(name: "scout").routesToReconnect)
        XCTAssertFalse(CheckInAvailability.noBoss.routesToReconnect)
        XCTAssertFalse(CheckInAvailability.ready.routesToReconnect)
        XCTAssertFalse(CheckInAvailability.running.routesToReconnect)
    }

    func testUnreachableBossNameAccessor() {
        // The carried name is exposed so the App can drive the per-agent reconnect.
        XCTAssertEqual(CheckInAvailability.bossUnreachable(name: "scout").unreachableBossName, "scout")
        XCTAssertNil(CheckInAvailability.noBoss.unreachableBossName)
        XCTAssertNil(CheckInAvailability.ready.unreachableBossName)
        XCTAssertNil(CheckInAvailability.running.unreachableBossName)
    }

    // MARK: - help text (single-sourced wording)

    func testReadyHelpNamesTheBossAndTheShortcut() {
        let help = CheckInAvailability.helpText(for: .ready, bossAgentName: "scout")
        XCTAssertTrue(help.contains("scout"), help)
        XCTAssertTrue(help.contains("⌘I"), help)
    }

    func testReadyHelpFallsBackToGenericBossWhenNameMissing() {
        // .ready with an empty name shouldn't happen via resolve, but the help
        // builder is defensive: it never interpolates a blank name into the
        // sentence ("Ask  what's going on").
        let help = CheckInAvailability.helpText(for: .ready, bossAgentName: "  ")
        XCTAssertFalse(help.contains("Ask  "), help)
        XCTAssertTrue(help.contains("⌘I"), help)
    }

    func testRunningHelpExplainsTheInFlightCheckIn() {
        let help = CheckInAvailability.helpText(for: .running, bossAgentName: "scout")
        XCTAssertFalse(help.isEmpty)
        // Distinct wording from the ready case — it's about the in-flight ask.
        XCTAssertNotEqual(help, CheckInAvailability.helpText(for: .ready, bossAgentName: "scout"))
    }

    func testNoBossHelpPointsAtSettingUpABoss() {
        let help = CheckInAvailability.helpText(for: .noBoss, bossAgentName: "")
        XCTAssertTrue(help.lowercased().contains("boss"), help)
        // Mentions the set-up action so the tooltip turns the dead click into a
        // next step.
        XCTAssertTrue(help.lowercased().contains("set up"), help)
    }

    func testBossUnreachableHelpNamesTheBossAndSaysReconnect() {
        // The honest message: "your boss X isn't reachable — reconnect it." Names the
        // agent and points at reconnect (NOT setting up a new boss).
        let help = CheckInAvailability.helpText(for: .bossUnreachable(name: "scout"), bossAgentName: "scout")
        XCTAssertTrue(help.contains("scout"), help)
        XCTAssertTrue(help.lowercased().contains("reconnect"), help)
        XCTAssertTrue(help.lowercased().contains("reach"), help)
    }

    func testBossUnreachableHelpDiffersFromNoBossHelp() {
        let unreachable = CheckInAvailability.helpText(for: .bossUnreachable(name: "scout"), bossAgentName: "scout")
        let noBoss = CheckInAvailability.helpText(for: .noBoss, bossAgentName: "")
        XCTAssertNotEqual(unreachable, noBoss, "unreachable and no-boss must read differently")
    }

    func testReadyAndRunningHelpDistinguishTheOneShotAskFromBossWatch() {
        // U12: help on the manual pull must distinguish "ask once now" from the
        // automatic Boss Watch loop so the operator builds one mental model.
        for state in [CheckInAvailability.ready, .running] {
            let help = CheckInAvailability.helpText(for: state, bossAgentName: "scout")
            XCTAssertTrue(help.contains("Boss Watch"), "\(state): \(help)")
        }
    }
}
