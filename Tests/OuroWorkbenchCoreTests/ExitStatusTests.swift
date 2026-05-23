import XCTest
@testable import OuroWorkbenchCore

final class ExitStatusTests: XCTestCase {
    func testDecodesNormalWaitStatus() {
        let status = ProcessExitStatus(rawWaitStatus: 256)

        XCTAssertEqual(status.exitCode, 1)
        XCTAssertEqual(status.rawWaitStatus, 256)
    }

    func testSignalTerminationHasNoNormalExitCode() {
        let status = ProcessExitStatus(rawWaitStatus: 2)

        XCTAssertNil(status.exitCode)
        XCTAssertEqual(status.rawWaitStatus, 2)
    }
}
