import XCTest
@testable import OuroWorkbenchCore

final class TranscriptTextSanitizerTests: XCTestCase {
    func testLoneEscapeAtEndIsRemovedWithoutDroppingVisibleText() {
        XCTAssertEqual(TranscriptTextSanitizer.sanitized("ready\u{1B}"), "ready")
    }

    func testOscSequencesTerminatedByBelOrStringTerminatorAreRemoved() {
        let input = "a\u{1B}]0;title\u{07}b\u{1B}]1;ignored\u{1B}\\c"

        XCTAssertEqual(TranscriptTextSanitizer.sanitized(input), "abc")
    }

    func testUnterminatedOscSequenceConsumesThroughEnd() {
        XCTAssertEqual(TranscriptTextSanitizer.sanitized("prefix\u{1B}]0;unterminated"), "prefix")
    }

    func testTwoCharacterEscapeSequenceIsRemoved() {
        XCTAssertEqual(TranscriptTextSanitizer.sanitized("a\u{1B}7b"), "ab")
    }
}
