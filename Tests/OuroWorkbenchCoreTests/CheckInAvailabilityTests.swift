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

    func testNeedsBossWhenNameIsEmpty() {
        XCTAssertEqual(
            CheckInAvailability.resolve(bossAgentName: "", bossIsUsable: false, isRunning: false),
            .needsBoss
        )
    }

    func testNeedsBossWhenNameIsWhitespaceOnly() {
        XCTAssertEqual(
            CheckInAvailability.resolve(bossAgentName: "   \n\t", bossIsUsable: false, isRunning: false),
            .needsBoss
        )
    }

    func testNeedsBossWhenNamedButNotUsable() {
        // A boss is named but its bundle isn't installed/ready — asking it would
        // silently no-op (or fail), so the affordance must route to set-up, not
        // pretend it can run.
        XCTAssertEqual(
            CheckInAvailability.resolve(bossAgentName: "scout", bossIsUsable: false, isRunning: false),
            .needsBoss
        )
    }

    func testRunningWinsOverNeedsBoss() {
        // Defensive: if a check-in is somehow in flight while the boss is no
        // longer usable, we still report running (the in-flight guard owns the
        // button) rather than flicker to needs-boss mid-run.
        XCTAssertEqual(
            CheckInAvailability.resolve(bossAgentName: "", bossIsUsable: false, isRunning: true),
            .running
        )
    }

    // MARK: - canRunNow

    func testCanRunNowOnlyWhenReady() {
        XCTAssertTrue(CheckInAvailability.ready.canRunNow)
        XCTAssertFalse(CheckInAvailability.needsBoss.canRunNow)
        XCTAssertFalse(CheckInAvailability.running.canRunNow)
    }

    func testRoutesToBossSetupOnlyWhenNeedsBoss() {
        XCTAssertTrue(CheckInAvailability.needsBoss.routesToBossSetup)
        XCTAssertFalse(CheckInAvailability.ready.routesToBossSetup)
        XCTAssertFalse(CheckInAvailability.running.routesToBossSetup)
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

    func testNeedsBossHelpPointsAtSettingUpABoss() {
        let help = CheckInAvailability.helpText(for: .needsBoss, bossAgentName: "")
        XCTAssertTrue(help.lowercased().contains("boss"), help)
        // Mentions the set-up action so the tooltip turns the dead click into a
        // next step.
        XCTAssertTrue(help.lowercased().contains("set up"), help)
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
