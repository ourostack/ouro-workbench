import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class AgentProposalQueueTests: XCTestCase {
    // MARK: - Fixtures

    private func sampleProposal(id: String, title: String = "Bring back your work") -> AgentProposal {
        AgentProposal(
            id: id,
            title: title,
            items: [
                AgentProposalItem(id: "a", label: "First", command: "claude --resume a", selected: true),
                AgentProposalItem(id: "b", label: "Second", command: "copilot --resume b", selected: false),
            ]
        )
    }

    // MARK: - enqueue / pending

    func testEnqueueThenPendingRoundTripsProposal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AgentProposalQueue(directoryURL: root)

        let proposal = sampleProposal(id: "prop-1")
        try queue.enqueue(proposal)

        XCTAssertEqual(queue.pendingProposals(), [proposal])
    }

    func testPendingProposalsAreSortedByIdForDeterminism() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AgentProposalQueue(directoryURL: root)

        try queue.enqueue(sampleProposal(id: "ccc"))
        try queue.enqueue(sampleProposal(id: "aaa"))
        try queue.enqueue(sampleProposal(id: "bbb"))

        XCTAssertEqual(queue.pendingProposals().map(\.id), ["aaa", "bbb", "ccc"])
    }

    func testPendingProposalsOnMissingDirectoryIsEmpty() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentProposalQueueTests-missing-\(UUID().uuidString)", isDirectory: true)
        let queue = AgentProposalQueue(directoryURL: root)

        XCTAssertEqual(queue.pendingProposals(), [])
        XCTAssertNil(queue.readResult(id: "anything"))
    }

    func testMalformedPendingFileIsSkipped() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AgentProposalQueue(directoryURL: root)
        try queue.enqueue(sampleProposal(id: "good"))

        // Drop a non-JSON file with the .json extension into the pending dir.
        let junk = queue.pendingDirectoryURL.appendingPathComponent("garbage.json")
        try Data("not json at all {".utf8).write(to: junk)
        // And a non-.json file that must be ignored entirely.
        try Data("ignored".utf8).write(to: queue.pendingDirectoryURL.appendingPathComponent("note.txt"))

        XCTAssertEqual(queue.pendingProposals().map(\.id), ["good"])
    }

    // MARK: - result write / read

    func testWriteThenReadResultRoundTrips() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AgentProposalQueue(directoryURL: root)

        // The operator's approved decision: only the selected item, edited.
        var proposal = sampleProposal(id: "prop-1")
        proposal.edit(itemID: "a", field: .command, value: "claude --resume EDITED")
        let result = proposal.result()
        try queue.writeResult(result)

        XCTAssertEqual(queue.readResult(id: "prop-1"), result)
        XCTAssertEqual(queue.readResult(id: "prop-1")?.items.first?.command, "claude --resume EDITED")
    }

    func testReadResultForUnknownIdIsNil() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AgentProposalQueue(directoryURL: root)
        try queue.writeResult(sampleProposal(id: "present").result())

        XCTAssertNil(queue.readResult(id: "absent"))
    }

    func testReadResultSkipsMalformedResultFile() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AgentProposalQueue(directoryURL: root)
        // Hand-write a corrupt result file at the id's expected location.
        try FileManager.default.createDirectory(at: queue.resultsDirectoryURL, withIntermediateDirectories: true)
        let corrupt = queue.resultsDirectoryURL.appendingPathComponent("broken.json")
        try Data("}{".utf8).write(to: corrupt)

        XCTAssertNil(queue.readResult(id: "broken"))
    }

    func testWriteResultOverwritesPriorResultForSameId() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AgentProposalQueue(directoryURL: root)

        try queue.writeResult(AgentProposalResult(id: "p", items: [
            AgentProposalItem(id: "x", label: "old", selected: true),
        ]))
        try queue.writeResult(AgentProposalResult(id: "p", items: [
            AgentProposalItem(id: "y", label: "new", selected: true),
        ]))

        XCTAssertEqual(queue.readResult(id: "p")?.items.map(\.id), ["y"])
    }

    // MARK: - removePending

    func testRemovePendingDropsTheProposal() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AgentProposalQueue(directoryURL: root)
        try queue.enqueue(sampleProposal(id: "one"))
        try queue.enqueue(sampleProposal(id: "two"))

        queue.removePending(id: "one")

        XCTAssertEqual(queue.pendingProposals().map(\.id), ["two"])
    }

    func testRemovePendingUnknownIdIsNoOp() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = AgentProposalQueue(directoryURL: root)
        try queue.enqueue(sampleProposal(id: "one"))

        queue.removePending(id: "missing")

        XCTAssertEqual(queue.pendingProposals().map(\.id), ["one"])
    }

    func testRemovePendingOnMissingDirectoryIsNoOp() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentProposalQueueTests-rm-missing-\(UUID().uuidString)", isDirectory: true)
        let queue = AgentProposalQueue(directoryURL: root)
        // Must not throw / crash when nothing exists.
        queue.removePending(id: "anything")
        XCTAssertEqual(queue.pendingProposals(), [])
    }

    // MARK: - convenience init via WorkbenchPaths

    func testConvenienceInitUsesWorkbenchPathsProposalsDirectory() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentProposalQueueTests-\(UUID().uuidString)", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: root)
        XCTAssertEqual(AgentProposalQueue(paths: paths).directoryURL, paths.proposalsURL)
    }

    // MARK: - helper

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentProposalQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
