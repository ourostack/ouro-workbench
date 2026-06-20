import Foundation
import XCTest
@testable import OuroWorkbenchCore

final class WorkbenchStoreTests: XCTestCase {
    func testMissingStateFileLoadsEmptyWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let loaded = try WorkbenchStore(stateURL: root.appendingPathComponent("workspace.json")).load()

        XCTAssertTrue(loaded.projects.isEmpty)
        XCTAssertTrue(loaded.processEntries.isEmpty)
        XCTAssertEqual(loaded.schemaVersion, 1)
    }

    func testConvenienceInitUsesWorkbenchPathsStateURL() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkbenchStoreTests-\(UUID().uuidString)", isDirectory: true)
        let paths = WorkbenchPaths(rootURL: root)
        XCTAssertEqual(WorkbenchStore(paths: paths).stateURL, paths.stateURL)
    }

    func testUnreadableStateDirectoryIsQuarantinedOrThrownForReadOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkbenchStoreTests-\(UUID().uuidString)", isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json", isDirectory: true)
        try FileManager.default.createDirectory(at: stateURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try WorkbenchStore(stateURL: stateURL).load(quarantineCorruptFile: false))
        XCTAssertThrowsError(try WorkbenchStore(stateURL: stateURL).load()) { error in
            guard case let WorkbenchStoreError.unreadableState(quarantineURL, reason) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertTrue(reason.contains("read failed"))
            XCTAssertTrue(quarantineURL.lastPathComponent.hasPrefix("workspace.json.corrupt-"))
        }
    }

    func testStoreErrorEqualityIgnoresUnreadableReasonButKeepsCaseAndVersion() {
        let a = URL(fileURLWithPath: "/state-a")
        let b = URL(fileURLWithPath: "/state-b")

        XCTAssertEqual(WorkbenchStoreError.unsupportedStateVersion(2), .unsupportedStateVersion(2))
        XCTAssertNotEqual(WorkbenchStoreError.unsupportedStateVersion(2), .unsupportedStateVersion(3))
        XCTAssertEqual(
            WorkbenchStoreError.unreadableState(quarantineURL: a, reason: "decode failed"),
            .unreadableState(quarantineURL: a, reason: "read failed")
        )
        XCTAssertNotEqual(
            WorkbenchStoreError.unreadableState(quarantineURL: a, reason: "decode failed"),
            .unreadableState(quarantineURL: b, reason: "decode failed")
        )
        XCTAssertNotEqual(
            WorkbenchStoreError.unreadableState(quarantineURL: a, reason: "decode failed"),
            .unsupportedStateVersion(1)
        )
    }

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
            bossWatchEnabled: true,
            bossPaneCollapsed: true,
            selectedProjectId: project.id,
            projects: [project],
            processEntries: [
                ProcessEntry(
                    projectId: project.id,
                    name: "Aider",
                    kind: .terminalAgent,
                    executable: "/bin/zsh",
                    arguments: ["-lc", "aider --yes"],
                    workingDirectory: "/repo",
                    trust: .trusted,
                    autoResume: true,
                    notes: "Use for implementation passes."
                )
            ],
            actionLog: [logEntry]
        )

        try store.save(state)
        let loaded = try store.load()

        XCTAssertEqual(loaded.boss.agentName, "slugger")
        XCTAssertEqual(loaded.bossWatchEnabled, true)
        XCTAssertEqual(loaded.bossPaneCollapsed, true)
        XCTAssertEqual(loaded.selectedProjectId, project.id)
        XCTAssertEqual(loaded.projects, [project])
        XCTAssertEqual(loaded.processEntries.first?.notes, "Use for implementation passes.")
        XCTAssertEqual(loaded.actionLog, [logEntry])
        try? FileManager.default.removeItem(at: root)
    }

    func testStoreLoadsStateBeforeAttentionAndArchiveFieldsExisted() throws {
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
        XCTAssertEqual(loaded.processEntries.first?.isArchived, false)
        XCTAssertNil(loaded.processEntries.first?.lastSummary)
        XCTAssertNil(loaded.processEntries.first?.notes)
        // Slice 6 forward-memory fields are absent from this pre-Slice-6 file →
        // decode-if-present leaves them nil; the whole state file still loads.
        XCTAssertNil(loaded.processEntries.first?.discoveredHarness)
        XCTAssertNil(loaded.processEntries.first?.discoveredSessionId)
        XCTAssertEqual(loaded.actionLog, [])
        // Absent bossWatchEnabled defaults on (automate-first posture); the
        // one-time migration also turns it on for existing state.
        XCTAssertEqual(loaded.bossWatchEnabled, true)
        XCTAssertEqual(loaded.bossPaneCollapsed, false)
        XCTAssertNil(loaded.selectedProjectId)
        XCTAssertNil(loaded.selectedEntryId)
        try? FileManager.default.removeItem(at: root)
    }

    func testCorruptStateFileIsQuarantinedNotOverwritten() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "{ this is not valid json".data(using: .utf8)?.write(to: stateURL)

        let store = WorkbenchStore(stateURL: stateURL)
        do {
            _ = try store.load()
            XCTFail("Expected load to throw on corrupt JSON")
        } catch let WorkbenchStoreError.unreadableState(quarantineURL, _) {
            // Original moved aside; nothing left at the live path to overwrite.
            XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
            let preserved = try String(contentsOf: quarantineURL, encoding: .utf8)
            XCTAssertEqual(preserved, "{ this is not valid json")
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testReadOnlyLoadDoesNotQuarantineCorruptFile() throws {
        // A read-only consumer (e.g. the MCP server) must never move the
        // owning app's live file aside. With quarantineCorruptFile: false a
        // decode failure throws the underlying error and leaves the file in
        // place.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "{ not valid json".data(using: .utf8)?.write(to: stateURL)

        let store = WorkbenchStore(stateURL: stateURL)
        do {
            _ = try store.load(quarantineCorruptFile: false)
            XCTFail("Expected load to throw on corrupt JSON")
        } catch {
            // Must NOT be the quarantine error, and the file must still exist.
            if case WorkbenchStoreError.unreadableState = error {
                XCTFail("read-only load must not quarantine")
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
            // No .corrupt sibling created.
            let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertFalse(siblings.contains { $0.contains(".corrupt-") })
        }
        try? FileManager.default.removeItem(at: root)
    }

    func testReadOnlyLoadReportsUnsupportedSchemaWithoutQuarantine() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let json = """
        {
          "boss": { "agentName": "slugger", "scope": "machine" },
          "processEntries": [],
          "processRuns": [],
          "projects": [],
          "schemaVersion": 99,
          "updatedAt": "2026-05-23T00:00:00Z"
        }
        """
        try Data(json.utf8).write(to: stateURL)

        XCTAssertThrowsError(try WorkbenchStore(stateURL: stateURL).load(quarantineCorruptFile: false)) { error in
            XCTAssertEqual(error as? WorkbenchStoreError, .unsupportedStateVersion(99))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testUnsupportedSchemaIsQuarantinedByOwningStore() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let json = """
        {
          "boss": { "agentName": "slugger", "scope": "machine" },
          "processEntries": [],
          "processRuns": [],
          "projects": [],
          "schemaVersion": 99,
          "updatedAt": "2026-05-23T00:00:00Z"
        }
        """
        try Data(json.utf8).write(to: stateURL)

        XCTAssertThrowsError(try WorkbenchStore(stateURL: stateURL).load()) { error in
            guard case let WorkbenchStoreError.unreadableState(quarantineURL, reason) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            XCTAssertTrue(quarantineURL.lastPathComponent.hasPrefix("workspace.json.corrupt-"))
            XCTAssertTrue(reason.contains("unsupported schema version 99"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
    }

    func testLenientDecodeSkipsCorruptElementsKeepsGoodOnes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let goodId = UUID()
        // Two projects: one valid, one missing the required `name` field.
        // The bad one should be skipped, the good one preserved — rather than
        // the whole workspace failing to load.
        let json = """
        {
          "boss": { "agentName": "slugger", "scope": "machine" },
          "processEntries": [],
          "processRuns": [],
          "projects": [
            { "id": "\(goodId.uuidString)", "name": "Good", "rootPath": "/good",
              "boss": { "agentName": "slugger", "scope": "machine" } },
            { "id": "\(UUID().uuidString)", "rootPath": "/bad",
              "boss": { "agentName": "slugger", "scope": "machine" } }
          ],
          "schemaVersion": 1,
          "updatedAt": "2026-05-23T00:00:00Z"
        }
        """
        try json.data(using: .utf8)?.write(to: stateURL)

        let loaded = try WorkbenchStore(stateURL: stateURL).load()
        XCTAssertEqual(loaded.projects.map(\.name), ["Good"])
        try? FileManager.default.removeItem(at: root)
    }

    func testUnknownEnumRawValueDecodesToFallbackNotThrow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let projectId = UUID()
        let entryId = UUID()
        // `kind` and `agentKind` carry values a newer build might write. The
        // entry should survive with the fields defaulted (.command / .custom)
        // instead of the whole load throwing.
        let json = """
        {
          "boss": { "agentName": "slugger", "scope": "machine" },
          "processEntries": [
            { "id": "\(entryId.uuidString)", "projectId": "\(projectId.uuidString)",
              "name": "Future Agent", "kind": "quantumAgent", "agentKind": "geminiCLI",
              "executable": "future", "arguments": [], "workingDirectory": "/tmp",
              "trust": "ultraTrusted", "autoResume": false }
          ],
          "processRuns": [],
          "projects": [
            { "id": "\(projectId.uuidString)", "name": "P", "rootPath": "/tmp",
              "boss": { "agentName": "slugger", "scope": "machine" } }
          ],
          "schemaVersion": 1,
          "updatedAt": "2026-05-23T00:00:00Z"
        }
        """
        try json.data(using: .utf8)?.write(to: stateURL)

        let loaded = try WorkbenchStore(stateURL: stateURL).load()
        let entry = try XCTUnwrap(loaded.processEntries.first)
        XCTAssertEqual(entry.name, "Future Agent")
        XCTAssertEqual(entry.kind, .command)
        XCTAssertEqual(entry.agentKind, .custom)
        XCTAssertEqual(entry.trust, .untrusted)
        try? FileManager.default.removeItem(at: root)
    }
}
