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
}
