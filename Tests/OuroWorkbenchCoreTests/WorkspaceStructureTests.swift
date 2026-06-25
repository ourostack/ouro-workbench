import XCTest
@testable import OuroWorkbenchCore

/// Slice ②a — durable workspace/tab STRUCTURE (vs ephemeral runtime).
/// Tests the `Workspace` entity, its name model, `ProcessEntry.tabNameOverride`,
/// the `workspaces` persistence collection + schema bump, and the
/// non-destructive idempotent migration. Core is test-visible
/// (`@testable import`), so this is real red→green XCTest TDD.
final class WorkspaceStructureTests: XCTestCase {

    // MARK: - Unit 1a: Workspace struct + name model

    func testWorkspaceMemberwiseInitDefaults() {
        // The documented defaults: nameOverride nil, isPinned false, tabIds [].
        let id = UUID()
        let ws = Workspace(id: id, autoName: "Restored workspace")
        XCTAssertEqual(ws.id, id)
        XCTAssertEqual(ws.autoName, "Restored workspace")
        XCTAssertNil(ws.nameOverride)
        XCTAssertFalse(ws.isPinned)
        XCTAssertEqual(ws.tabIds, [])
    }

    func testWorkspaceMemberwiseInitExplicitValues() {
        let id = UUID()
        let tab1 = UUID()
        let tab2 = UUID()
        let ws = Workspace(
            id: id,
            autoName: "auto",
            nameOverride: "Custom",
            isPinned: true,
            tabIds: [tab1, tab2]
        )
        XCTAssertEqual(ws.autoName, "auto")
        XCTAssertEqual(ws.nameOverride, "Custom")
        XCTAssertTrue(ws.isPinned)
        XCTAssertEqual(ws.tabIds, [tab1, tab2])
    }

    func testEffectiveNameUsesOverrideWhenPresent() {
        let ws = Workspace(id: UUID(), autoName: "auto", nameOverride: "Custom")
        XCTAssertEqual(ws.effectiveName, "Custom")
    }

    func testEffectiveNameFallsBackToAutoNameWhenOverrideNil() {
        let ws = Workspace(id: UUID(), autoName: "auto", nameOverride: nil)
        XCTAssertEqual(ws.effectiveName, "auto")
    }

    func testEffectiveNameHonorsEmptyStringOverride() {
        // DA4: an EMPTY override is a deliberate value, NOT a revert. Revert is
        // unambiguously nameOverride == nil. An empty string is honored.
        let ws = Workspace(id: UUID(), autoName: "auto", nameOverride: "")
        XCTAssertEqual(ws.effectiveName, "")
        XCTAssertNotNil(ws.nameOverride)
    }

    func testWorkspaceCodableRoundTripsEqual() throws {
        let ws = Workspace(
            id: UUID(),
            autoName: "auto",
            nameOverride: "Custom",
            isPinned: true,
            tabIds: [UUID(), UUID()]
        )
        let data = try JSONEncoder().encode(ws)
        let decoded = try JSONDecoder().decode(Workspace.self, from: data)
        XCTAssertEqual(decoded, ws)
    }

