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

    func testDrainSortsByDecodedCreationTimeNotLexicalFilename() throws {
        let root = try temporaryDirectory()
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        let earlier = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            createdAt: Date(timeIntervalSince1970: 2),
            source: "slugger",
            action: BossWorkbenchAction(action: .launch, entry: "Earlier")
        )
        let later = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
            createdAt: Date(timeIntervalSince1970: 10),
            source: "slugger",
            action: BossWorkbenchAction(action: .launch, entry: "Later")
        )

        try queue.enqueue(later)
        try queue.enqueue(earlier)

        XCTAssertEqual(try queue.drain(), [earlier, later])
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

    func testCreateSessionRequestRoundTripsCarryingOwnerAndParams() throws {
        // The agent-initiated createSession request must survive the
        // enqueue → file → drain → decode trip with its owner (agent name) and
        // every launch parameter intact, since the running app reconstructs the
        // ProcessEntry from exactly this payload.
        let root = try temporaryDirectory()
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        let request = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c5")!,
            createdAt: Date(timeIntervalSince1970: 5),
            source: "ouro-workbench-mcp",
            action: BossWorkbenchAction(
                action: .createSession,
                group: "Harness",
                name: "Boss Codex",
                command: "codex --yolo",
                workingDirectory: "/repo",
                trust: .trusted,
                autoResume: true,
                owner: "slugger"
            )
        )

        try queue.enqueue(request)
        let drained = try queue.drain()

        XCTAssertEqual(drained, [request])
        let action = try XCTUnwrap(drained.first?.action)
        XCTAssertEqual(action.action, .createSession)
        XCTAssertEqual(action.owner, "slugger")
        XCTAssertEqual(action.group, "Harness")
        XCTAssertEqual(action.name, "Boss Codex")
        XCTAssertEqual(action.command, "codex --yolo")
        XCTAssertEqual(action.workingDirectory, "/repo")
        XCTAssertEqual(action.trust, .trusted)
        XCTAssertEqual(action.autoResume, true)
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
