import XCTest
@testable import OuroWorkbenchCore

final class AttentionSignalDetectorTests: XCTestCase {
    // MARK: - Positive: real-world waiting prompts

    func testClaudeCodeApprovalMenuIsWaiting() {
        let tail = """
        Edit file src/main.swift?

        Do you want to make this edit?
        ❯ 1. Yes
          2. Yes, and don't ask again
          3. No, and tell Claude what to do differently
        """
        XCTAssertEqual(AttentionSignalDetector.classify(tail: tail), .waitingOnHuman)
    }

    func testCodexStyleArrowMenuIsWaiting() {
        let tail = """
        Allow command: rm -rf build/
        > 1. Yes
          2. No
        """
        XCTAssertEqual(AttentionSignalDetector.classify(tail: tail), .waitingOnHuman)
    }

    func testLowercaseYesNoPromptIsWaiting() {
        XCTAssertEqual(
            AttentionSignalDetector.classify(tail: "Proceed with deployment? (y/N) "),
            .waitingOnHuman
        )
    }

    func testBracketedYesNoIsWaiting() {
        XCTAssertEqual(
            AttentionSignalDetector.classify(tail: "Overwrite existing file? [y/n]"),
            .waitingOnHuman
        )
    }

    func testPressEnterToContinueIsWaiting() {
        XCTAssertEqual(
            AttentionSignalDetector.classify(tail: "-- More --\nPress enter to continue"),
            .waitingOnHuman
        )
    }

    func testPassphrasePromptIsWaiting() {
        XCTAssertEqual(
            AttentionSignalDetector.classify(tail: "Enter passphrase for key '/Users/me/.ssh/id_ed25519': "),
            .waitingOnHuman
        )
    }

    func testTrailingDirectQuestionIsWaiting() {
        XCTAssertEqual(
            AttentionSignalDetector.classify(tail: "Running tests...\nDo you want to continue? "),
            .waitingOnHuman
        )
    }

    func testWaitingSurvivesAnsiColorCodes() {
        // The menu line wrapped in ANSI color/cursor codes must still match.
        let tail = "\u{1B}[2m? \u{1B}[0m\u{1B}[1mDo you want to proceed?\u{1B}[0m\n\u{1B}[36m❯ 1. Yes\u{1B}[0m"
        XCTAssertEqual(AttentionSignalDetector.classify(tail: tail), .waitingOnHuman)
    }

    // MARK: - Negative: must NOT cry wolf

    func testPlainShellPromptIsNotWaiting() {
        // A bare zsh prompt is idle, not waiting-on-human.
        XCTAssertEqual(AttentionSignalDetector.classify(tail: "~/Projects/app ❯ "), .unknown)
        XCTAssertEqual(AttentionSignalDetector.classify(tail: "$ "), .unknown)
        XCTAssertEqual(AttentionSignalDetector.classify(tail: "user@host project % "), .unknown)
    }

    func testCompilerOutputIsNotWaiting() {
        let tail = """
        Compiling OuroWorkbenchCore (12 sources)
        error: cannot find 'foo' in scope
        Build failed after 3.2s
        """
        XCTAssertEqual(AttentionSignalDetector.classify(tail: tail), .unknown)
    }

    func testProgressOutputIsNotWaiting() {
        let tail = """
        Downloading dependency... 45%
        Downloading dependency... 88%
        Resolving graph
        """
        XCTAssertEqual(AttentionSignalDetector.classify(tail: tail), .unknown)
    }

    func testArrowWithoutNumberIsNotWaiting() {
        // A powerlevel10k-style arrow prompt with no numbered option must not match.
        XCTAssertEqual(AttentionSignalDetector.classify(tail: "❯ git status"), .unknown)
    }

    func testRhetoricalQuestionInLogIsNotWaiting() {
        // A "?" buried in a log line that isn't a direct user question.
        let tail = "INFO why did the cache miss? recomputing\nDONE"
        XCTAssertEqual(AttentionSignalDetector.classify(tail: tail), .unknown)
    }

    func testEmptyTailIsUnknown() {
        XCTAssertEqual(AttentionSignalDetector.classify(tail: "   \n  \n"), .unknown)
    }

    func testStaleMenuFarUpScrollbackIsNotWaiting() {
        // A menu 20+ lines back is stale; recent output is plain logs.
        var lines = ["❯ 1. Yes", "  2. No"]
        for i in 0..<20 { lines.append("log line \(i) processing batch") }
        XCTAssertEqual(AttentionSignalDetector.classify(tail: lines.joined(separator: "\n")), .unknown)
    }
}
