import XCTest
@testable import OuroWorkbenchCore

/// F12a Gap 2 — durable wiring assertions for the missing-`screen` diagnosis.
///
/// The pure `TerminalExitDiagnosis` seam is unit-tested + 100% covered in Core; the
/// App that wires it (preflight + the markTerminated backstop) isn't coverage-gated
/// and can't be click-tested in CI, so we source-pin its structural wiring the same
/// `appSource()` way `TerminalLeakReaperWiringTests` / `ReplayDedupWiringTests` do.
///
/// The risks these pins defend (the spec's behavioral risks for gap 2):
///   - the preflight must check the OUTER `screen` executable
///     (`PersistentTerminalSession.executable`) health, NOT just the inner agent —
///     so a missing multiplexer is caught BEFORE the spawn (the primary fix);
///   - that check must be GATED strictly on `plan.persistentSessionName != nil` —
///     cold-start/provider probes spawn `ouro`/`gh` DIRECTLY (no screen wrapper),
///     so their 127 must NOT be misattributed to a missing multiplexer;
///   - the `markTerminated` 127 backstop (TOCTOU: screen vanished between preflight
///     and spawn) must render the `TerminalExitDiagnosis` sentence instead of the
///     dead-end "exited with code 127", again gated on persistentSessionName.
final class ScreenPreflightWiringTests: XCTestCase {
    // MARK: Preflight — primary fix

    func testPreflightChecksTheOuterScreenExecutableGatedOnPersistentSessionName() throws {
        let body = try launchPreflightProblem()
        XCTAssertTrue(
            body.contains("plan.persistentSessionName"),
            "the screen preflight must be GATED on plan.persistentSessionName (a direct spawn has no screen wrapper to blame)"
        )
        XCTAssertTrue(
            body.contains("PersistentTerminalSession.executable"),
            "the preflight must check the OUTER screen executable (PersistentTerminalSession.executable), not just the inner agent"
        )
        XCTAssertTrue(
            body.contains("executableHealthChecker.health(for:"),
            "the preflight must reuse the existing ExecutableHealthChecker for the screen exe"
        )
    }

    func testPreflightScreenCheckIsOrderedBeforeTheInnerAgentReturnNil() throws {
        let body = try launchPreflightProblem()
        // The screen gate must sit while persistentSessionName is in scope and
        // return its problem before the existing inner-agent `resolved.contains("/")
        // → return nil` early-out (which would otherwise short-circuit bare presets
        // and never reach a screen check).
        let screenIndex = try XCTUnwrap(
            body.range(of: "PersistentTerminalSession.executable")?.lowerBound,
            "the preflight must reference the screen executable"
        )
        let innerEarlyOut = try XCTUnwrap(
            body.range(of: "ExecutableHealthTarget.executable(for: entry)")?.lowerBound,
            "the preflight still validates the inner agent for explicit-path commands"
        )
        XCTAssertLessThan(
            screenIndex, innerEarlyOut,
            "the screen-exe gate must run BEFORE the inner-agent bare-name early-out that returns nil"
        )
    }

    // MARK: markTerminated backstop — TOCTOU

    func testMarkTerminatedRendersTheDiagnosisOn127ForScreenWrappedSessions() throws {
        let body = try markTerminated()
        XCTAssertTrue(
            body.contains("TerminalExitDiagnosis.screenWrappedExit("),
            "markTerminated must render the TerminalExitDiagnosis backstop instead of the dead-end 'exited with code 127'"
        )
        // Gated on the screen wrapper: a direct-spawn 127 must NOT be rewritten.
        XCTAssertTrue(
            body.contains("persistentSessionName"),
            "the 127 backstop must be gated on the screen wrapper (persistentSessionName) so a direct-spawn 127 isn't misattributed"
        )
        // It must feed the live screen-exe health, not a hardcoded verdict.
        XCTAssertTrue(
            body.contains("executableHealthChecker.health(for: PersistentTerminalSession.executable)")
                || (body.contains("executableHealthChecker.health(for:") && body.contains("PersistentTerminalSession.executable")),
            "the backstop must diagnose with the LIVE screen-exe health, not a hardcoded status"
        )
    }

    // MARK: - Helpers

    private func launchPreflightProblem() throws -> String {
        try sourceSlice(
            in: try appSource(),
            from: "private func launchPreflightProblem(for entry: ProcessEntry, plan: TerminalCommandPlan) -> String? {",
            to: "\n    /// Build the per-session Workbench context"
        )
    }

    private func markTerminated() throws -> String {
        try sourceSlice(
            in: try appSource(),
            from: "func markTerminated(entryId: UUID, runId: UUID, rawStatus: Int32?) {",
            to: "\n    /// Whether enough time has passed since the last unexpected-exit"
        )
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

    private func sourceSlice(in source: String, from startMarker: String, to endMarker: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound, "missing start marker: \(startMarker)")
        let end = try XCTUnwrap(source.range(of: endMarker, range: start..<source.endIndex)?.lowerBound, "missing end marker: \(endMarker)")
        return String(source[start..<end])
    }
}
