import XCTest

/// Diagnostic: aborts the test process and prints the offending test name if any
/// single test exceeds a wall-clock budget. Some batch-authored tests do real
/// network / subprocess I/O that wedges on CI but not locally; this surfaces the
/// exact culprit in one run instead of blind cycles. The class name sorts first
/// so its once-per-class `setUp` installs the observer before any other test runs.
final class AAAGlobalTestWatchdog: XCTestCase {
    override class func setUp() {
        super.setUp()
        XCTestObservationCenter.shared.addTestObserver(TestHangWatchdog())
    }

    func testWatchdogInstalled() {
        XCTAssertTrue(true)
    }
}

private final class TestHangWatchdog: NSObject, XCTestObservation, @unchecked Sendable {
    private var pending: DispatchWorkItem?

    func testCaseWillStart(_ testCase: XCTestCase) {
        let name = testCase.name
        let item = DispatchWorkItem {
            FileHandle.standardError.write(Data("\n\n*** HANG WATCHDOG: \(name) exceeded 90s — likely real network/subprocess I/O ***\n\n".utf8))
            exit(73)
        }
        pending = item
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: item)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        pending?.cancel()
        pending = nil
    }
}
