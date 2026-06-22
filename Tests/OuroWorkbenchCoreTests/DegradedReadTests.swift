import Foundation
import XCTest
@testable import OuroWorkbenchCore

/// F10b Seam B. `degradedReadReason(for:)` is the pure classifier the MCP
/// `workbench_status` handler consults so a newer-schema state file renders the
/// "upgrade Workbench" advisory as first-class CONTENT (isError:false) rather
/// than an error string. Genuine corruption is NOT masked — only the schema
/// case becomes content; `.stateUnreadable` keeps surfacing honestly via the
/// LocalizedError safety net (Seam A).
///
/// Gated to 100% line + region, so every arm — including the `nil` arm for a
/// non-`WorkbenchStoreError` input — is exercised here.
final class DegradedReadTests: XCTestCase {
    // MARK: - advisory (both arms)

    func testNewerSchemaAdvisoryNamesFoundAndSupportedAndUpgradeAndIntact() {
        let advisory = DegradedReadReason
            .stateWrittenByNewerWorkbench(foundVersion: 4, supportedVersion: 1)
            .advisory
        XCTAssertTrue(advisory.contains("v4"), "must name the found schema version, got: \(advisory)")
        XCTAssertTrue(advisory.contains("v1"), "must name the supported schema version, got: \(advisory)")
        XCTAssertTrue(
            advisory.lowercased().contains("upgrade"),
            "must instruct the boss to upgrade, got: \(advisory)"
        )
        XCTAssertTrue(
            advisory.lowercased().contains("intact"),
            "must reassure the data is intact, got: \(advisory)"
        )
    }

    func testUnreadableAdvisoryCarriesTheReason() {
        let advisory = DegradedReadReason
            .stateUnreadable(reason: "decode failed: bad json")
            .advisory
        XCTAssertTrue(
            advisory.contains("decode failed: bad json"),
            "the unreadable advisory must carry the underlying reason, got: \(advisory)"
        )
    }

    // MARK: - degradedReadReason(for:)

    func testUnsupportedVersionMapsToNewerSchemaWithCurrentSchemaVersion() {
        let reason = degradedReadReason(for: WorkbenchStoreError.unsupportedStateVersion(9))
        XCTAssertEqual(
            reason,
            .stateWrittenByNewerWorkbench(foundVersion: 9, supportedVersion: WorkspaceState.currentSchemaVersion)
        )
    }

    func testUnreadableStateMapsToStateUnreadableCarryingTheReason() {
        let preserved = QuarantineOutcome.moved(quarantineURL: URL(fileURLWithPath: "/tmp/x.corrupt"))
        let reason = degradedReadReason(
            for: WorkbenchStoreError.unreadableState(preserved: preserved, reason: "decode failed")
        )
        XCTAssertEqual(reason, .stateUnreadable(reason: "decode failed"))
    }

    func testNonStoreErrorMapsToNil() {
        // The nil arm is a real region: a non-WorkbenchStoreError input must NOT
        // be classified as a degraded read (so the MCP handler re-throws it and
        // Seam A surfaces it honestly). Exercised here for region coverage.
        struct OtherError: Error {}
        XCTAssertNil(degradedReadReason(for: OtherError()))
    }

    // MARK: - WorkspaceState.currentSchemaVersion (the single source of truth)

    func testCurrentSchemaVersionIsOne() {
        XCTAssertEqual(WorkspaceState.currentSchemaVersion, 1)
    }

    func testLoadRejectsOneAboveCurrentSchemaVersion() throws {
        // The version the load path accepts is pinned to currentSchemaVersion;
        // a file one above it is rejected as unsupported (read-only mode, so no
        // quarantine — just the honest error).
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DegradedReadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let stateURL = root.appendingPathComponent("workspace.json")
        let tooNew = WorkspaceState.currentSchemaVersion + 1
        let json = """
        {
          "boss": { "agentName": "slugger", "scope": "machine" },
          "processEntries": [],
          "processRuns": [],
          "projects": [],
          "schemaVersion": \(tooNew),
          "updatedAt": "2026-05-23T00:00:00Z"
        }
        """
        try Data(json.utf8).write(to: stateURL)

        XCTAssertThrowsError(
            try WorkbenchStore(stateURL: stateURL).load(quarantineCorruptFile: false)
        ) { error in
            XCTAssertEqual(error as? WorkbenchStoreError, .unsupportedStateVersion(tooNew))
        }
    }
}
