import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchActionRequestQueueTests: XCTestCase {
    func testQueueRoundTripsAndDrainsRequestsInFileOrder() throws {
        let root = try temporaryDirectory()
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        let first = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1),
            source: "slugger",
            action: BossWorkbenchAction(action: .launch, entry: "Claude Code")
        )
        let second = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            createdAt: Date(timeIntervalSince1970: 2),
            source: "slugger",
            action: BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "continue")
        )

        try queue.enqueue(second)
        try queue.enqueue(first)

        XCTAssertEqual(try queue.drain(), [first, second])
        XCTAssertEqual(try queue.drain(), [])
        try? FileManager.default.removeItem(at: root)
    }

    func testDrainQuarantinesMalformedRequestsAndContinues() throws {
        let root = try temporaryDirectory()
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        let badURL = root.appendingPathComponent("0-bad.json")
        try Data("{".utf8).write(to: badURL)
        let valid = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            createdAt: Date(timeIntervalSince1970: 1),
            source: "slugger",
            action: BossWorkbenchAction(action: .launch, entry: "OpenAI Codex")
        )
        try queue.enqueue(valid)

        XCTAssertEqual(try queue.drain(), [valid])
        XCTAssertFalse(FileManager.default.fileExists(atPath: badURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.rejectedDirectoryURL.appendingPathComponent(badURL.lastPathComponent).path))
        XCTAssertEqual(try queue.drain(), [])
        try? FileManager.default.removeItem(at: root)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
