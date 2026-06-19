import XCTest
@testable import OuroWorkbenchCore

/// Tests for `SessionHealthProbe` — the pure classifier the boss uses to confirm
/// a resumed session came up healthy, composing the latest run status, a
/// transcript tail (via the existing `AttentionSignalDetector`), and the
/// time-since-start / time-since-output signals into a single verdict.
final class SessionHealthProbeTests: XCTestCase {
    private let stalled = SessionHealthProbe.defaultStalledThreshold
    private let startup = SessionHealthProbe.defaultStartupGrace

    // MARK: - Healthy

    func testRunningWithRecentOutputIsHealthy() {
        let v = SessionHealthProbe.classify(
            runStatus: .running,
            tail: "Resumed session. Reading files…\nedited Foo.swift",
            elapsedSinceStart: 60,
            elapsedSinceOutput: 2
        )
        XCTAssertEqual(v, .healthy)
    }

    func testWaitingAtPromptIsHealthyNotStalled() {
        // A session parked at an approval prompt came up fine and is responsive —
        // it's waiting on the human, which is healthy, not stalled, even if its
        // output has been quiet for a while.
        let v = SessionHealthProbe.classify(
            runStatus: .waitingForInput,
            tail: "Do you want to proceed? (y/n)",
            elapsedSinceStart: 600,
            elapsedSinceOutput: stalled + 100
        )
        XCTAssertEqual(v, .healthy)
    }

    func testWaitingSignalInTailIsHealthyEvenWhenRunStatusRunning() {
        // The run still reads `.running` but the tail shows a confirmation
        // prompt → the boss should see it as healthy-and-waiting, not stalled.
        let v = SessionHealthProbe.classify(
            runStatus: .running,
            tail: "❯ 1. Yes\n  2. No",
            elapsedSinceStart: 600,
            elapsedSinceOutput: stalled + 100
        )
        XCTAssertEqual(v, .healthy)
    }

    // MARK: - Starting

    func testRunningWithNoOutputYetIsStarting() {
        let v = SessionHealthProbe.classify(
            runStatus: .running,
            tail: "",
            elapsedSinceStart: 1,
            elapsedSinceOutput: nil
        )
        XCTAssertEqual(v, .starting)
    }

    func testRunningWithNilTailWithinGraceIsStarting() {
        let v = SessionHealthProbe.classify(
            runStatus: .running,
            tail: nil,
            elapsedSinceStart: startup - 1,
            elapsedSinceOutput: nil
        )
        XCTAssertEqual(v, .starting)
    }

    func testConfiguredNeverRunIsStarting() {
        // A session that's been (re)created but whose run hasn't produced a
        // status yet is still coming up.
        let v = SessionHealthProbe.classify(
            runStatus: .configured,
            tail: nil,
            elapsedSinceStart: nil,
            elapsedSinceOutput: nil
        )
        XCTAssertEqual(v, .starting)
    }

    func testNoRunAtAllIsStarting() {
        let v = SessionHealthProbe.classify(
            runStatus: nil,
            tail: nil,
            elapsedSinceStart: nil,
            elapsedSinceOutput: nil
        )
        XCTAssertEqual(v, .starting)
    }

    // MARK: - Stalled

    func testRunningWithOutputGoneQuietPastThresholdIsStalled() {
        let v = SessionHealthProbe.classify(
            runStatus: .running,
            tail: "compiling…\nstill compiling…",
            elapsedSinceStart: 600,
            elapsedSinceOutput: stalled + 1
        )
        XCTAssertEqual(v, .stalled)
    }

    func testRunningPastStartupGraceWithNoOutputIsStalled() {
        // It claims to be running but has emitted nothing well past the startup
        // grace — that's a stall, not still-starting.
        let v = SessionHealthProbe.classify(
            runStatus: .running,
            tail: nil,
            elapsedSinceStart: startup + 1,
            elapsedSinceOutput: nil
        )
        XCTAssertEqual(v, .stalled)
    }

    func testOutputExactlyAtThresholdIsStillHealthy() {
        // Boundary: at exactly the threshold the session is not yet stalled.
        let v = SessionHealthProbe.classify(
            runStatus: .running,
            tail: "working",
            elapsedSinceStart: 600,
            elapsedSinceOutput: stalled
        )
        XCTAssertEqual(v, .healthy)
    }

    func testStartupGraceBoundaryIsStarting() {
        // Boundary: at exactly the startup grace with no output, still starting.
        let v = SessionHealthProbe.classify(
            runStatus: .running,
            tail: nil,
            elapsedSinceStart: startup,
            elapsedSinceOutput: nil
        )
        XCTAssertEqual(v, .starting)
    }

    // MARK: - Failed

    func testExitedNonzeroIsFailed() {
        let v = SessionHealthProbe.classify(
            runStatus: .exited,
            tail: "build failed",
            elapsedSinceStart: 30,
            elapsedSinceOutput: 5,
            exitCode: 1
        )
        XCTAssertEqual(v, .failed)
    }

    func testExitedZeroIsHealthy() {
        // A clean exit (code 0) is a successful completion, not a failure — the
        // resumed session ran and finished fine.
        let v = SessionHealthProbe.classify(
            runStatus: .exited,
            tail: "Done.",
            elapsedSinceStart: 30,
            elapsedSinceOutput: 5,
            exitCode: 0
        )
        XCTAssertEqual(v, .healthy)
    }

