import XCTest
@testable import OuroWorkbenchCore

/// U41: the TTFA readiness actuators (`trustUntrustedAutonomyAgentTerminals` /
/// `enableAutoResumeForAutonomyAgentTerminals`) must NOT repurpose the
/// operator-visible `entry.lastSummary` for a settings-toggle confirmation. That
/// field is the session status line and feeds the boss prompt, so tapping "Trust"
/// in the readiness popover shouldn't oddly rewrite a session's status. The
/// confirmation belongs in the action log (`recordActionLog`), which both
/// actuators already call.
///
/// The App target isn't coverage-gated and can't be click-tested in CI, so we pin
/// the structural wiring by reading the App source directly — the same pattern
/// `BossForwardStatusWiringTests` uses.
final class ReadinessActuatorStatusWiringTests: XCTestCase {
    func testTrustActuatorDoesNotRewriteSessionStatusLine() throws {
        let body = try actuatorBody(named: "func trustUntrustedAutonomyAgentTerminals()")
        // The trust flip itself stays.
        XCTAssertTrue(body.contains("entry.trust = .trusted"), "the trust state change must remain")
        // But it must not write the operator-visible status line as a side-effect.
        XCTAssertFalse(
            body.contains("entry.lastSummary ="),
            "the trust actuator must not rewrite entry.lastSummary (U41)"
        )
        // The confirmation still lives where it belongs — the action log.
        XCTAssertTrue(body.contains("recordActionLog"), "the action-log confirmation must remain")
    }

    func testAutoResumeActuatorDoesNotRewriteSessionStatusLine() throws {
        let body = try actuatorBody(named: "func enableAutoResumeForAutonomyAgentTerminals()")
        // The auto-resume flip itself stays.
        XCTAssertTrue(body.contains("entry.autoResume = true"), "the auto-resume state change must remain")
        XCTAssertFalse(
            body.contains("entry.lastSummary ="),
            "the auto-resume actuator must not rewrite entry.lastSummary (U41)"
        )
        XCTAssertTrue(body.contains("recordActionLog"), "the action-log confirmation must remain")
    }

    // MARK: - source pinning helpers (App is not coverage-gated)

    /// The body of a model function, from its signature to the next `func` (or
    /// `// MARK`) boundary — enough to assert what it does and doesn't touch.
    private func actuatorBody(named signature: String) throws -> String {
        let source = try appSource()
        let start = try XCTUnwrap(
            source.range(of: signature)?.upperBound,
            "could not find \(signature) in the App source"
        )
        let tail = source[start...]
        // End at the next function declaration so we read only this body.
        let end = tail.range(of: "\n    func ")?.lowerBound ?? tail.endIndex
        return String(tail[tail.startIndex..<end])
    }

    private func appSource() throws -> String {
        let sourceURL = repoRoot()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchApp")
            .appendingPathComponent("OuroWorkbenchApp.swift")
        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