    func testWorkspaceDecodesMissingOptionalFieldsToDefaults() throws {
        // Forward/back-compat: a workspace JSON carrying only id + autoName decodes
        // with documented defaults (decode-if-present) and never throws.
        let id = UUID()
        let json = """
        { "id": "\(id.uuidString)", "autoName": "seed" }
        """
        let decoded = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.autoName, "seed")
        XCTAssertNil(decoded.nameOverride)
        XCTAssertFalse(decoded.isPinned)
        XCTAssertEqual(decoded.tabIds, [])
    }

    func testWorkspaceIgnoresUnknownExtraKey() throws {
        // An unknown extra key (e.g. a forward-slice field) is ignored, no throw.
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "autoName": "seed",
          "someFutureField": "ignore-me",
          "groupings": [{ "x": 1 }]
        }
        """
        let decoded = try JSONDecoder().decode(Workspace.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.id, id)
        XCTAssertEqual(decoded.autoName, "seed")
        XCTAssertNil(decoded.nameOverride)
        XCTAssertFalse(decoded.isPinned)
        XCTAssertEqual(decoded.tabIds, [])
    }

    // MARK: - Unit 1c: persistence-boundary invariant (DA2)

    func testWorkspaceExposesOnlyStructureFieldsNoRuntime() {
        // DA2: a Workspace is a PURE structural value. Pin its stored property set
        // via Mirror so a later field-add can't smuggle a pid/run/live-status into
        // the durable type without this test failing. The set must be EXACTLY the
        // structure fields — and must contain none of the runtime field names that
        // live on ProcessRun.
        let ws = Workspace(
            id: UUID(),
            autoName: "auto",
            nameOverride: "x",
            isPinned: true,
            tabIds: [UUID()]
        )
        let labels = Set(Mirror(reflecting: ws).children.compactMap(\.label))
        XCTAssertEqual(labels, ["id", "autoName", "nameOverride", "isPinned", "tabIds"])

        // Explicit negative pins: none of these runtime/live-process field names
        // may appear on the structure type.
        let forbiddenRuntimeFields: Set<String> = [
            "pid", "status", "run", "processRun", "startedAt", "endedAt",
            "exitCode", "rawExitStatus", "terminalSessionId", "transcriptPath",
            "lastOutputAt", "attention",
        ]
        XCTAssertTrue(
            labels.isDisjoint(with: forbiddenRuntimeFields),
            "Workspace must carry no runtime field; found \(labels.intersection(forbiddenRuntimeFields))"
        )
    }

    // MARK: - Unit 2a: ProcessEntry.tabNameOverride + effectiveTabName

    func testProcessEntryTabNameOverrideDefaultsNil() {
        // Memberwise init defaults tabNameOverride to nil; effectiveTabName falls
        // back to `name`.
        let entry = makeEntry(name: "ouro-workbench")
        XCTAssertNil(entry.tabNameOverride)
        XCTAssertEqual(entry.effectiveTabName, "ouro-workbench")
    }

    func testEffectiveTabNameUsesOverrideWhenPresent() {
        let entry = makeEntry(name: "auto-name", tabNameOverride: "My Tab")
        XCTAssertEqual(entry.effectiveTabName, "My Tab")
    }

    func testEffectiveTabNameHonorsEmptyStringOverride() {
        // DA4 (mirrored for tabs): an empty override is honored, NOT a revert.
        let entry = makeEntry(name: "auto-name", tabNameOverride: "")
        XCTAssertEqual(entry.effectiveTabName, "")
        XCTAssertNotNil(entry.tabNameOverride)
    }

    func testProcessEntryWithoutTabNameOverrideDecodesNil() throws {
        // Backcompat: every pre-②a row (incl. the v1 fixture's "Resume …" rows)
        // lacks `tabNameOverride` → decodes nil → effectiveTabName == name.
        let state = try loadV1Fixture()
        XCTAssertEqual(state.processEntries.count, 6)
        for entry in state.processEntries {
            XCTAssertNil(
                entry.tabNameOverride,
                "pre-②a entry \(entry.name) must decode tabNameOverride nil"
            )
            XCTAssertEqual(entry.effectiveTabName, entry.name)
        }
        // Spot-check a "Resume …" row specifically.
        let resume = state.processEntries.first { $0.name.hasPrefix("Resume ") }
        XCTAssertNotNil(resume)
        XCTAssertNil(resume?.tabNameOverride)
        XCTAssertEqual(resume?.effectiveTabName, resume?.name)
    }

    func testTabNameOverrideRoundTripsAndRevertReturnsToName() throws {
        // An entry WITH a tabNameOverride survives save→load; clearing it (nil)
        // reverts effectiveTabName to `name`.
        var entry = makeEntry(name: "auto-name", tabNameOverride: "Renamed")
        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(ProcessEntry.self, from: data)
        XCTAssertEqual(decoded.tabNameOverride, "Renamed")
        XCTAssertEqual(decoded.effectiveTabName, "Renamed")
        XCTAssertEqual(decoded, entry)

        entry.tabNameOverride = nil
        XCTAssertEqual(entry.effectiveTabName, "auto-name")
    }

    // MARK: - Unit 3a: WorkspaceState.workspaces + schema bump 1→2

    func testCurrentSchemaVersionIsTwo() {
        XCTAssertEqual(WorkspaceState.currentSchemaVersion, 2)
    }

    func testWorkspaceStateMemberwiseInitDefaultsWorkspacesEmpty() {
        let state = WorkspaceState()
        XCTAssertEqual(state.workspaces, [])
        XCTAssertEqual(state.schemaVersion, 2)
    }

    func testWorkspacesAbsentInJSONDecodesEmpty() throws {
        // present-or-empty: a state JSON without a `workspaces` key → [].
        let json = """
        {
          "schemaVersion": 2,
          "boss": { "agentName": "slugger", "scope": "machine" },
          "projects": [],
          "processEntries": [],
          "processRuns": [],
          "actionLog": [],
          "decisionLog": [],
          "updatedAt": "2026-06-02T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let state = try decoder.decode(WorkspaceState.self, from: Data(json.utf8))
        XCTAssertEqual(state.workspaces, [])
    }

    func testWorkspacesRoundTripPreservesOrderNamesPin() throws {
        let ws1 = Workspace(autoName: "First", nameOverride: "Renamed", isPinned: true, tabIds: [UUID(), UUID()])
        let ws2 = Workspace(autoName: "Second", tabIds: [UUID()])
        let state = WorkspaceState(workspaces: [ws1, ws2])

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkspaceState.self, from: data)

        XCTAssertEqual(decoded.workspaces, [ws1, ws2])
        XCTAssertEqual(decoded.workspaces.map(\.effectiveName), ["Renamed", "Second"])
        XCTAssertEqual(decoded.workspaces.map(\.isPinned), [true, false])
    }

    func testStoreSaveWritesSchemaTwoAndWorkspacesArray() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ws = Workspace(autoName: "Restored workspace", tabIds: [UUID()])
        let store = WorkbenchStore(stateURL: stateURL)
        try store.save(WorkspaceState(workspaces: [ws]))

        // Raw JSON carries schemaVersion 2 + a workspaces array.
        let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        XCTAssertEqual(raw?["schemaVersion"] as? Int, 2)
        let rawWorkspaces = raw?["workspaces"] as? [[String: Any]]
        XCTAssertEqual(rawWorkspaces?.count, 1)
        XCTAssertEqual(rawWorkspaces?.first?["autoName"] as? String, "Restored workspace")

        // And round-trips through the store.
        let loaded = try store.load()
        XCTAssertEqual(loaded.workspaces, [ws])
        XCTAssertEqual(loaded.schemaVersion, 2)
    }

    func testWorkspacesDecodeLenientlySkipsCorruptElementAttributesDrop() throws {
        // One valid + one corrupt workspace (missing required `autoName`): the valid
        // one is kept, the corrupt one dropped, the drop attributed into
        // decodeReport.skippedByCollection["workspaces"]. Mirrors the projects test.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let goodId = UUID()
        let json = """
        {
          "schemaVersion": 2,
          "boss": { "agentName": "slugger", "scope": "machine" },
          "projects": [],
          "processEntries": [],
          "processRuns": [],
          "workspaces": [
            { "id": "\(goodId.uuidString)", "autoName": "Good" },
            { "id": "\(UUID().uuidString)" }
          ],
          "updatedAt": "2026-05-23T00:00:00Z"
        }
        """
        try Data(json.utf8).write(to: stateURL)

        let loaded = try WorkbenchStore(stateURL: stateURL).load()
        XCTAssertEqual(loaded.workspaces.map(\.autoName), ["Good"])
        XCTAssertEqual(loaded.workspaces.first?.id, goodId)
        XCTAssertEqual(loaded.decodeReport.skippedByCollection["workspaces"], 1)
        XCTAssertTrue(loaded.decodeReport.isLossy)
    }

    func testV1FixtureLoadsUnderV2BuildWithEmptyWorkspacesNotQuarantined() throws {
        // Backcompat: the Unit-0 v1 fixture (schemaVersion 1, no `workspaces`) loads
        // under the v2 build with workspaces == [] (pre-migration), all 6 entries
        // intact, NOT quarantined.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stateURL = root.appendingPathComponent("workspace.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(contentsOf: v1FixtureURL()).write(to: stateURL)

        let loaded = try WorkbenchStore(stateURL: stateURL).load()
        XCTAssertEqual(loaded.schemaVersion, 1) // decode preserves the input version
        XCTAssertEqual(loaded.workspaces, [])
        XCTAssertEqual(loaded.processEntries.count, 6)
        // Not quarantined: live file in place, no `.corrupt-` sibling.
        XCTAssertTrue(FileManager.default.fileExists(atPath: stateURL.path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(siblings.contains { $0.contains(".corrupt-") })
    }

    // MARK: - Unit 4a: migrateToWorkspaceStructure()

    func testMigrationOfV1FixtureCreatesSingleWorkspaceWithAllEntriesInOrder() throws {
        var state = try loadV1Fixture()
        let originalIds = state.processEntries.map(\.id)
        XCTAssertEqual(state.workspaces, [])

        state.migrateToWorkspaceStructure()

        // Exactly ONE workspace, deterministic seed name, defaults.
        XCTAssertEqual(state.workspaces.count, 1)
        let ws = try XCTUnwrap(state.workspaces.first)
        XCTAssertEqual(ws.autoName, "Restored workspace")
        XCTAssertNil(ws.nameOverride)
        XCTAssertFalse(ws.isPinned)
        // tabIds == every entry id in ORIGINAL order (all 6, incl. the 4 "Resume …").
        XCTAssertEqual(ws.tabIds, originalIds)
        XCTAssertEqual(ws.tabIds.count, 6)
        // No processEntries row deleted — the 4 "Resume …" rows are all members.
        let resumeIds = state.processEntries.filter { $0.name.hasPrefix("Resume ") }.map(\.id)
        XCTAssertEqual(resumeIds.count, 4)
        for rid in resumeIds {
            XCTAssertTrue(ws.tabIds.contains(rid), "Resume row \(rid) must be a member")
        }
    }

    func testMigrationIsIdempotent() throws {
        var state = try loadV1Fixture()
        state.migrateToWorkspaceStructure()
        let afterFirst = state
        state.migrateToWorkspaceStructure()
        // Second call changes NOTHING.
        XCTAssertEqual(state, afterFirst)
        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.workspaces.first?.tabIds.count, 6)
    }

    func testMigrationLeavesAlreadyMigratedStateUnchanged() {
        // A v2 state whose single workspace already covers all entries is unchanged.
        let e1 = makeEntry(name: "a")
        let e2 = makeEntry(name: "b")
        let covering = Workspace(autoName: "Restored workspace", tabIds: [e1.id, e2.id])
        var state = WorkspaceState(processEntries: [e1, e2], workspaces: [covering])
        let before = state
        state.migrateToWorkspaceStructure()
        XCTAssertEqual(state, before)
        XCTAssertEqual(state.workspaces.count, 1)
    }

    func testMigrationOnEmptyStateMintsNoWorkspace() {
        // DA5: an empty machine has nothing to restore — no default minted.
        var state = WorkspaceState()
        state.migrateToWorkspaceStructure()
        XCTAssertEqual(state.workspaces, [])
    }

    func testMigrationExcludesArchivedEntriesFromAutoMembership() {
        // DA6: archived entries are NOT forced into the default workspace's tabIds,
        // but are PRESERVED in processEntries (never dropped).
        let active1 = makeEntry(name: "active1")
        let archived = makeEntry(name: "archived", isArchived: true)
        let active2 = makeEntry(name: "active2")
        var state = WorkspaceState(processEntries: [active1, archived, active2])

        state.migrateToWorkspaceStructure()

        XCTAssertEqual(state.workspaces.count, 1)
        let ws = state.workspaces.first
        // Only the two active entries are members, in order; archived excluded.
        XCTAssertEqual(ws?.tabIds, [active1.id, active2.id])
        XCTAssertFalse(ws?.tabIds.contains(archived.id) ?? true)
        // Archived entry still present in processEntries (preserved).
        XCTAssertEqual(state.processEntries.count, 3)
        XCTAssertTrue(state.processEntries.contains { $0.id == archived.id })
    }

    func testMigrationOfAllArchivedEntriesMintsNoWorkspace() {
        // If every entry is archived, there's no active tab to restore → no workspace
        // minted (mirrors the empty-state rule).
        let archived1 = makeEntry(name: "a", isArchived: true)
        let archived2 = makeEntry(name: "b", isArchived: true)
        var state = WorkspaceState(processEntries: [archived1, archived2])
        state.migrateToWorkspaceStructure()
        XCTAssertEqual(state.workspaces, [])
        XCTAssertEqual(state.processEntries.count, 2)
    }

    func testMigrationAppendsUnmappedActiveEntriesToExistingDefaultWorkspace() {
        // Incremental: a new active entry not covered by the existing default
        // workspace is APPENDED to it (keeps idempotence + handles growth), rather
        // than minting a second workspace.
        let e1 = makeEntry(name: "a")
        let e2 = makeEntry(name: "b")
        let existing = Workspace(autoName: "Restored workspace", tabIds: [e1.id])
        var state = WorkspaceState(processEntries: [e1, e2], workspaces: [existing])

        state.migrateToWorkspaceStructure()

        XCTAssertEqual(state.workspaces.count, 1)
        XCTAssertEqual(state.workspaces.first?.tabIds, [e1.id, e2.id])
    }

    func testMigrationIsNonDestructiveForAllOtherCollections() throws {
        var state = try loadV1Fixture()
        let entriesBefore = state.processEntries
        let projectsBefore = state.projects
        let runsBefore = state.processRuns
        let actionLogBefore = state.actionLog

        state.migrateToWorkspaceStructure()

        // Only `workspaces` grew; every other collection byte-for-byte equal.
        XCTAssertEqual(state.processEntries, entriesBefore)
        XCTAssertEqual(state.projects, projectsBefore)
        XCTAssertEqual(state.processRuns, runsBefore)
        XCTAssertEqual(state.actionLog, actionLogBefore)
        XCTAssertFalse(state.workspaces.isEmpty)
    }

    // MARK: - Helpers

    private func makeEntry(
        id: UUID = UUID(),
        name: String,
        tabNameOverride: String? = nil,
        isArchived: Bool = false
    ) -> ProcessEntry {
        ProcessEntry(
            id: id,
            projectId: UUID(),
            name: name,
            kind: .terminalAgent,
            executable: "claude",
            workingDirectory: "/tmp/work",
            isArchived: isArchived,
            tabNameOverride: tabNameOverride
        )
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func v1FixtureURL() -> URL {
        repoRoot()
            .appendingPathComponent("worker")
            .appendingPathComponent("tasks")
            .appendingPathComponent("2026-06-24-1832-doing-slice2a-storage-schema")
            .appendingPathComponent("fixtures")
            .appendingPathComponent("v1-malformed-resume-state.json")
    }

    private func loadV1Fixture() throws -> WorkspaceState {
        let data = try Data(contentsOf: v1FixtureURL())
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(WorkspaceState.self, from: data)
    }
}
