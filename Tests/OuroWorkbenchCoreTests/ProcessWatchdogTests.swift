import XCTest
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
}
