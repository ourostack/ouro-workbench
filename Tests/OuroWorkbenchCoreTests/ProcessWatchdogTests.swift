import XCTest
import Darwin
@testable import OuroWorkbenchCore

final class ProcessWatchdogTests: XCTestCase {
    private func makeProcess(_ launchPath: String, _ args: [String]) -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    func testWaitReturnsPromptlyForAFastProcess() throws {
        // Fast process exits before the deadline → waitUntilExit returns on its own and
        // the pending kill is cancelled (covers the cancel path).
        let process = makeProcess("/bin/echo", ["ready"])
        try process.run()
        let start = Date()
        ProcessWatchdog.waitUntilExit(process, timeoutSeconds: 10)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testWaitTerminatesAProcessThatExceedsTheDeadline() throws {
        // Slow process still running at the deadline → the watchdog fires and terminates
        // it (covers the watchdog closure + terminateIfRunning's running branch).
        let process = makeProcess("/bin/sleep", ["30"])
        try process.run()
        let start = Date()
        ProcessWatchdog.waitUntilExit(process, timeoutSeconds: 0.3)
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testTerminateIfRunningTerminatesARunningProcess() throws {
        let process = makeProcess("/bin/sleep", ["30"])
        try process.run()
        XCTAssertTrue(process.isRunning)
        ProcessWatchdog.terminateIfRunning(process)
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
    }

    func testTerminateIfRunningIsANoOpForAnExitedProcess() throws {
        // terminate() on an already-exited Process raises; the isRunning guard must skip it.
        let process = makeProcess("/bin/echo", ["done"])
        try process.run()
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
        ProcessWatchdog.terminateIfRunning(process)
        XCTAssertFalse(process.isRunning)
    }

    // MARK: - F7 — waitUntilExitReportingTimeout (B-1 structural defense)

    func testReportingVariantReturnsTrueAndTerminatesAWedgedProcess() throws {
        // A real sleeper still running at the deadline → the watchdog FIRES, terminates it, and the
        // method reports `true`. This is the load-bearing distinction that lets the runner return
        // `.timedOut` (a wedge) BEFORE reading the kill's `terminationStatus` (B-1): a watchdog kill
        // is otherwise indistinguishable from a real non-zero git failure.
        let process = makeProcess("/bin/sleep", ["30"])
        try process.run()
        let start = Date()
        let timedOut = ProcessWatchdog.waitUntilExitReportingTimeout(process, timeoutSeconds: 0.3)
        XCTAssertTrue(timedOut, "the watchdog fired on a wedged child — must report true")
        XCTAssertFalse(process.isRunning, "the wedged child must be terminated")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testReportingVariantReturnsFalseForAFastProcess() throws {
        // A fast process exits on its own before the deadline → the watchdog never fires and the
        // method reports `false` (the runner then trusts `terminationStatus`). Covers the
        // did-NOT-fire branch of the NSLock-guarded flag.
        let process = makeProcess("/bin/echo", ["ready"])
        try process.run()
        let start = Date()
        let timedOut = ProcessWatchdog.waitUntilExitReportingTimeout(process, timeoutSeconds: 10)
        XCTAssertFalse(timedOut, "a fast process never trips the watchdog — must report false")
        XCTAssertFalse(process.isRunning)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    // MARK: - F8 — SIGTERM→grace→SIGKILL escalation (injected fake deliverer)

    /// Records every `(pid, signal)` the escalation delivers, so the orchestration is
    /// covered deterministically without depending on a child that ignores SIGTERM.
    private final class RecordingDeliverer: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(pid: pid_t, signal: Int32)] = []
        var calls: [(pid: pid_t, signal: Int32)] {
            lock.lock(); defer { lock.unlock() }
            return _calls
        }
        func deliver(_ pid: pid_t, _ signal: Int32) {
            lock.lock(); _calls.append((pid, signal)); lock.unlock()
        }
    }

    func testEscalationSendsTermThenKillToChildWhenSigtermIgnored() throws {
        // A child that IGNORES SIGTERM (the FAKE deliverer is a no-op, so the real child keeps
        // running through the grace window) must record exactly: one SIGTERM, then one SIGKILL —
        // both targeting the CHILD pid, never a process group. This is the escalation that
        // defends against a wedged child hanging forever. Driving escalateTermination directly
        // (not the full blocking waitUntilExit) keeps it deterministic: a no-op fake can't reap
        // the real child, so the outer process.waitUntilExit() would otherwise block the full 30s.
        let process = makeProcess("/bin/sleep", ["30"])
        try process.run()
        let pid = process.processIdentifier
        let rec = RecordingDeliverer()
        let start = Date()
        ProcessWatchdog.escalateTermination(
            process,
            gracePeriodSeconds: 0.2,
            signalDeliverer: { rec.deliver($0, $1) }
        )
        // The fake never actually killed the child — reap it ourselves to keep the test clean.
        process.terminate()
        process.waitUntilExit()

        let calls = rec.calls
        XCTAssertEqual(calls.count, 2, "expected exactly SIGTERM then SIGKILL, got \(calls)")
        XCTAssertEqual(calls.first?.signal, SIGTERM, "first signal must be SIGTERM")
        XCTAssertEqual(calls.last?.signal, SIGKILL, "second signal must be SIGKILL")
        XCTAssertEqual(calls.last?.pid, pid, "SIGKILL must target the CHILD pid (never killpg)")
        XCTAssertTrue(calls.allSatisfy { $0.pid > 0 }, "every signal targets a concrete child pid, never a group")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testEscalationDeliversNoSignalsForAnAlreadyExitedChild() throws {
        // The watchdog's deadline closure runs escalateTermination; if the child already exited
        // (it raced the deadline), the captured-while-running guard must deliver NOTHING.
        let process = makeProcess("/bin/echo", ["ready"])
        try process.run()
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
        let rec = RecordingDeliverer()
        ProcessWatchdog.escalateTermination(
            process,
            gracePeriodSeconds: 0.2,
            signalDeliverer: { rec.deliver($0, $1) }
        )
        XCTAssertEqual(rec.calls.count, 0, "an already-exited child must trigger no escalation signals")
    }

    func testWaitDeliversNoEscalationSignalsWhenChildExitsBeforeDeadline() throws {
        // End-to-end via the public wait: a fast child exits before the deadline → the watchdog
        // is cancelled → the fake deliverer records NOTHING. The cancel path must beat escalation.
        let process = makeProcess("/bin/echo", ["ready"])
        try process.run()
        let rec = RecordingDeliverer()
        ProcessWatchdog.waitUntilExit(
            process,
            timeoutSeconds: 10,
            gracePeriodSeconds: 0.2,
            signalDeliverer: { rec.deliver($0, $1) }
        )
        XCTAssertFalse(process.isRunning)
        // Give any (erroneously-scheduled) escalation a moment to prove it does NOT fire.
        let settle = expectation(description: "settle")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
        XCTAssertEqual(rec.calls.count, 0, "a fast-exiting child must trigger no escalation signals")
    }

    func testEscalationStopsAtSigtermWhenChildExitsDuringGrace() throws {
        // Child exits on its own during the grace window (real SIGTERM via the default deliverer
        // reaps /bin/sleep) → the SIGKILL stage must re-check isRunning and NOT fire a second
        // signal. The tee deliverer records AND really kills, so SIGTERM genuinely lands.
        let process = makeProcess("/bin/sleep", ["30"])
        try process.run()
        let rec = RecordingDeliverer()
        ProcessWatchdog.escalateTermination(
            process,
            gracePeriodSeconds: 1.5,
            signalDeliverer: { pid, sig in rec.deliver(pid, sig); kill(pid, sig) }
        )
        process.waitUntilExit()
        XCTAssertFalse(process.isRunning)
        let calls = rec.calls
        XCTAssertEqual(calls.first?.signal, SIGTERM)
        XCTAssertFalse(
            calls.contains { $0.signal == SIGKILL },
            "the child exited during grace → the SIGKILL stage must skip (isRunning re-check), got \(calls)"
        )
    }

    // MARK: - F8b — latent gated group-reap arm
    //
    // The REAL killpg mechanism (that `.killGroup` would deliver in production) is proven
    // against own-group children in SpawnInOwnGroupTests (the grandchild-reap proof) and the
    // ProcessIOBox default-killpg test. Here the group deliverer is a FAKE: a real killpg of a
    // `Process` (which always shares Workbench's group) would reap the test runner, so the
    // routing is asserted via an injected recorder.

    func testEscalationGroupReapsAnOwnGroupChildPastGrace() throws {
        // F8b: a child explicitly flagged `childInOwnGroup: true` that survives SIGTERM through
        // grace → the post-grace SIGKILL routes through the GROUP deliverer (killpg), NOT the
        // child-only one. This is the latent arm — no production ProcessWatchdog caller opts in
        // yet, but the mechanism is reachable + covered.
        let process = makeProcess("/bin/sleep", ["30"])
        try process.run()
        let pid = process.processIdentifier
        let childRec = RecordingDeliverer()
        let groupRec = RecordingDeliverer()
        ProcessWatchdog.escalateTermination(
            process,
            gracePeriodSeconds: 0.2,
            signalDeliverer: { childRec.deliver($0, $1) },
            childInOwnGroup: true,
            groupSignalDeliverer: { groupRec.deliver($0, $1) }
        )
        // The fakes never reaped the real child — clean it up.
        process.terminate()
        process.waitUntilExit()

        // SIGTERM still goes through the child-only deliverer (the polite first ask).
        XCTAssertEqual(childRec.calls.first?.signal, SIGTERM, "SIGTERM must precede the group reap")
        XCTAssertFalse(
            childRec.calls.contains { $0.signal == SIGKILL },
            "an own-group child must NOT receive a child-only SIGKILL — the group reap takes over"
        )
        // The post-grace SIGKILL goes through the GROUP deliverer.
        XCTAssertEqual(groupRec.calls.count, 1, "expected exactly one group SIGKILL, got \(groupRec.calls)")
        XCTAssertEqual(groupRec.calls.first?.signal, SIGKILL)
        XCTAssertEqual(groupRec.calls.first?.pid, pid)
    }

    func testEscalationChildOnlyDefaultDoesNotGroupReap() throws {
        // The DEFAULT (childInOwnGroup: false) — every current caller — must SIGKILL the child
        // pid only and NEVER touch the group deliverer.
        let process = makeProcess("/bin/sleep", ["30"])
        try process.run()
        let pid = process.processIdentifier
        let childRec = RecordingDeliverer()
        let groupRec = RecordingDeliverer()
        ProcessWatchdog.escalateTermination(
            process,
            gracePeriodSeconds: 0.2,
            signalDeliverer: { childRec.deliver($0, $1) },
            childInOwnGroup: false,
            groupSignalDeliverer: { groupRec.deliver($0, $1) }
        )
        process.terminate()
        process.waitUntilExit()

        XCTAssertEqual(childRec.calls.last?.signal, SIGKILL, "child-only default must SIGKILL the child pid")
        XCTAssertEqual(childRec.calls.last?.pid, pid)
        XCTAssertEqual(groupRec.calls.count, 0, "the child-only default must NEVER killpg")
    }

    // MARK: - F8b — source-pin the group-reap is GATED (can't ungate)

    /// INVERTED F8 pin. F8b adds the killpg arm, but it is GATED: `killpg` is only ever reached
    /// via the `.killGroup` case of `WatchdogEscalation.nextSignal`, which returns `.killGroup`
    /// IFF `childInOwnGroup` is true. The default for every current caller is `false`, so a plain
    /// `Process()` (shared group) can never be group-reaped. This pins that the killpg is wired
    /// through the gate (not an ungated raw `killpg(pid, …)` on the escalation's main path).
    func testProcessWatchdogGroupReapIsGatedOnOwnGroup() throws {
        let source = try processWatchdogSource()
        // The killpg arm exists now (F8b).
        XCTAssertTrue(source.contains("killpg"), "F8b adds the group-reap arm")
        // It is gated on the .killGroup case (the policy returns that IFF childInOwnGroup).
        XCTAssertTrue(
            source.contains("case .killGroup"),
            "the group reap must be reached only through the .killGroup policy case (the gate)"
        )
        XCTAssertTrue(
            source.contains("childInOwnGroup"),
            "escalateTermination must take the childInOwnGroup gate flag"
        )
        // The child-only SIGKILL is still the default arm.
        XCTAssertTrue(
            source.contains("signalDeliverer(pid, SIGKILL)"),
            "the default (non-own-group) arm must SIGKILL the CHILD pid through the injected deliverer"
        )
        // The gate flag defaults to false → no current caller opts in.
        XCTAssertTrue(
            source.contains("childInOwnGroup: Bool = false"),
            "the gate must default to false so finite-runner callers stay child-only"
        )
    }

    private func processWatchdogSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
            .appendingPathComponent("OuroWorkbenchCore")
            .appendingPathComponent("ProcessWatchdog.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }
}
