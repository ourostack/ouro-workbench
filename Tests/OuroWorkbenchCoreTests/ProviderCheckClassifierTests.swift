import XCTest
@testable import OuroWorkbenchCore

/// Tests for `ProviderCheckClassifier` — the pure seam that fixes the P0 false-green Connect
/// bug (F2). `ouro check` exits 0 in EVERY state (working, vault-locked, 401, network-down), so
/// the verdict MUST be derived from the OUTPUT, never the exit code. The load-bearing safety
/// property: only the exact token `ready` yields `.working`; any drift/ambiguity yields
/// `.indeterminate` — never a false green.
final class ProviderCheckClassifierTests: XCTestCase {
    private let classifier = ProviderCheckClassifier()

    // MARK: - Verdict raw values + case list (Codable/CaseIterable surface)

    func testVerdictRawValues() {
        XCTAssertEqual(ProviderConnectionVerdict.working.rawValue, "working")
        XCTAssertEqual(ProviderConnectionVerdict.vaultLocked.rawValue, "vaultLocked")
        XCTAssertEqual(ProviderConnectionVerdict.unauthorized.rawValue, "unauthorized")
        XCTAssertEqual(ProviderConnectionVerdict.unreachable.rawValue, "unreachable")
        XCTAssertEqual(ProviderConnectionVerdict.indeterminate.rawValue, "indeterminate")
    }

    func testVerdictCaseIterableCoversEveryCase() {
        XCTAssertEqual(
            Set(ProviderConnectionVerdict.allCases),
            [.working, .vaultLocked, .unauthorized, .unreachable, .indeterminate]
        )
    }

    // MARK: - working: ONLY the exact token `ready`, and exit code is ignored

