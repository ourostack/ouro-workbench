import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchStoreTests: XCTestCase {
    func testStoreRoundTripsWorkspaceState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WorkbenchStore(stateURL: root.appendingPathComponent("workspace.json"))
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let logEntry = WorkbenchActionLogEntry(
            occurredAt: Date(timeIntervalSince1970: 1_779_552_000),
            source: "boss:slugger",
            action: "sendInput",
            targetName: "Claude Code",
            result: "Sent input to Claude Code",
            succeeded: true
        )
        let state = WorkspaceState(
            boss: BossAgentSelection(agentName: "slugger"),
            projects: [project],
            actionLog: [logEntry]
        )

        try store.save(state)
        let loaded = try store.load()

        XCTAssertEqual(loaded.boss.agentName, "slugger")
        XCTAssertEqual(loaded.projects, [project])
        XCTAssertEqual(loaded.actionLog, [logEntry])
        try? FileManager.default.removeItem(at: root)
    }

    func testStoreLoadsStateBeforeAttentionFieldsExisted() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectId = UUID()
        let entryId = UUID()
        let json = """
        {
          "boss": {
            "agentName": "slugger",
            "scope": "machine"
          },
          "processEntries": [
            {
              "agentKind": "openAICodex",
              "arguments": ["--yolo"],
              "autoResume": true,
              "executable": "codex",
              "id": "\(entryId.uuidString)",
              "kind": "terminalAgent",
              "name": "OpenAI Codex",
              "projectId": "\(projectId.uuidString)",
              "trust": "trusted",
              "workingDirectory": "/tmp/project"
            }
          ],
          "processRuns": [],
          "projects": [
            {
              "boss": {
                "agentName": "slugger",
                "scope": "machine"
              },
              "id": "\(projectId.uuidString)",
              "name": "Project",
              "rootPath": "/tmp/project"
            }
          ],
          "schemaVersion": 1,
          "updatedAt": "2026-05-23T00:00:00Z"
        }
        """
        try json.data(using: .utf8)?.write(to: stateURL)

        let loaded = try WorkbenchStore(stateURL: stateURL).load()

        XCTAssertEqual(loaded.processEntries.first?.attention, .idle)
        XCTAssertNil(loaded.processEntries.first?.lastSummary)
        XCTAssertEqual(loaded.actionLog, [])
        try? FileManager.default.removeItem(at: root)
    }
}
