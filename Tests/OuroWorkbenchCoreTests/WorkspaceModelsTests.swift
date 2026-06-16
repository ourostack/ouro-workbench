import XCTest
@testable import OuroWorkbenchCore

final class WorkspaceModelsTests: XCTestCase {
    func testUnknownProcessStatusDecodesToConfigured() throws {
        let decoded = try JSONDecoder().decode(ProcessStatus.self, from: Data(#""future-status""#.utf8))

        XCTAssertEqual(decoded, .configured)
    }

    func testPruneProcessRunsNoOpsForEmptyOrNonPositiveCap() {
        var empty = WorkspaceState(boss: BossAgentSelection(agentName: "slugger"))
        empty.pruneProcessRuns()
        XCTAssertTrue(empty.processRuns.isEmpty)

        let entryId = UUID()
        let run = ProcessRun(entryId: entryId, status: .running, startedAt: Date(timeIntervalSince1970: 1))
        var state = WorkspaceState(boss: BossAgentSelection(agentName: "slugger"), processRuns: [run])
        state.pruneProcessRuns(perEntryCap: 0)
        XCTAssertEqual(state.processRuns, [run], "non-positive caps are ignored rather than deleting all run history")
    }

    func testTrimmedNotesReturnsNilForBlankAndTrimmedTextForContent() {
        let projectID = UUID()
        let blank = ProcessEntry(projectId: projectID, name: "Blank", kind: .shell, executable: "sh", workingDirectory: "/repo", notes: " \n ")
        let content = ProcessEntry(projectId: projectID, name: "Content", kind: .shell, executable: "sh", workingDirectory: "/repo", notes: "  hello  ")

        XCTAssertNil(blank.trimmedNotes)
        XCTAssertEqual(content.trimmedNotes, "hello")
    }
}