    func testReadyYieldsWorkingOnExitZero() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "slugger outward openai / gpt-5: ready", stderr: ""),
            .working
        )
    }

    func testReadyYieldsWorkingEvenOnNonZeroExitCode() {
        // Proves the exit code is IGNORED for the `.working` decision: `ouro check` can exit
        // non-zero while the lane is genuinely ready.
        XCTAssertEqual(
            classifier.classify(exitCode: 7, stdout: "slugger outward openai / gpt-5: ready", stderr: ""),
            .working
        )
    }

    func testFailedVerdictWinsOverAnEarlierStrayReadyLineOnExitZero() {
        // The classifier keys on the LAST verdict line. An earlier informational `ready` line
        // must NOT false-green a lane whose real verdict is a 401. Exit 0 (the bug condition)
        // must not rescue it either.
        let out = """
        slugger inner anthropic / claude: ready
        slugger outward openai / gpt-5: failed (401 Unauthorized)
        """
        XCTAssertEqual(classifier.classify(exitCode: 0, stdout: out, stderr: ""), .unauthorized)
    }

    // MARK: - vaultLocked: unknown (...) matching a vault phrase

    func testUnknownLockedBitwardenSessionYieldsVaultLocked() {
        let out = "slugger outward openai / gpt-5: unknown (bw CLI could not use the local "
            + "Bitwarden session because it is locked, missing, or expired)"
        XCTAssertEqual(classifier.classify(exitCode: 0, stdout: out, stderr: ""), .vaultLocked)
    }

    func testUnknownVaultPhraseYieldsVaultLocked() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: unknown (vault is sealed)", stderr: ""),
            .vaultLocked
        )
    }

    func testUnknownNoCredentialsYieldsVaultLocked() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: unknown (no credentials found)", stderr: ""),
            .vaultLocked
        )
    }

    func testUnknownNotConfiguredYieldsVaultLocked() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: unknown (provider not configured)", stderr: ""),
            .vaultLocked
        )
    }

    func testUnknownLockedTokenYieldsVaultLocked() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: unknown (it is LOCKED right now)", stderr: ""),
            .vaultLocked
        )
    }

    func testUnknownThatMatchesNoVaultPhraseYieldsIndeterminate() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: unknown (some other reason)", stderr: ""),
            .indeterminate
        )
    }

    // MARK: - unauthorized: failed (...) matching an HTTP-auth phrase

    func testFailed401YieldsUnauthorized() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (401 Unauthorized)", stderr: ""),
            .unauthorized
        )
    }

    func testFailed403ForbiddenYieldsUnauthorized() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (403 Forbidden)", stderr: ""),
            .unauthorized
        )
    }

    func testFailedHTTP401YieldsUnauthorized() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (HTTP 401)", stderr: ""),
            .unauthorized
        )
    }

    func testFailedHTTP403YieldsUnauthorized() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (HTTP 403)", stderr: ""),
            .unauthorized
        )
    }

    func testFailedUnauthorizedWordYieldsUnauthorized() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (request was unauthorized)", stderr: ""),
            .unauthorized
        )
    }

    func testFailedAuthCodeAtVeryEndOfParentheticalYieldsUnauthorized() {
        // The code is the final token with no trailing char (a truncated/odd line). The boundary
        // is end-of-string, which must still classify as unauthorized.
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (401", stderr: ""),
            .unauthorized
        )
    }

    func testFailedAuthCodeImmediatelyFollowedByDigitsIsNotUnauthorized() {
        // `4011` is not a 401 word-boundary match; with no other auth/network signal it is
        // indeterminate (never false-green, never mis-bucketed).
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (4011 weird)", stderr: ""),
            .indeterminate
        )
    }

    func testFailedNotAuthorizedYieldsUnauthorized() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (caller is not authorized)", stderr: ""),
            .unauthorized
        )
    }

    func testFailedExpiredTokenYieldsUnauthorized() {
        XCTAssertEqual(
            classifier.classify(
                exitCode: 0,
                stdout: "a b c / d: failed (the authentication token is expired)",
                stderr: ""
            ),
            .unauthorized
        )
    }

    // MARK: - unreachable: failed (...) matching a network phrase

    func testFailedFetchFailedYieldsUnreachable() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (fetch failed)", stderr: ""),
            .unreachable
        )
    }

    func testFailedGetaddrinfoENOTFOUNDYieldsUnreachable() {
        XCTAssertEqual(
            classifier.classify(
                exitCode: 0,
                stdout: "a b c / d: failed (getaddrinfo ENOTFOUND api.openai.com)",
                stderr: ""
            ),
            .unreachable
        )
    }

    func testFailedTimedOutYieldsUnreachable() {
        XCTAssertEqual(
            classifier.classify(
                exitCode: 0,
                stdout: "a b c / d: failed (provider ping timed out after 10000ms)",
                stderr: ""
            ),
            .unreachable
        )
    }

    func testFailedSocketHangUpYieldsUnreachable() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (socket hang up)", stderr: ""),
            .unreachable
        )
    }

    func testFailedECONNREFUSEDYieldsUnreachable() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (connect ECONNREFUSED)", stderr: ""),
            .unreachable
        )
    }

    func testFailedETIMEDOUTYieldsUnreachable() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (ETIMEDOUT)", stderr: ""),
            .unreachable
        )
    }

    func testFailedTimeoutWordYieldsUnreachable() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (request timeout)", stderr: ""),
            .unreachable
        )
    }

    func testFailedConnectionErrorYieldsUnreachable() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (connection error)", stderr: ""),
            .unreachable
        )
    }

    func testFailedNetworkWordYieldsUnreachable() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (network is down)", stderr: ""),
            .unreachable
        )
    }

    // MARK: - AUTH is tested BEFORE NETWORK within failed()

    func testFailedWithBothAuthAndNetworkPhrasesPrefersUnauthorized() {
        // A parenthetical that mentions both an auth signal and a network word must classify as
        // unauthorized — auth is tested first.
        XCTAssertEqual(
            classifier.classify(
                exitCode: 0,
                stdout: "a b c / d: failed (401 Unauthorized after network retry)",
                stderr: ""
            ),
            .unauthorized
        )
    }

    // MARK: - indeterminate: everything else (never false-green)

    func testFailed500YieldsIndeterminate() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (500 Internal Server Error)", stderr: ""),
            .indeterminate
        )
    }

    func testFailed429YieldsIndeterminate() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: failed (429 Too Many Requests)", stderr: ""),
            .indeterminate
        )
    }

    func testEmptyOutputYieldsIndeterminate() {
        XCTAssertEqual(classifier.classify(exitCode: 0, stdout: "", stderr: ""), .indeterminate)
    }

    func testShellPathErrorYieldsIndeterminate() {
        XCTAssertEqual(
            classifier.classify(exitCode: 127, stdout: "", stderr: "env: ouro: No such file or directory"),
            .indeterminate
        )
    }

    func testColonLineWithoutVerdictSeparatorYieldsIndeterminate() {
        // A line with `: ` but no ` / ` is not a verdict line.
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "note: something happened", stderr: ""),
            .indeterminate
        )
    }

    func testUnparseableStatusYieldsIndeterminate() {
        // A verdict line whose status segment is none of ready/unknown(/failed(.
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: weird-status", stderr: ""),
            .indeterminate
        )
    }

    // MARK: - ANSI stripping + case-insensitivity

    func testAnsiPrefixedReadyLineYieldsWorking() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "\u{1B}[2Kslugger outward openai / gpt-5: ready", stderr: ""),
            .working
        )
    }

    func testUppercaseFailedAuthYieldsUnauthorized() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / d: FAILED (401 Unauthorized)", stderr: ""),
            .unauthorized
        )
    }

    // MARK: - verdict line keys off the LAST `: ` in the status segment

    func testStatusSegmentTakenAfterTheLastColonSpace() {
        // A model name containing `: ` must not derail status extraction — the status is the
        // segment after the LAST `: `.
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "a b c / model: turbo: ready", stderr: ""),
            .working
        )
    }

    // MARK: - stderr is folded into the searched text

    func testVerdictLineFromStderrIsClassified() {
        XCTAssertEqual(
            classifier.classify(exitCode: 0, stdout: "", stderr: "a b c / d: failed (403 Forbidden)"),
            .unauthorized
        )
    }
}
