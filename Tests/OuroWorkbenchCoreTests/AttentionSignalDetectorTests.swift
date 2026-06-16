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

    func testArrowSelectedOptionAcceptsSupportedSeparators() {
        XCTAssertTrue(AttentionSignalDetector.isArrowSelectedOption("❯ 1) Yes"))
        XCTAssertTrue(AttentionSignalDetector.isArrowSelectedOption("❯ 1 Yes"))
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

    func testBracketedYesNoAllVariantIsWaiting() {
        XCTAssertEqual(
            AttentionSignalDetector.classify(tail: "Apply changes? [Y/n/a]"),
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

    func testWaitingSurvivesOscAndLoneEscapeControlCodes() {
        let oscWithBel = "\u{1B}]0;title\u{07}Do you want to proceed? "
        let oscWithST = "\u{1B}]0;title\u{1B}\\Proceed now? (y/N)"
        let loneEscape = "\u{1B}xAllow command? (y/N)"

        XCTAssertEqual(AttentionSignalDetector.classify(tail: oscWithBel), .waitingOnHuman)
        XCTAssertEqual(AttentionSignalDetector.classify(tail: oscWithST), .waitingOnHuman)
        XCTAssertEqual(AttentionSignalDetector.classify(tail: loneEscape), .waitingOnHuman)
    }

    func testCarriageReturnsAreIgnoredBeforeClassifying() {
        XCTAssertEqual(
            AttentionSignalDetector.classify(tail: "building\rDo you want to proceed? "),
            .waitingOnHuman
        )
    }

    // MARK: - Negative: must NOT cry wolf

    func testPlainShellPromptIsNotWaiting() {
        // A bare zsh prompt is idle, not waiting-on-human.
        XCTAssertEqual(AttentionSignalDetector.classify(tail: "~/Projects/app ❯ "), .unknown)
        XCTAssertEqual(AttentionSignalDetector.classify(tail: "$ "), .unknown)
        XCTAssertEqual(AttentionSignalDetector.classify(tail: "user@host project % "), .unknown)
    }

    func testCompilerProgressIsNotWaiting() {
        // Mid-compile progress (no terminal failure as the last line) is neither
        // waiting nor blocked.
        let tail = """
        Compiling OuroWorkbenchCore (12 sources)
        Linking OuroWorkbench
        """
        XCTAssertEqual(AttentionSignalDetector.classify(tail: tail), .unknown)
    }

    func testBuildFailureAsLastLineIsBlocked() {
        // A build that ended on failure is stuck — correctly blocked, not waiting.
        let tail = """
        Compiling OuroWorkbenchCore (12 sources)
        error: cannot find 'foo' in scope
        Build failed after 3.2s
        """
        XCTAssertEqual(AttentionSignalDetector.classify(tail: tail), .blocked)
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

    func testArrowWithBareNumberIsNotWaiting() {
        XCTAssertEqual(AttentionSignalDetector.classify(tail: "❯ 1"), .unknown)
    }

    func testRhetoricalQuestionInLogIsNotWaiting() {
        // A "?" buried in a log line that isn't a direct user question.
        let tail = "INFO why did the cache miss? recomputing\nDONE"
        XCTAssertEqual(AttentionSignalDetector.classify(tail: tail), .unknown)
    }

    func testEmptyTailIsUnknown() {
        XCTAssertEqual(AttentionSignalDetector.classify(tail: "   \n  \n"), .unknown)
    }

    // MARK: - Blocked (stuck on a terminal error)

    func testTerminalErrorsAsLastLineAreBlocked() {
        for tail in [
            "Compiling...\nzsh: command not found: pnpm",
            "$ ./deploy.sh\npermission denied",
            "cloning...\nfatal: repository 'x' does not exist",
            "running build\nbuild failed",
            "node index.js\nError: Cannot find module 'express'\nmodule not found",
            "git push\nfatal: Authentication failed for 'https://...'"
        ] {
            XCTAssertEqual(AttentionSignalDetector.classify(tail: tail), .blocked, "expected blocked for: \(tail)")
        }
    }

    func testErrorFollowedByAPromptIsWaitingNotBlocked() {
        // A prompt after an error means the human can still act → waiting wins.
        let tail = "fatal: merge conflict\nResolve and retry? (y/N)"
        XCTAssertEqual(AttentionSignalDetector.classify(tail: tail), .waitingOnHuman)
    }

    func testErrorMidProgressThatWorkProceededPastIsNotBlocked() {
        // The error isn't the last thing said; the agent kept working.
        let tail = "error: flaky test failed\nretrying...\nall tests passed\nDone in 4.1s"
        XCTAssertEqual(AttentionSignalDetector.classify(tail: tail), .unknown)
    }

    func testBareErrorWordIsNotBlocked() {
        // "error" alone is too noisy to flag.
        XCTAssertEqual(AttentionSignalDetector.classify(tail: "WARN: error rate 0.2% nominal"), .unknown)
    }

    func testStaleMenuFarUpScrollbackIsNotWaiting() {
        // A menu 20+ lines back is stale; recent output is plain logs.
        var lines = ["❯ 1. Yes", "  2. No"]
        for i in 0..<20 { lines.append("log line \(i) processing batch") }
        XCTAssertEqual(AttentionSignalDetector.classify(tail: lines.joined(separator: "\n")), .unknown)
    }
}
