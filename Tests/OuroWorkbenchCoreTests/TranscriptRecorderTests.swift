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
}
