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

    // MARK: - Forward memory (Slice 6)

    func testProcessEntryForwardMemoryDefaultsToNil() {
        // A session Workbench created without provenance carries no forward
        // memory — both discovery fields default to nil.
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Plain",
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/repo"
        )

        XCTAssertNil(entry.discoveredHarness)
        XCTAssertNil(entry.discoveredSessionId)
    }

    func testProcessEntryForwardMemoryRoundTripsWithValues() throws {
        // When Workbench owns the launch it stamps the originating harness +
        // sessionId so the next scan() native path can find it again. These
        // survive encode → decode unchanged.
        let original = ProcessEntry(
            projectId: UUID(),
            name: "From discovery",
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/repo",
            discoveredHarness: .claudeCode,
            discoveredSessionId: "abc-123"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProcessEntry.self, from: data)

        XCTAssertEqual(decoded.discoveredHarness, .claudeCode)
        XCTAssertEqual(decoded.discoveredSessionId, "abc-123")
        XCTAssertEqual(decoded, original)
    }

    func testProcessEntryDecodesLegacyJSONWithoutForwardMemoryFields() throws {
        // Backward-compat: a persisted entry written before Slice 6 has neither
        // `discoveredHarness` nor `discoveredSessionId`. It must still decode,
        // leaving both nil (decode-if-present), so workspace-state.json loads.
        let legacy = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "projectId": "00000000-0000-0000-0000-000000000002",
            "name": "Legacy",
            "kind": "terminalAgent",
            "executable": "claude",
            "arguments": [],
            "workingDirectory": "/repo",
            "trust": "trusted",
            "autoResume": false
        }
        """

        let decoded = try JSONDecoder().decode(ProcessEntry.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.discoveredHarness)
        XCTAssertNil(decoded.discoveredSessionId)
        XCTAssertEqual(decoded.name, "Legacy")
    }

    func testProcessEntryAttentionReasonDefaultsToNil() {
        // A fresh entry carries no attention reason until the detector derives one.
        let entry = ProcessEntry(
            projectId: UUID(),
            name: "Plain",
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/repo"
        )
        XCTAssertNil(entry.attentionReason)
    }

    func testProcessEntryAttentionReasonRoundTrips() throws {
        // The "why" line the detector derived survives encode → decode so the
        // boss snapshot and the header banner read the same persisted string.
        let original = ProcessEntry(
            projectId: UUID(),
            name: "Waiting",
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/repo",
            attention: .waitingOnHuman,
            attentionReason: "Do you want to make this edit?"
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProcessEntry.self, from: data)

        XCTAssertEqual(decoded.attentionReason, "Do you want to make this edit?")
        XCTAssertEqual(decoded, original)
    }

    func testProcessEntryDecodesLegacyJSONWithoutAttentionReason() throws {
        // Backward-compat: a persisted entry written before U10 has no
        // `attentionReason` key. It must still decode, leaving the field nil.
        let legacy = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "projectId": "00000000-0000-0000-0000-000000000002",
            "name": "Legacy",
            "kind": "terminalAgent",
            "executable": "claude",
            "arguments": [],
            "workingDirectory": "/repo",
            "trust": "trusted",
            "autoResume": false,
            "attention": "waitingOnHuman"
        }
        """

        let decoded = try JSONDecoder().decode(ProcessEntry.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.attentionReason)
        XCTAssertEqual(decoded.attention, .waitingOnHuman)
    }

    func testProcessEntryDecodesUnknownDiscoveredHarnessToCustom() throws {
        // A forward-memory record from a newer build whose harness raw value is
        // unknown decodes to `.custom` (matching AgentHarness's lenient policy)
        // rather than dropping the row.
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "projectId": "00000000-0000-0000-0000-000000000002",
            "name": "Future",
            "kind": "terminalAgent",
            "executable": "future",
            "arguments": [],
            "workingDirectory": "/repo",
            "trust": "trusted",
            "autoResume": false,
            "discoveredHarness": "futureHarness",
            "discoveredSessionId": "z-9"
        }
        """

        let decoded = try JSONDecoder().decode(ProcessEntry.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.discoveredHarness, .custom)
        XCTAssertEqual(decoded.discoveredSessionId, "z-9")
    }
}
