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

    func testDrainingMissingDirectoryAndPendingCountAreEmpty() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let queue = WorkbenchActionRequestQueue(directoryURL: root)

        XCTAssertEqual(try queue.drain(), [])
        XCTAssertEqual(queue.pendingCount(), 0)
        XCTAssertEqual(queue.recoverUnconfirmed(), [])
    }

    func testConvenienceInitUsesWorkbenchPathsActionRequestDirectory() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkbenchActionRequestQueueTests-\(UUID().uuidString)", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: root)
        XCTAssertEqual(WorkbenchActionRequestQueue(paths: paths).directoryURL, paths.actionRequestsURL)
    }

    func testPendingCountFallsBackToZeroWhenQueuePathIsNotDirectory() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("requests")
        try Data("not a directory".utf8).write(to: fileURL)

        XCTAssertEqual(WorkbenchActionRequestQueue(directoryURL: fileURL).pendingCount(), 0)
    }

    func testDuplicateCheckReturnsFalseWhenPendingDirectoryCannotBeListed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("requests")
        try Data("not a directory".utf8).write(to: fileURL)
        let request = WorkbenchActionRequest(source: "slugger", action: BossWorkbenchAction(action: .launch, entry: "Claude"))

        XCTAssertFalse(WorkbenchActionRequestQueue(directoryURL: fileURL).hasPendingDuplicate(of: request))
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

    func testDrainTieBreaksSameCreationTimeByRequestID() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        let laterID = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000ff")!,
            createdAt: Date(timeIntervalSince1970: 1),
            source: "slugger",
            action: BossWorkbenchAction(action: .launch, entry: "Later ID")
        )
        let earlierID = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            createdAt: Date(timeIntervalSince1970: 1),
            source: "slugger",
            action: BossWorkbenchAction(action: .launch, entry: "Earlier ID")
        )

        try queue.enqueue(laterID)
        try queue.enqueue(earlierID)

        XCTAssertEqual(try queue.drain().map(\.id), [earlierID.id, laterID.id])
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

    func testQuarantineRemovesMalformedFileWhenRejectedPathCannotBeCreated() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        try Data("not a directory".utf8).write(to: queue.rejectedDirectoryURL)
        let badURL = root.appendingPathComponent("bad.json")
        try Data("{".utf8).write(to: badURL)

        XCTAssertEqual(try queue.drain(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: badURL.path))
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

    func testEnqueueDropsDuplicateFingerprintWhilePendingSoDrainReturnsOne() throws {
        // A reasoning boss can return an empty FINAL reply *after* it already
        // called workbench_request_action; the empty-retry then runs a fresh
        // turn that re-enqueues the same action. The queue must treat the second
        // (identical-fingerprint) enqueue as a no-op so the action drains once.
        let root = try temporaryDirectory()
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        let first = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a1")!,
            createdAt: Date(timeIntervalSince1970: 1),
            source: "ouro-workbench-mcp",
            action: BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "continue")
        )
        // Same effect, different id/createdAt/source — the dup the retry would write.
        let duplicate = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000a2")!,
            createdAt: Date(timeIntervalSince1970: 2),
            source: "boss:slugger",
            action: BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "continue")
        )

        try queue.enqueue(first)
        try queue.enqueue(duplicate)

        let drained = try queue.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained.first?.id, first.id)
        XCTAssertEqual(try queue.drain(), [])
        try? FileManager.default.removeItem(at: root)
    }

    func testAppendNewlineParticipatesInDuplicateFingerprint() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        let withNewline = WorkbenchActionRequest(
            createdAt: Date(timeIntervalSince1970: 1),
            source: "ouro-workbench-mcp",
            action: BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "continue", appendNewline: true)
        )
        let withoutNewline = WorkbenchActionRequest(
            createdAt: Date(timeIntervalSince1970: 2),
            source: "ouro-workbench-mcp",
            action: BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "continue", appendNewline: false)
        )

        try queue.enqueue(withNewline)
        try queue.enqueue(withoutNewline)

        XCTAssertEqual(try queue.drain().map(\.action.appendNewline), [true, false])
    }

    func testEnqueueKeepsRequestsThatDifferOnlyByAFingerprintField() throws {
        // Dedup must key on the *effect*: a one-character difference in any
        // fingerprint field (here `text`) is a genuinely different action and
        // must NOT be dropped.
        let root = try temporaryDirectory()
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        let sendContinue = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b1")!,
            createdAt: Date(timeIntervalSince1970: 1),
            source: "ouro-workbench-mcp",
            action: BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "continue")
        )
        let sendStop = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000b2")!,
            createdAt: Date(timeIntervalSince1970: 2),
            source: "ouro-workbench-mcp",
            action: BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "stop")
        )

        try queue.enqueue(sendContinue)
        try queue.enqueue(sendStop)

        XCTAssertEqual(try queue.drain().count, 2)
        try? FileManager.default.removeItem(at: root)
    }

    func testDrainMovesFilesToProcessingAndConfirmApplyDeletesThem() throws {
        // drain() converts at-most-once-with-loss to at-least-once: it MOVES
        // each request file into processing/ (queue empties, processing holds
        // them) instead of deleting, so a crash before apply can recover. Only
        // confirmApplied(id) — called after the app applies a request — deletes
        // the processing/ file. A request enqueued after the drain is untouched.
        let root = try temporaryDirectory()
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        let launch = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c1")!,
            createdAt: Date(timeIntervalSince1970: 1),
            source: "ouro-workbench-mcp",
            action: BossWorkbenchAction(action: .launch, entry: "Claude Code")
        )
        let sendInput = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c2")!,
            createdAt: Date(timeIntervalSince1970: 2),
            source: "ouro-workbench-mcp",
            action: BossWorkbenchAction(action: .sendInput, entry: "Claude Code", text: "go")
        )
        try queue.enqueue(launch)
        try queue.enqueue(sendInput)

        let drained = try queue.drain()
        XCTAssertEqual(drained.map(\.id), [launch.id, sendInput.id])

        // Queue dir holds no pending .json; processing/ holds both, named by id.
        XCTAssertEqual(pendingJSONFileNames(in: root), [])
        XCTAssertEqual(
            Set(processingJSONFileNames(in: queue)),
            ["\(launch.id.uuidString).json", "\(sendInput.id.uuidString).json"]
        )
        // Draining again returns nothing (files are in processing, not pending).
        XCTAssertEqual(try queue.drain(), [])

        // Confirm one applied → only its processing file is removed; the other
        // remains as still-unconfirmed.
        queue.confirmApplied(launch.id)
        XCTAssertEqual(
            processingJSONFileNames(in: queue),
            ["\(sendInput.id.uuidString).json"]
        )
        XCTAssertEqual(queue.recoverUnconfirmed().map(\.id), [sendInput.id])

        // A distinct request enqueued after the drain is unaffected by the
        // processing/recover machinery: it drains normally.
        let later = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000c3")!,
            createdAt: Date(timeIntervalSince1970: 3),
            source: "ouro-workbench-mcp",
            action: BossWorkbenchAction(action: .launch, entry: "OpenAI Codex")
        )
        try queue.enqueue(later)
        XCTAssertEqual(try queue.drain().map(\.id), [later.id])
        // recoverUnconfirmed still surfaces the earlier unconfirmed sendInput
        // plus the just-drained `later` (both now in processing).
        XCTAssertEqual(
            Set(queue.recoverUnconfirmed().map(\.id)),
            [sendInput.id, later.id]
        )

        // Confirming the remaining two empties processing/ entirely.
        queue.confirmApplied(sendInput.id)
        queue.confirmApplied(later.id)
        XCTAssertEqual(queue.recoverUnconfirmed(), [])
        try? FileManager.default.removeItem(at: root)
    }

    func testDrainReplacesStaleProcessingFileForSameRequestID() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        let request = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000d1")!,
            createdAt: Date(timeIntervalSince1970: 1),
            source: "ouro-workbench-mcp",
            action: BossWorkbenchAction(action: .launch, entry: "Claude Code")
        )
        try FileManager.default.createDirectory(at: queue.processingDirectoryURL, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: queue.processingDirectoryURL.appendingPathComponent("\(request.id.uuidString).json"))
        try queue.enqueue(request)

        XCTAssertEqual(try queue.drain(), [request])
        XCTAssertEqual(queue.recoverUnconfirmed(), [request])
    }

    func testRecoverUnconfirmedQuarantinesMalformedProcessingFilesAndSortsByID() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        try FileManager.default.createDirectory(at: queue.processingDirectoryURL, withIntermediateDirectories: true)
        let badURL = queue.processingDirectoryURL.appendingPathComponent("bad.json")
        try Data("{".utf8).write(to: badURL)
        let second = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000e2")!,
            createdAt: Date(timeIntervalSince1970: 1),
            source: "mcp",
            action: BossWorkbenchAction(action: .launch, entry: "Second")
        )
        let first = WorkbenchActionRequest(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000e1")!,
            createdAt: Date(timeIntervalSince1970: 1),
            source: "mcp",
            action: BossWorkbenchAction(action: .launch, entry: "First")
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(second).write(to: queue.processingDirectoryURL.appendingPathComponent("second.json"))
        try encoder.encode(first).write(to: queue.processingDirectoryURL.appendingPathComponent("first.json"))

        XCTAssertEqual(queue.recoverUnconfirmed().map(\.id), [first.id, second.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: badURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: queue.rejectedDirectoryURL.appendingPathComponent("bad.json").path))
    }

    func testQuarantineAvoidsOverwritingExistingRejectedFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: queue.rejectedDirectoryURL, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: queue.rejectedDirectoryURL.appendingPathComponent("bad.json"))
        try Data("{".utf8).write(to: root.appendingPathComponent("bad.json"))

        XCTAssertEqual(try queue.drain(), [])
        let rejected = try FileManager.default.contentsOfDirectory(at: queue.rejectedDirectoryURL, includingPropertiesForKeys: nil)
            .map(\.lastPathComponent)

        XCTAssertEqual(rejected.count, 2)
        XCTAssertTrue(rejected.contains("bad.json"))
        XCTAssertTrue(rejected.contains { $0.hasSuffix("-bad.json") })
    }

    func testRecoverUnconfirmedReturnsNothingWhenProcessingIsEmptyOrAbsent() throws {
        let root = try temporaryDirectory()
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        // No drain has happened, so processing/ doesn't exist yet.
        XCTAssertEqual(queue.recoverUnconfirmed(), [])
    }

    func testRecoverUnconfirmedReturnsEmptyWhenProcessingPathCannotBeListed() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = WorkbenchActionRequestQueue(directoryURL: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: queue.processingDirectoryURL)

        XCTAssertEqual(queue.recoverUnconfirmed(), [])
        try? FileManager.default.removeItem(at: root)
    }

    private func pendingJSONFileNames(in root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .map(\.lastPathComponent)
            .sorted()
    }

    private func processingJSONFileNames(in queue: WorkbenchActionRequestQueue) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(at: queue.processingDirectoryURL, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
            .map(\.lastPathComponent)
            .sorted()
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
