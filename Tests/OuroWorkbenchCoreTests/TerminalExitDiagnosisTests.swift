import XCTest
@testable import OuroWorkbenchCore

/// F12a Gap 2 — the phrasebook-style diagnosis for a `screen`-wrapped 127 exit.
///
/// Every custom session launches through `screen` (the outer multiplexer
/// executable). When `screen` is missing or not runnable, the wrapped command
/// exits 127 and the old path rendered a dead-end "exited with code 127". This
/// seam turns the (exitCode, screen-health) pair into one honest operator sentence
/// — or nil when there's nothing screen-specific to say.
final class TerminalExitDiagnosisTests: XCTestCase {
    func testNon127ExitYieldsNoScreenDiagnosis() {
        // Only a 127 is the "command not found" signature screen produces when it
        // can't exec. Any other code (or a signal, nil) is the inner agent's own
        // exit — never misattributed to a missing multiplexer.
        XCTAssertNil(TerminalExitDiagnosis.screenWrappedExit(exitCode: 0, screenHealth: .missing))
        XCTAssertNil(TerminalExitDiagnosis.screenWrappedExit(exitCode: 1, screenHealth: .missing))
        XCTAssertNil(TerminalExitDiagnosis.screenWrappedExit(exitCode: nil, screenHealth: .missing))
    }

    func test127WithMissingScreenExplainsTheMultiplexerIsGone() {
        let sentence = TerminalExitDiagnosis.screenWrappedExit(exitCode: 127, screenHealth: .missing)
        XCTAssertNotNil(sentence)
        XCTAssertTrue(sentence?.contains("screen") == true, "must name the screen multiplexer")
        XCTAssertTrue(
            sentence?.lowercased().contains("reinstall") == true,
            "a missing multiplexer must tell the operator to reinstall it"
        )
    }

    func test127WithNotExecutableScreenAlsoPointsAtTheMultiplexer() {
        let sentence = TerminalExitDiagnosis.screenWrappedExit(exitCode: 127, screenHealth: .notExecutable)
        XCTAssertNotNil(sentence)
        XCTAssertTrue(sentence?.contains("screen") == true)
        XCTAssertTrue(sentence?.lowercased().contains("reinstall") == true)
    }

    func test127WithAvailableScreenBlamesThePathNotTheMultiplexer() {
        // screen is fine, so a 127 is the INNER command not being on PATH — don't
        // misdirect the operator to reinstall a multiplexer that's healthy.
        let sentence = TerminalExitDiagnosis.screenWrappedExit(exitCode: 127, screenHealth: .available)
        XCTAssertNotNil(sentence)
        XCTAssertTrue(sentence?.lowercased().contains("path") == true, "a healthy screen + 127 is a PATH problem")
        XCTAssertFalse(
            sentence?.lowercased().contains("reinstall") == true,
            "a healthy multiplexer must NOT be told to reinstall"
        )
    }
}
