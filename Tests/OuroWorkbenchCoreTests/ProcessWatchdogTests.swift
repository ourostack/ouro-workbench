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
}
