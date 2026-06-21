import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchActionResultTests: XCTestCase {
    private let classifier = WorkbenchActionResultClassifier()

    func testStillQueuedReadsAsQueuedNotReady() {
        let readback = classifier.readback(requestId: "req-1", stillQueued: true, logEntry: nil)
        XCTAssertEqual(readback.state, .queued)
        XCTAssertNil(readback.result)
        XCTAssertNil(readback.succeeded)
    }

    func testQueuedWinsOverAStaleLogEntry() {
        // The queue is the live truth: a request still in flight is `queued` even
        // if a log entry with the same id somehow exists.
        let entry = WorkbenchActionLogEntry(source: "external", action: "recover", result: "ok", succeeded: true)
        let readback = classifier.readback(requestId: "req-1", stillQueued: true, logEntry: entry)
        XCTAssertEqual(readback.state, .queued)
    }

    func testAppliedResolvesFromASucceededLogEntry() {
        let entry = WorkbenchActionLogEntry(source: "external", action: "recover", result: "Recovered Build", succeeded: true)
        let readback = classifier.readback(requestId: "req-2", stillQueued: false, logEntry: entry)
        XCTAssertEqual(readback.state, .applied)
        XCTAssertEqual(readback.result, "Recovered Build")
        XCTAssertEqual(readback.succeeded, true)
    }

    func testFailedResolvesFromAFailedLogEntry() {
        let entry = WorkbenchActionLogEntry(source: "external", action: "recover", result: "Skipped recover: not authorized", succeeded: false)
        let readback = classifier.readback(requestId: "req-3", stillQueued: false, logEntry: entry)
        XCTAssertEqual(readback.state, .failed)
        XCTAssertEqual(readback.result, "Skipped recover: not authorized")
        XCTAssertEqual(readback.succeeded, false)
    }

    func testUnknownWhenNeitherQueuedNorLogged() {
        let readback = classifier.readback(requestId: "nope", stillQueued: false, logEntry: nil)
        XCTAssertEqual(readback.state, .unknown)
        XCTAssertNil(readback.result)
        XCTAssertNil(readback.succeeded)
    }

    func testLogEntryCarriesRequestIdKey() {
        // The action-log entry shares the requestId key with the boss's queued
        // request so request and outcome are attributable (#U24).
        let requestId = UUID()
        let entry = WorkbenchActionLogEntry(
            source: "external:ouro",
            action: "recover",
            result: "Recovered",
            succeeded: true,
            requestId: requestId
        )
        XCTAssertEqual(entry.requestId, requestId)
    }

    func testRequestIdDecodesAbsentAsNilForPreU24State() throws {
        // A pre-U24 log entry has no `requestId` key; it must decode as nil so old
        // logs load unchanged.
        let json = """
        {"id":"\(UUID().uuidString)","occurredAt":0,"source":"op","action":"launch","result":"ok","succeeded":true}
        """
        let decoder = JSONDecoder()
        let entry = try decoder.decode(WorkbenchActionLogEntry.self, from: Data(json.utf8))
        XCTAssertNil(entry.requestId)
    }
}

final class WorkbenchActionRequestQueueReadbackTests: XCTestCase {
    private func makeQueue() -> (WorkbenchActionRequestQueue, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wb-queue-\(UUID().uuidString)", isDirectory: true)
        return (WorkbenchActionRequestQueue(directoryURL: dir), dir)
    }

    private func request() -> WorkbenchActionRequest {
        WorkbenchActionRequest(source: "test", action: BossWorkbenchAction(action: .recover, entry: "abc"))
    }

    func testPendingRequestIsInFlight() throws {
        let (queue, dir) = makeQueue()
        defer { try? FileManager.default.removeItem(at: dir) }
        let req = request()
        try queue.enqueue(req)
        XCTAssertTrue(queue.isPendingOrProcessing(requestId: req.id))
    }

    func testProcessingRequestIsInFlight() throws {
        let (queue, dir) = makeQueue()
        defer { try? FileManager.default.removeItem(at: dir) }
        let req = request()
        try queue.enqueue(req)
        // drain() moves the file into processing/ — still in flight until confirmed.
        _ = try queue.drain()
        XCTAssertTrue(queue.isPendingOrProcessing(requestId: req.id))
    }

    func testConfirmedRequestIsNotInFlight() throws {
        let (queue, dir) = makeQueue()
        defer { try? FileManager.default.removeItem(at: dir) }
        let req = request()
        try queue.enqueue(req)
        _ = try queue.drain()
        queue.confirmApplied(req.id)
        XCTAssertFalse(queue.isPendingOrProcessing(requestId: req.id))
    }

    func testUnknownRequestIsNotInFlight() {
        let (queue, dir) = makeQueue()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(queue.isPendingOrProcessing(requestId: UUID()))
    }
}
