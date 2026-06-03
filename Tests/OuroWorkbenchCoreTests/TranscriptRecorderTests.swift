import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class TranscriptRecorderTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("transcript.log")
    }

    func testAppendWritesBytes() throws {
        let url = tempURL()
        let recorder = try TranscriptRecorder(url: url)
        recorder.append(ArraySlice(Array("hello ".utf8)))
        recorder.append(ArraySlice(Array("world".utf8)))
        recorder.close()

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, "hello world")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testAppendAfterCloseIsANoOpAndDoesNotCrash() throws {
        let url = tempURL()
        let recorder = try TranscriptRecorder(url: url)
        recorder.append(ArraySlice(Array("before".utf8)))
        recorder.close()
        // Must not throw or crash — the handle is nil after close.
        recorder.append(ArraySlice(Array("after".utf8)))

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, "before")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// The writes happen asynchronously on a private serial queue now, so this
    /// guards that the serial/FIFO ordering is preserved: many chunks appended
    /// back-to-back from the caller must land on disk in the same order.
    func testManyAppendsPreserveOrderAcrossAsyncQueue() throws {
        let url = tempURL()
        let recorder = try TranscriptRecorder(url: url)
        let chunks = (0..<500).map { "chunk-\($0);" }
        for chunk in chunks {
            recorder.append(ArraySlice(Array(chunk.utf8)))
        }
        // close() drains the queue synchronously, so every enqueued write has
        // landed by the time it returns.
        recorder.close()

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, chunks.joined())
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    /// A chunk appended immediately before `close()` must be flushed, not lost:
    /// the append enqueues asynchronously and `close()` drains the queue before
    /// tearing down the handle, so a quit captures outstanding bytes.
    func testAppendImmediatelyBeforeCloseIsFlushedNotLost() throws {
        let url = tempURL()
        let recorder = try TranscriptRecorder(url: url)
        recorder.append(ArraySlice(Array("pending-on-quit".utf8)))
        recorder.close()

        let written = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(written, "pending-on-quit")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}
