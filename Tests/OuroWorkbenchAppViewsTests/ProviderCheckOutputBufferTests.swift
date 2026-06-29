#if os(macOS)
import XCTest
@testable import OuroWorkbenchAppViews

final class ProviderCheckOutputBufferTests: XCTestCase {
    func testAppendAndSnapshotIgnoreEmptyChunks() {
        let buffer = ProviderCheckOutputBuffer()

        buffer.append(Data())
        XCTAssertTrue(buffer.snapshot().isEmpty, "empty chunks are ignored")

        buffer.append(Data("ready".utf8))
        buffer.append(Data("\n".utf8))

        XCTAssertEqual(String(decoding: buffer.snapshot(), as: UTF8.self), "ready\n")
    }

    func testConcurrentAppendsAndSnapshotsPreserveEveryChunk() {
        let buffer = ProviderCheckOutputBuffer()
        let chunkCount = 500

        DispatchQueue.concurrentPerform(iterations: chunkCount) { index in
            buffer.append(Data("chunk-\(index)\n".utf8))
            _ = buffer.snapshot()
        }

        let text = String(decoding: buffer.snapshot(), as: UTF8.self)
        for index in 0..<chunkCount {
            XCTAssertTrue(text.contains("chunk-\(index)\n"), "missing chunk \(index)")
        }
    }
}
#endif