    func testExitedUnknownCodeIsFailed() {
        // An exit with no recorded code is treated as a failure (the resume
        // didn't stay up) rather than a clean completion.
        let v = SessionHealthProbe.classify(
            runStatus: .exited,
            tail: "",
            elapsedSinceStart: 30,
            elapsedSinceOutput: 5,
            exitCode: nil
        )
        XCTAssertEqual(v, .failed)
    }

    func testNeedsRecoveryIsFailed() {
        let v = SessionHealthProbe.classify(
            runStatus: .needsRecovery,
            tail: "",
            elapsedSinceStart: 30,
            elapsedSinceOutput: 5
        )
        XCTAssertEqual(v, .failed)
    }

    func testManualActionNeededIsFailed() {
        let v = SessionHealthProbe.classify(
            runStatus: .manualActionNeeded,
            tail: "",
            elapsedSinceStart: 30,
            elapsedSinceOutput: 5
        )
        XCTAssertEqual(v, .failed)
    }

    func testTerminalErrorInTailIsFailedEvenWhileRunning() {
        // The run status hasn't caught up, but the tail ended on a fatal error
        // (AttentionSignalDetector → .blocked) → failed.
        let v = SessionHealthProbe.classify(
            runStatus: .running,
            tail: "fatal: not a git repository",
            elapsedSinceStart: 30,
            elapsedSinceOutput: 2
        )
        XCTAssertEqual(v, .failed)
    }

    func testTerminalErrorWinsOverRecentOutput() {
        // Even with fresh output, a terminal error as the last line is a failure.
        let v = SessionHealthProbe.classify(
            runStatus: .running,
            tail: "npm ERR! something broke",
            elapsedSinceStart: 30,
            elapsedSinceOutput: 0
        )
        XCTAssertEqual(v, .failed)
    }

    // MARK: - Convenience overload from a snapshot

    func testProbeFromSnapshotComputesElapsedFromNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = SessionSnapshot(
            id: "s1",
            name: "Resumed",
            owner: SessionOwnerSnapshot(kind: "agent", name: "slugger"),
            kind: "terminalAgent",
            status: ProcessStatus.running.rawValue,
            attention: AttentionState.active.rawValue,
            needsHuman: false,
            trust: "trusted",
            autoResume: false,
            isArchived: false,
            isPinned: false,
            workingDirectory: "/work",
            startedAt: now.addingTimeInterval(-120),
            lastOutputAt: now.addingTimeInterval(-3)
        )

        let v = SessionHealthProbe.classify(snapshot: snapshot, tail: "editing files", now: now)

        XCTAssertEqual(v, .healthy)
    }

    func testProbeFromSnapshotWithStaleOutputIsStalled() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = SessionSnapshot(
            id: "s1",
            name: "Quiet",
            owner: SessionOwnerSnapshot(kind: "agent", name: "slugger"),
            kind: "terminalAgent",
            status: ProcessStatus.running.rawValue,
            attention: AttentionState.active.rawValue,
            needsHuman: false,
            trust: "trusted",
            autoResume: false,
            isArchived: false,
            isPinned: false,
            workingDirectory: "/work",
            startedAt: now.addingTimeInterval(-600),
            lastOutputAt: now.addingTimeInterval(-(stalled + 30))
        )

        let v = SessionHealthProbe.classify(snapshot: snapshot, tail: "compiling", now: now)

        XCTAssertEqual(v, .stalled)
    }

    func testProbeFromSnapshotUnknownStatusRawDecodesToConfiguredStarting() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = SessionSnapshot(
            id: "s1",
            name: "New",
            owner: SessionOwnerSnapshot(kind: "human"),
            kind: "shell",
            status: "some-future-status",
            attention: "idle",
            needsHuman: false,
            trust: "trusted",
            autoResume: false,
            isArchived: false,
            isPinned: false,
            workingDirectory: "/work",
            startedAt: nil,
            lastOutputAt: nil
        )

        let v = SessionHealthProbe.classify(snapshot: snapshot, tail: nil, now: now)

        // Unknown status raw → ProcessStatus decodes to `.configured` → starting.
        XCTAssertEqual(v, .starting)
    }

    func testProbeFromSnapshotExitedNonzeroIsFailed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let snapshot = SessionSnapshot(
            id: "s1",
            name: "Crashed",
            owner: SessionOwnerSnapshot(kind: "human"),
            kind: "shell",
            status: ProcessStatus.exited.rawValue,
            attention: "idle",
            needsHuman: false,
            trust: "trusted",
            autoResume: false,
            isArchived: false,
            isPinned: false,
            exitCode: 2,
            workingDirectory: "/work",
            startedAt: now.addingTimeInterval(-30),
            lastOutputAt: now.addingTimeInterval(-5)
        )

        let v = SessionHealthProbe.classify(snapshot: snapshot, tail: "boom", now: now)

        XCTAssertEqual(v, .failed)
    }

    // MARK: - Verdict metadata

    func testVerdictLabelsAreStableAndGeneral() {
        XCTAssertEqual(SessionHealth.healthy.rawValue, "healthy")
        XCTAssertEqual(SessionHealth.starting.rawValue, "starting")
        XCTAssertEqual(SessionHealth.stalled.rawValue, "stalled")
        XCTAssertEqual(SessionHealth.failed.rawValue, "failed")
    }

    func testVerdictIsCodableRoundTrip() throws {
        for verdict in SessionHealth.allCases {
            let data = try JSONEncoder().encode(verdict)
            let decoded = try JSONDecoder().decode(SessionHealth.self, from: data)
            XCTAssertEqual(decoded, verdict)
        }
    }
}
