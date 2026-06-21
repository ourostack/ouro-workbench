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

    // MARK: - classifyWithReason: signal carries a short "why" line (U10)

    func testReasonForApprovalMenuIsTheQuestionAboveIt() {
        // The menu line itself ("❯ 1. Yes") is uninformative; the operator wants
        // to know WHAT is being approved, so the reason is the question line.
        let tail = """
        Edit file src/main.swift?

        Do you want to make this edit?
        ❯ 1. Yes
          2. Yes, and don't ask again
          3. No, and tell Claude what to do differently
        """
        let result = AttentionSignalDetector.classifyWithReason(tail: tail)
        XCTAssertEqual(result.signal, .waitingOnHuman)
        XCTAssertEqual(result.reason, "Do you want to make this edit?")
    }

    func testReasonForYesNoPromptIsThePromptLine() {
        let result = AttentionSignalDetector.classifyWithReason(tail: "Proceed with deployment? (y/N) ")
        XCTAssertEqual(result.signal, .waitingOnHuman)
        XCTAssertEqual(result.reason, "Proceed with deployment? (y/N)")
    }

    func testReasonForPassphrasePromptIsThePromptLine() {
        let result = AttentionSignalDetector.classifyWithReason(
            tail: "Enter passphrase for key '/Users/me/.ssh/id_ed25519': "
        )
        XCTAssertEqual(result.signal, .waitingOnHuman)
        XCTAssertEqual(result.reason, "Enter passphrase for key '/Users/me/.ssh/id_ed25519':")
    }

    func testReasonForBlockedIsTheErrorLine() {
        let tail = """
        Compiling OuroWorkbenchCore (12 sources)
        error: cannot find 'foo' in scope
        Build failed after 3.2s
        """
        let result = AttentionSignalDetector.classifyWithReason(tail: tail)
        XCTAssertEqual(result.signal, .blocked)
        XCTAssertEqual(result.reason, "Build failed after 3.2s")
    }

    func testReasonIsNilForUnknown() {
        let result = AttentionSignalDetector.classifyWithReason(tail: "Resolving graph\nDownloading 88%")
        XCTAssertEqual(result.signal, .unknown)
        XCTAssertNil(result.reason)
    }

    func testReasonIsNilForEmptyTail() {
        let result = AttentionSignalDetector.classifyWithReason(tail: "   \n  \n")
        XCTAssertEqual(result.signal, .unknown)
        XCTAssertNil(result.reason)
    }

    func testReasonIsTruncatedToABoundedLength() throws {
        // A pathologically long prompt line is clipped so the banner/snapshot
        // never carries an unbounded blob.
        let longQuestion = "Do you want to proceed with " + String(repeating: "a", count: 400) + "?"
        let result = AttentionSignalDetector.classifyWithReason(tail: longQuestion)
        XCTAssertEqual(result.signal, .waitingOnHuman)
        let reason = try XCTUnwrap(result.reason)
        XCTAssertLessThanOrEqual(reason.count, AttentionSignalDetector.maxReasonLength)
        XCTAssertTrue(reason.hasSuffix("…"), "a clipped reason ends with an ellipsis")
    }

    func testBoundedReasonReturnsNilForAWhitespaceOnlyLine() {
        // Defensive guard: a blank candidate yields no reason.
        XCTAssertNil(AttentionSignalDetector.boundedReason("   "))
        XCTAssertEqual(AttentionSignalDetector.boundedReason("  hi  "), "hi")
    }

    func testReasonForArrowMenuWithoutAQuestionFallsBackToTheMenuLine() {
        // No question line above the menu → the menu/selected option is the best
        // available reason rather than nothing.
        let tail = """
        ❯ 1. Yes
          2. No
        """
        let result = AttentionSignalDetector.classifyWithReason(tail: tail)
        XCTAssertEqual(result.signal, .waitingOnHuman)
        XCTAssertEqual(result.reason, "❯ 1. Yes")
    }

    func testReasonStripsAnsiBeforeReporting() {
        let tail = "\u{1B}[1mDo you want to proceed?\u{1B}[0m\n\u{1B}[36m❯ 1. Yes\u{1B}[0m"
        let result = AttentionSignalDetector.classifyWithReason(tail: tail)
        XCTAssertEqual(result.signal, .waitingOnHuman)
        XCTAssertEqual(result.reason, "Do you want to proceed?")
    }

    func testClassifyStillReturnsBareSignalAndAgreesWithReasonVariant() {
        // The legacy `classify` is the `.signal` of `classifyWithReason`.
        for tail in [
            "Proceed? (y/N)",
            "Compiling\nbuild failed",
            "Resolving graph"
        ] {
            XCTAssertEqual(
                AttentionSignalDetector.classify(tail: tail),
                AttentionSignalDetector.classifyWithReason(tail: tail).signal
            )
        }
    }
}
