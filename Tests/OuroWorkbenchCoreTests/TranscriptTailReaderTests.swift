import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class TranscriptTailReaderTests: XCTestCase {
    func testMissingTranscriptReturnsNil() {
        let tail = TranscriptTailReader(maxBytes: 100).read(path: "/tmp/missing-\(UUID().uuidString).log")

        XCTAssertNil(tail)
    }

    func testReadsWholeTranscriptWhenUnderLimit() throws {
        let url = try transcript(contents: "hello\nworld\n")

        let tail = try XCTUnwrap(TranscriptTailReader(maxBytes: 100).read(path: url.path))

        XCTAssertEqual(tail.path, url.path)
        XCTAssertEqual(tail.text, "hello\nworld\n")
        XCTAssertFalse(tail.truncated)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testReadsTailWhenTranscriptExceedsLimit() throws {
        let url = try transcript(contents: "0123456789abcdef")

        let tail = try XCTUnwrap(TranscriptTailReader(maxBytes: 6).read(path: url.path))

        XCTAssertEqual(tail.text, "abcdef")
        XCTAssertTrue(tail.truncated)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testReadsTailWithoutANSIEscapeCodes() throws {
        let url = try transcript(contents: "\u{001B}[32mready\u{001B}[0m\n")

        let tail = try XCTUnwrap(TranscriptTailReader(maxBytes: 100).read(path: url.path))

        XCTAssertEqual(tail.text, "ready\n")
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    func testTranscriptTailLimitClampsCallerProvidedValues() {
        XCTAssertEqual(TranscriptTailLimit.clamped(nil), 12_000)
        XCTAssertEqual(TranscriptTailLimit.clamped(40_000), 40_000)
        XCTAssertEqual(TranscriptTailLimit.clamped(1_000_000), 64_000)
    }

    private func transcript(contents: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("transcript.log")
        try contents.data(using: .utf8)?.write(to: url)
        return url
    }
}
