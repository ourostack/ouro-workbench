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
            guard case let WorkbenchStoreError.unreadableState(preserved, reason) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            guard case let .moved(quarantineURL) = preserved else {
                return XCTFail("Expected .moved outcome, got \(preserved)")
            }
            XCTAssertTrue(reason.contains("read failed"))
            XCTAssertTrue(quarantineURL.lastPathComponent.hasPrefix("workspace.json.corrupt-"))
        }
    }

    func testStoreErrorEqualityIgnoresUnreadableReasonButKeepsPreservedAndVersion() {
        let a = URL(fileURLWithPath: "/state-a")
        let b = URL(fileURLWithPath: "/state-b")

        XCTAssertEqual(WorkbenchStoreError.unsupportedStateVersion(2), .unsupportedStateVersion(2))
        XCTAssertNotEqual(WorkbenchStoreError.unsupportedStateVersion(2), .unsupportedStateVersion(3))
        // Reason is ignored in equality; the carried outcome is not.
        XCTAssertEqual(
            WorkbenchStoreError.unreadableState(preserved: .moved(quarantineURL: a), reason: "decode failed"),
            .unreadableState(preserved: .moved(quarantineURL: a), reason: "read failed")
        )
        XCTAssertNotEqual(
            WorkbenchStoreError.unreadableState(preserved: .moved(quarantineURL: a), reason: "decode failed"),
            .unreadableState(preserved: .moved(quarantineURL: b), reason: "decode failed")
        )
        // A move that succeeded and one that failed are never equal even at the
        // same path — the operator-facing message must differ.
        XCTAssertNotEqual(
            WorkbenchStoreError.unreadableState(preserved: .moved(quarantineURL: a), reason: "decode failed"),
            .unreadableState(preserved: .moveFailed(attemptedURL: a, reason: "boom"), reason: "decode failed")
        )
        XCTAssertNotEqual(
            WorkbenchStoreError.unreadableState(preserved: .moved(quarantineURL: a), reason: "decode failed"),
            .unsupportedStateVersion(1)
        )
    }

    // MARK: - F5 Seam 1: quarantine outcome is a checked value

    func testQuarantineMoveSucceedsReturnsMovedAndRelocatesBytes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original bytes".utf8).write(to: stateURL)
        let quarantineURL = root.appendingPathComponent("workspace.json.corrupt-stamp")

        let outcome = WorkbenchStore.quarantineMove(
            stateURL: stateURL,
            quarantineURL: quarantineURL,
            fileManager: .default
        )

        guard case let .moved(movedURL) = outcome else {
            return XCTFail("Expected .moved, got \(outcome)")
        }
        XCTAssertEqual(movedURL, quarantineURL)
        // Original is gone from the live path; bytes live at the quarantine URL.
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
        XCTAssertEqual(try String(contentsOf: quarantineURL, encoding: .utf8), "original bytes")
    }

    func testQuarantineMoveFailsReturnsMoveFailedAndLeavesOriginalInPlace() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("original bytes".utf8).write(to: stateURL)
        // Pre-create a NON-EMPTY DIRECTORY at the target so moveItem throws
        // deterministically (no timestamp racing). A non-empty dir cannot be
        // overwritten by a move.
        let quarantineURL = root.appendingPathComponent("workspace.json.corrupt-stamp", isDirectory: true)
        try FileManager.default.createDirectory(at: quarantineURL, withIntermediateDirectories: true)
        try Data("occupant".utf8).write(to: quarantineURL.appendingPathComponent("occupant.txt"))

        let outcome = WorkbenchStore.quarantineMove(
            stateURL: stateURL,
            quarantineURL: quarantineURL,
            fileManager: .default
        )

        guard case let .moveFailed(attemptedURL, reason) = outcome else {
            return XCTFail("Expected .moveFailed, got \(outcome)")
        }
        XCTAssertEqual(attemptedURL, quarantineURL)
        XCTAssertFalse(reason.isEmpty)
        // CRITICAL: the original is STILL at stateURL with its original bytes —
        // a subsequent atomic save must not be told it's safe to overwrite.
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertEqual(try String(contentsOf: stateURL, encoding: .utf8), "original bytes")
    }

    func testCorruptStateMoveSucceedsCarriesMovedOutcomeInError() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("{ not valid json".utf8).write(to: stateURL)

        XCTAssertThrowsError(try WorkbenchStore(stateURL: stateURL).load()) { error in
            guard case let WorkbenchStoreError.unreadableState(preserved, reason) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            guard case let .moved(quarantineURL) = preserved else {
                return XCTFail("Expected .moved outcome, got \(preserved)")
            }
            XCTAssertTrue(reason.contains("decode failed"))
            XCTAssertTrue(quarantineURL.lastPathComponent.hasPrefix("workspace.json.corrupt-"))
            // Original relocated; the quarantine file holds the exact bytes.
            XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
            XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
            XCTAssertEqual(
                try? String(contentsOf: quarantineURL, encoding: .utf8),
                "{ not valid json"
            )
        }
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
        // Absent bossPaneCollapsed defaults to the SAME value a fresh memberwise
        // state uses (`true`) — an upgraded old file and a fresh launch must agree
        // on the boss pane (was the buggy `false`, which expanded an upgraded file
        // while collapsing a fresh one).
        XCTAssertEqual(loaded.bossPaneCollapsed, true)
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
        } catch let WorkbenchStoreError.unreadableState(outcome, _) {
            guard case let .moved(quarantineURL) = outcome else {
                return XCTFail("Expected .moved outcome, got \(outcome)")
            }
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
            guard case let WorkbenchStoreError.unreadableState(preserved, reason) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            guard case let .moved(quarantineURL) = preserved else {
                return XCTFail("Expected .moved outcome, got \(preserved)")
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
        // F5 Seam 2: the drop is now SURFACED, not silent. Exactly one row was
        // skipped, attributed to the `projects` collection.
        XCTAssertEqual(loaded.decodeReport.skippedRowCount, 1)
        XCTAssertEqual(loaded.decodeReport.skippedByCollection["projects"], 1)
        XCTAssertTrue(loaded.decodeReport.isLossy)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - F5 Seam 2: lenient decode surfaces a salvage decision

    func testDecodeReportIsLosslessOnCleanLoad() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectId = UUID()
        let json = """
        {
          "boss": { "agentName": "slugger", "scope": "machine" },
          "processEntries": [],
          "processRuns": [],
          "projects": [
            { "id": "\(projectId.uuidString)", "name": "Good", "rootPath": "/good",
              "boss": { "agentName": "slugger", "scope": "machine" } }
          ],
          "schemaVersion": 1,
          "updatedAt": "2026-05-23T00:00:00Z"
        }
        """
        try Data(json.utf8).write(to: stateURL)

        let loaded = try WorkbenchStore(stateURL: stateURL).load()
        XCTAssertEqual(loaded.decodeReport.skippedRowCount, 0)
        XCTAssertTrue(loaded.decodeReport.skippedByCollection.isEmpty)
        XCTAssertFalse(loaded.decodeReport.isLossy)
    }

    func testPostLoadDecisionIsSafeOnLosslessReportAndSalvageOnLossy() {
        XCTAssertEqual(postLoadDecision(for: DecodeReport()), .safeToResave)
        XCTAssertEqual(
            postLoadDecision(for: DecodeReport(skippedRowCount: 0, skippedByCollection: [:])),
            .safeToResave
        )
        let lossy = DecodeReport(skippedRowCount: 2, skippedByCollection: ["projects": 1, "processRuns": 1])
        guard case let .salvageBeforeResave(reason) = postLoadDecision(for: lossy) else {
            return XCTFail("Expected .salvageBeforeResave for a lossy report")
        }
        XCTAssertTrue(reason.contains("2"))
    }

    func testUnknownEnumFallbackIsNotSalvagePathed() throws {
        // A forward-schema raw value that DEFAULTS (e.g. `kind`/`agentKind`/`trust`)
        // keeps the row — it is NOT a drop, so it must NOT mark the load lossy.
        // Only genuine element drops salvage. Pin this distinction.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectId = UUID()
        let entryId = UUID()
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
        try Data(json.utf8).write(to: stateURL)

        let loaded = try WorkbenchStore(stateURL: stateURL).load()
        // The entry SURVIVED with defaulted fields → no drop → not lossy.
        XCTAssertEqual(loaded.processEntries.count, 1)
        XCTAssertEqual(loaded.decodeReport.skippedRowCount, 0)
        XCTAssertFalse(loaded.decodeReport.isLossy)
        XCTAssertEqual(postLoadDecision(for: loaded.decodeReport), .safeToResave)
    }

    func testWriteSalvageCopyCopiesOriginalBytesAndLeavesLiveFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("ORIGINAL PRE-DROP BYTES".utf8).write(to: stateURL)

        let store = WorkbenchStore(stateURL: stateURL)
        let salvageURL = try store.writeSalvageCopy()

        XCTAssertTrue(salvageURL.lastPathComponent.hasPrefix("workspace.json.salvage-"))
        // The salvage copy holds the ORIGINAL bytes.
        XCTAssertEqual(try String(contentsOf: salvageURL, encoding: .utf8), "ORIGINAL PRE-DROP BYTES")
        // CRITICAL: copyItem (not move) — the live file MUST still be present so
        // the imminent re-save has something to write over.
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        XCTAssertEqual(try String(contentsOf: stateURL, encoding: .utf8), "ORIGINAL PRE-DROP BYTES")
    }

    func testDecodeReportIsExcludedFromEncodingSoRoundTripStaysGreen() throws {
        // The non-persisted decodeReport must not appear in the encoded JSON and
        // must default back to lossless on re-decode — round-trip equality holds.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = WorkbenchStore(stateURL: root.appendingPathComponent("workspace.json"))
        defer { try? FileManager.default.removeItem(at: root) }
        let project = WorkbenchProject(name: "Harness", rootPath: "/repo")
        let state = WorkspaceState(projects: [project])

        try store.save(state)
        let raw = try String(contentsOf: store.stateURL, encoding: .utf8)
        XCTAssertFalse(raw.contains("decodeReport"), "decodeReport must be excluded from CodingKeys")

        let loaded = try store.load()
        XCTAssertEqual(loaded.decodeReport, DecodeReport())
        XCTAssertEqual(loaded.projects, [project])
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

    // MARK: - F10b Seam A: WorkbenchStoreError is a LocalizedError so the boss
    // reads an honest, actionable message instead of the Foundation default
    // ("The operation couldn't be completed. (…WorkbenchStoreError error 0.)").

    func testUnsupportedStateVersionErrorDescriptionNamesVersionAndUpgrade() throws {
        let error = WorkbenchStoreError.unsupportedStateVersion(2)
        let message = try XCTUnwrap(error.errorDescription)
        // Names the schema it found (v2)...
        XCTAssertTrue(message.contains("v2"), "must name the newer schema version, got: \(message)")
        // ...the schema this build understands (v1)...
        XCTAssertTrue(message.contains("v1"), "must name the supported schema version, got: \(message)")
        // ...tells the boss to upgrade...
        XCTAssertTrue(
            message.lowercased().contains("upgrade"),
            "must instruct the boss to upgrade, got: \(message)"
        )
        // ...and reassures that nothing was destroyed.
        XCTAssertTrue(
            message.lowercased().contains("intact"),
            "must reassure the data is intact, got: \(message)"
        )
    }

    func testUnsupportedStateVersionErrorReachesThroughLocalizedDescription() throws {
        // localizedDescription only returns errorDescription when the error
        // conforms to LocalizedError — this is the property the MCP dispatch
        // catch reads. Pin that the honest message surfaces through it.
        let error: Error = WorkbenchStoreError.unsupportedStateVersion(7)
        XCTAssertTrue(
            error.localizedDescription.contains("v7"),
            "the dispatch catch reads error.localizedDescription — it must carry the honest message, got: \(error.localizedDescription)"
        )
    }

    func testUnreadableStateMovedErrorDescriptionNamesQuarantineAndEmptyWorkspace() throws {
        let quarantineURL = URL(fileURLWithPath: "/tmp/workspace.json.corrupt-2026")
        let error = WorkbenchStoreError.unreadableState(
            preserved: .moved(quarantineURL: quarantineURL),
            reason: "decode failed: bad json"
        )
        let message = try XCTUnwrap(error.errorDescription)
        // Names the quarantine filename so the operator can recover...
        XCTAssertTrue(
            message.contains("workspace.json.corrupt-2026"),
            "moved arm must name the quarantine filename, got: \(message)"
        )
        // ...names the failure reason...
        XCTAssertTrue(message.contains("decode failed: bad json"), "must name the reason, got: \(message)")
        // ...and tells the boss the live workspace is now empty.
        XCTAssertTrue(
            message.lowercased().contains("empty workspace"),
            "moved arm must say the workspace reset to empty, got: \(message)"
        )
    }

    func testUnreadableStateMoveFailedErrorDescriptionNamesBothReasonsAndUntouched() throws {
        let attemptedURL = URL(fileURLWithPath: "/tmp/workspace.json.corrupt-2026")
        let error = WorkbenchStoreError.unreadableState(
            preserved: .moveFailed(attemptedURL: attemptedURL, reason: "permission denied"),
            reason: "decode failed: bad json"
        )
        let message = try XCTUnwrap(error.errorDescription)
        // Names the decode reason...
        XCTAssertTrue(message.contains("decode failed: bad json"), "must name the load reason, got: \(message)")
        // ...names the move-failure reason...
        XCTAssertTrue(message.contains("permission denied"), "must name the move-failure reason, got: \(message)")
        // ...and tells the boss the original is still in place (not quarantined).
        XCTAssertTrue(
            message.lowercased().contains("untouched in place"),
            "moveFailed arm must say the original is untouched in place, got: \(message)"
        )
    }

    // MARK: - Schema back-compat: OLDER/equal loads, only NEWER rejects
    //
    // The decode of `WorkspaceState` succeeds BEFORE the version gate is even
    // consulted (the JSON is fully decoded into `state`, then the gate runs as a
    // separate check). An OLDER, backward-compatible file decodes cleanly because
    // the per-field decoders are lenient (`decodeIfPresent`/defaults). The bug was
    // an EQUALITY gate treating any non-current version — including a fully
    // readable older one — as unreadable, wiping the workspace to empty and
    // quarantining the file. The fix accepts `<= currentSchemaVersion` and
    // rejects ONLY `> currentSchemaVersion` (a future build's file we can't safely
    // interpret).

    func testOlderSchemaVersionLoadsWithAllRowsIntactAndIsNotQuarantined() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectId = UUID()
        let entryId = UUID()
        // schemaVersion ONE BELOW current: an older, fully-decodable file carrying
        // a real project + terminal. Every row must survive; nothing wiped, nothing
        // quarantined.
        let older = WorkspaceState.currentSchemaVersion - 1
        let json = """
        {
          "boss": { "agentName": "slugger", "scope": "machine" },
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
              "boss": { "agentName": "slugger", "scope": "machine" },
              "id": "\(projectId.uuidString)",
              "name": "Project",
              "rootPath": "/tmp/project"
            }
          ],
          "schemaVersion": \(older),
          "updatedAt": "2026-05-23T00:00:00Z"
        }
        """
        try Data(json.utf8).write(to: stateURL)

        let loaded = try WorkbenchStore(stateURL: stateURL).load()

        // All rows intact — NOT wiped to empty.
        XCTAssertEqual(loaded.projects.count, 1)
        XCTAssertEqual(loaded.projects.first?.id, projectId)
        XCTAssertEqual(loaded.projects.first?.name, "Project")
        XCTAssertEqual(loaded.processEntries.count, 1)
        XCTAssertEqual(loaded.processEntries.first?.id, entryId)
        XCTAssertEqual(loaded.processEntries.first?.name, "OpenAI Codex")
        // The older version is preserved as-loaded (not silently rewritten here).
        XCTAssertEqual(loaded.schemaVersion, older)
        // Live file still in place; NO `.corrupt-` sibling was created.
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        let siblings = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(
            siblings.contains { $0.contains(".corrupt-") },
            "older readable file must not be quarantined, found: \(siblings)"
        )
    }

    func testEqualSchemaVersionLoadsWithRowsIntact() throws {
        // Regression: a current-version file must continue to load fully.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectId = UUID()
        let json = """
        {
          "boss": { "agentName": "slugger", "scope": "machine" },
          "processEntries": [],
          "processRuns": [],
          "projects": [
            {
              "boss": { "agentName": "slugger", "scope": "machine" },
              "id": "\(projectId.uuidString)",
              "name": "Current",
              "rootPath": "/tmp/current"
            }
          ],
          "schemaVersion": \(WorkspaceState.currentSchemaVersion),
          "updatedAt": "2026-05-23T00:00:00Z"
        }
        """
        try Data(json.utf8).write(to: stateURL)

        let loaded = try WorkbenchStore(stateURL: stateURL).load()

        XCTAssertEqual(loaded.schemaVersion, WorkspaceState.currentSchemaVersion)
        XCTAssertEqual(loaded.projects.count, 1)
        XCTAssertEqual(loaded.projects.first?.id, projectId)
        let siblings = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(siblings.contains { $0.contains(".corrupt-") })
    }

    func testNewerSchemaVersionIsStillQuarantinedByOwningStore() throws {
        // Forward-incompat preserved: a file ONE ABOVE current was written by a
        // FUTURE build whose shape we can't safely interpret. It must still be
        // rejected — quarantined by the owning store, surfaced as
        // `unsupportedStateVersion` for the read-only consumer.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let newer = WorkspaceState.currentSchemaVersion + 1
        let json = """
        {
          "boss": { "agentName": "slugger", "scope": "machine" },
          "processEntries": [],
          "processRuns": [],
          "projects": [],
          "schemaVersion": \(newer),
          "updatedAt": "2026-05-23T00:00:00Z"
        }
        """
        try Data(json.utf8).write(to: stateURL)

        // Owning store quarantines the future file (data-preserving move aside).
        XCTAssertThrowsError(try WorkbenchStore(stateURL: stateURL).load()) { error in
            guard case let WorkbenchStoreError.unreadableState(preserved, reason) = error else {
                return XCTFail("Unexpected error \(error)")
            }
            guard case let .moved(quarantineURL) = preserved else {
                return XCTFail("Expected .moved outcome, got \(preserved)")
            }
            XCTAssertTrue(quarantineURL.lastPathComponent.hasPrefix("workspace.json.corrupt-"))
            XCTAssertTrue(reason.contains("unsupported schema version \(newer)"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: quarantineURL.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))

        // Read-only consumer: future file rejected as unsupportedStateVersion,
        // file left untouched in place.
        let stateURL2 = root.appendingPathComponent("workspace2.json")
        try Data(json.utf8).write(to: stateURL2)
        XCTAssertThrowsError(
            try WorkbenchStore(stateURL: stateURL2).load(quarantineCorruptFile: false)
        ) { error in
            XCTAssertEqual(error as? WorkbenchStoreError, .unsupportedStateVersion(newer))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL2.path))
    }

    func testSchemaVersionZeroIsTreatedAsOldestReadableAndLoads() throws {
        // The lower boundary of the accept range: an explicit oldest version (0)
        // is `< current`, so it must load (lenient decoders fill defaults) rather
        // than be wiped/quarantined.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let projectId = UUID()
        let json = """
        {
          "boss": { "agentName": "slugger", "scope": "machine" },
          "processEntries": [],
          "processRuns": [],
          "projects": [
            {
              "boss": { "agentName": "slugger", "scope": "machine" },
              "id": "\(projectId.uuidString)",
              "name": "Oldest",
              "rootPath": "/tmp/oldest"
            }
          ],
          "schemaVersion": 0,
          "updatedAt": "2026-05-23T00:00:00Z"
        }
        """
        try Data(json.utf8).write(to: stateURL)

        let loaded = try WorkbenchStore(stateURL: stateURL).load()

        XCTAssertEqual(loaded.schemaVersion, 0)
        XCTAssertEqual(loaded.projects.count, 1)
        XCTAssertEqual(loaded.projects.first?.name, "Oldest")
        let siblings = try FileManager.default
            .contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(siblings.contains { $0.contains(".corrupt-") })
    }
}
