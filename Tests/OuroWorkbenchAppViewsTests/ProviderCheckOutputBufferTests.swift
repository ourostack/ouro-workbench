#if os(macOS)
import XCTest
@testable import OuroWorkbenchAppViews

final class ProviderCheckOutputBufferTests: XCTestCase {
    func testAppendAndSnapshotAreThreadSafeAndIgnoreEmptyChunks() {
        let buffer = ProviderCheckOutputBuffer()

        buffer.append(Data())
        XCTAssertTrue(buffer.snapshot().isEmpty, "empty chunks are ignored")

        buffer.append(Data("ready".utf8))
        buffer.append(Data("\n".utf8))

        XCTAssertEqual(String(decoding: buffer.snapshot(), as: UTF8.self), "ready\n")
    }
}
#endif
